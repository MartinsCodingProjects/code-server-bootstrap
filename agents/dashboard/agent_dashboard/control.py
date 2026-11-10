"""Session control for the Session Config page and the cards: the folder list, the saved
selection, and starting/stopping through the same agent-* commands the terminal uses."""

import json
import subprocess
from pathlib import Path

from .config import Config
from .live import tmux_name, tmux_sessions

# Never offered as project folders.
SKIP = {"node_modules", "__pycache__", "venv", "dist", "build", "target", "vendor", "coverage", "out", "tmp"}


def _subfolders(folder: Path) -> list[Path]:
    try:
        return sorted((p for p in folder.iterdir()
                       if p.is_dir() and not p.name.startswith(".") and p.name not in SKIP),
                      key=lambda p: p.name.lower())
    except OSError:
        return []


def folders(cfg: Config, selected: list[str]) -> list[dict]:
    """Folders below PROJECTS_DIR, two levels deep, as a flat list in tree order."""
    running = {t["project"]: t for t in tmux_sessions().values()}
    sel = set(selected)

    def entry(p: Path, depth: int) -> dict:
        rel = p.relative_to(cfg.projects_dir).as_posix()
        t = running.get(rel)
        return {
            "rel": rel,
            "name": p.name,
            "depth": depth,
            "git": (p / ".git").exists(),
            "selected": rel in sel,
            "running": bool(t and not t["dead"]),
            "exited": bool(t and t["dead"]),
            "session": tmux_name(rel),
        }

    out = []
    for top in _subfolders(cfg.projects_dir):
        e = entry(top, 1)
        children = [entry(c, 2) for c in _subfolders(top)]
        e["children"] = len(children)
        out.append(e)
        out += children
    return out


def valid_folder(cfg: Config, rel: str) -> bool:
    """Only existing folders strictly inside PROJECTS_DIR (no '..', no symlinks out)."""
    if not rel or rel.startswith("/") or "\\" in rel:
        return False
    try:
        root = cfg.projects_dir.resolve()
        p = (root / rel).resolve()
        return p.is_dir() and p != root and root in p.parents
    except OSError:
        return False


def save_selection(cfg: Config, rels: list[str]) -> list[str]:
    rels = sorted({r.strip("/") for r in rels if valid_folder(cfg, r.strip("/"))})
    cfg.data_dir.mkdir(parents=True, exist_ok=True)
    tmp = cfg.data_dir / "selection.json.tmp"
    tmp.write_text(json.dumps({"folders": rels}, indent=2) + "\n")
    tmp.replace(cfg.data_dir / "selection.json")
    return rels


def _agent(*args) -> dict:
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=40)
        return {"ok": r.returncode == 0, "output": (r.stdout + r.stderr).strip()}
    except (OSError, subprocess.SubprocessError) as exc:
        return {"ok": False, "output": str(exc)}


def start(cfg: Config, rel: str, resume: bool = False) -> dict:
    if not valid_folder(cfg, rel):
        return {"folder": rel, "ok": False, "output": "not a folder below the projects folder"}
    args = ["agent-start", rel] + (["--continue"] if resume else [])
    return {"folder": rel} | _agent(*args)


def stop(cfg: Config, rel: str) -> dict:
    if not valid_folder(cfg, rel):
        return {"folder": rel, "ok": False, "output": "not a folder below the projects folder"}
    return {"folder": rel} | _agent("agent-stop", rel)
