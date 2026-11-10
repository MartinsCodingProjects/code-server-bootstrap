"""The current picture: tmux sessions, git state, status line snapshots, combined into one
card per project folder for the Sessions page."""

import json
import re
import subprocess
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote

from .config import Config
from .events import STATUS_LABELS, norm_ts
from .store import Store

CARD_STATUS_LABELS = STATUS_LABELS | {
    "starting": "startet",
    "trust": "Ordner bestätigen",
    "exited": "Claude beendet",
    "stopped": "gestoppt",
    "idle": "nicht gestartet",
}
# Order on the page: what needs you first.
STATUS_ORDER = ["permission", "trust", "input", "error", "working", "starting", "exited", "ended", "stopped", "idle"]
RECENT = timedelta(hours=24)
EXTERNAL_ALIVE = timedelta(minutes=30)  # a session outside tmux counts as live this long after its last event


def _run(*args, cwd=None) -> str:
    try:
        return subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def tmux_sessions() -> dict[str, dict]:
    """Agent sessions (tmux sessions with AGENT_PROJECT) by name."""
    out = {}
    fmt = "#{session_name}\t#{session_created}\t#{session_attached}\t#{pane_dead}"
    for line in _run("tmux", "list-panes", "-a", "-F", fmt).splitlines():
        name, created, attached, dead = (line.split("\t") + ["", "", "", ""])[:4]
        if name in out:
            continue
        env = _run("tmux", "show-environment", "-t", f"={name}", "AGENT_PROJECT").strip()
        if not env.startswith("AGENT_PROJECT="):
            continue
        out[name] = {
            "name": name,
            "project": env.split("=", 1)[1],
            "created": int(created or 0),
            "attached": int(attached or 0),
            "dead": dead == "1",
        }
    return out


def waits_for_trust(name: str) -> bool:
    screen = _run("tmux", "capture-pane", "-p", "-t", f"={name}:")
    return bool(re.search(r"trust (this|the files in this) folder|Do you trust", screen, re.I))


_git_cache: dict[str, tuple[float, dict | None]] = {}


def git_info(folder: Path) -> dict | None:
    hit = _git_cache.get(str(folder))
    if hit and time.monotonic() - hit[0] < 15:
        return hit[1]
    info = None
    if _run("git", "-C", str(folder), "rev-parse", "--is-inside-work-tree").strip() == "true":
        remote = _run("git", "-C", str(folder), "remote", "get-url", "origin").strip()
        info = {
            "branch": _run("git", "-C", str(folder), "branch", "--show-current").strip() or "(detached)",
            "changed": len(_run("git", "-C", str(folder), "status", "--porcelain").splitlines()),
            "last_commit": _run("git", "-C", str(folder), "log", "-1", "--format=%h %s (%cr)").strip(),
            "repo": re.sub(r"\.git$", "", remote.rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1]) if remote else "",
        }
    _git_cache[str(folder)] = (time.monotonic(), info)
    return info


def snapshots(cfg: Config) -> dict[str, dict]:
    """Latest status line data by session ID."""
    out = {}
    for path in cfg.state_dir.glob("*.json"):
        try:
            out[path.stem] = json.loads(path.read_text())
        except (OSError, ValueError):
            pass
    return out


def global_limits(snaps: dict[str, dict]) -> dict | None:
    """The 5-hour and 7-day limits are per account: take the newest snapshot that has them."""
    best = None
    for s in snaps.values():
        if s.get("rate_limits") and (best is None or s.get("_updated_at", 0) > best.get("_updated_at", 0)):
            best = s
    if not best:
        return None
    rl = best["rate_limits"]
    return {
        "five_hour": rl.get("five_hour"),
        "seven_day": rl.get("seven_day"),
        "updated_at": best.get("_updated_at"),
    }


def selection(cfg: Config) -> list[str]:
    try:
        data = json.loads((cfg.data_dir / "selection.json").read_text())
        return [p for p in data.get("folders", []) if isinstance(p, str)]
    except (OSError, ValueError, AttributeError):
        return []


def tmux_name(project: str) -> str:
    return re.sub(r"[/.:]", "_", project)


def _card_metrics(snap: dict | None) -> dict:
    if not snap:
        return {}
    cw = snap.get("context_window") or {}
    cost = snap.get("cost") or {}
    pr = snap.get("pr") or {}
    return {
        "model": (snap.get("model") or {}).get("display_name"),
        "context_pct": cw.get("used_percentage"),
        "context_tokens": (cw.get("total_input_tokens") or 0) + (cw.get("total_output_tokens") or 0),
        "context_size": cw.get("context_window_size"),
        "cost_usd": cost.get("total_cost_usd"),
        "duration_ms": cost.get("total_duration_ms"),
        "lines_added": cost.get("total_lines_added"),
        "lines_removed": cost.get("total_lines_removed"),
        "session_name": snap.get("session_name"),
        "effort": (snap.get("effort") or {}).get("level"),
        "pr": {"number": pr.get("number"), "url": pr.get("url"), "state": pr.get("review_state")} if pr else None,
        "cache_hit_ratio": (snap.get("prompt_cache") or {}).get("hit_ratio"),
        "updated_at": snap.get("_updated_at"),
    }


def overview(store: Store, cfg: Config) -> dict:
    now = datetime.now(timezone.utc)
    tmux = tmux_sessions()
    snaps = snapshots(cfg)
    by_tmux = store.latest_sessions_by_tmux()
    recent = store.sessions(norm_ts(now - RECENT))

    latest_by_project: dict[str, dict] = {}
    for s in recent:  # newest first
        if s["project"] and s["project"] not in latest_by_project:
            latest_by_project[s["project"]] = s

    projects = set(selection(cfg)) | {t["project"] for t in tmux.values()} | set(latest_by_project)
    tmux_by_project = {t["project"]: t for t in tmux.values()}

    cards = []
    for project in projects:
        t = tmux_by_project.get(project)
        name = t["name"] if t else tmux_name(project)
        session = None
        if t:
            s = by_tmux.get(name)
            created = norm_ts(t["created"])
            if s and s["last_ts"] >= created:
                session = s
        session = session or latest_by_project.get(project)

        if t:
            if t["dead"]:
                status = "exited"
            elif session is None or session["last_ts"] < norm_ts(t["created"]):
                status = "trust" if waits_for_trust(name) else "starting"
            else:
                status = session["status"]
        elif session and session["status"] != "ended" and \
                session["last_ts"] >= norm_ts(now - EXTERNAL_ALIVE):
            status = session["status"]  # a claude started by hand, outside agent-start
        elif session:
            status = "stopped"
        else:
            status = "idle"

        folder = cfg.projects_dir / project
        card = {
            "project": project,
            "name": name,
            "folder": str(folder),
            "exists": folder.is_dir(),
            "status": status,
            "status_label": CARD_STATUS_LABELS.get(status, status),
            "tmux": {"attached": t["attached"], "started": norm_ts(t["created"])} if t else None,
            "session_id": session["session_id"] if session else None,
            "last_ts": session["last_ts"] if session else None,
            "last_summary": session["last_summary"] if session else None,
            "status_ts": session["status_ts"] if session else None,
            "git": git_info(folder) if folder.is_dir() else None,
            "code_server_url": f"{cfg.code_server_url}/?folder={quote(str(folder))}" if cfg.code_server_url else None,
        }
        card.update(_card_metrics(snaps.get(card["session_id"] or "")))
        cards.append(card)

    cards.sort(key=lambda c: (STATUS_ORDER.index(c["status"]) if c["status"] in STATUS_ORDER else 99, c["project"]))
    return {
        "generated_at": norm_ts(now),
        "limits": global_limits(snaps),
        "cards": cards,
        "code_server_url": cfg.code_server_url or None,
    }
