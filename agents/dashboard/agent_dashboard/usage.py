"""Usage page and session detail: aggregates of the OpenTelemetry metrics, the status line
samples and the hook events, and a read-only view of a session's transcript."""

import json
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

from .config import Config
from .events import norm_ts, tool_target
from .store import Store

MAX_WAIT = timedelta(hours=8)  # a longer gap is a forgotten session, not waiting
WAIT_START = {"PermissionRequest", "Elicitation"}
WAIT_NOTIFY = {"permission_prompt", "elicitation_dialog", "elicitation_url_dialog"}
QUIET = {"Notification", "PermissionRequest", "Elicitation"}  # do not end a wait


def _day(ts: str) -> str:
    """UTC timestamp -> local calendar day (the container's TZ)."""
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().strftime("%Y-%m-%d")


def _ms(a: str, b: str) -> float:
    return (datetime.fromisoformat(b.replace("Z", "+00:00")) -
            datetime.fromisoformat(a.replace("Z", "+00:00"))).total_seconds() * 1000


def _rows(store: Store, sql: str, args) -> list[dict]:
    with store.lock:
        return [dict(r) for r in store.db.execute(sql, args)]


def permission_waits(events: list[dict]) -> list[dict]:
    """Waits for your permission: from a permission request to the session's next activity.
    `events` are hook events (ts, session_id, event, data) in time order."""
    open_since: dict[str, dict] = {}
    waits = []
    for e in events:
        sid = e["session_id"]
        if not sid:
            continue
        starts = e["event"] in WAIT_START or (
            e["event"] == "Notification" and e["data"].get("notification_type") in WAIT_NOTIFY)
        if starts:
            open_since.setdefault(sid, e)
        elif e["event"] not in QUIET and sid in open_since:
            first = open_since.pop(sid)
            ms = _ms(first["ts"], e["ts"])
            if 0 <= ms <= MAX_WAIT.total_seconds() * 1000:
                waits.append({"session_id": sid, "project": first["project"], "ts": first["ts"], "ms": ms})
    return waits


def usage(store: Store, cfg: Config, days: int = 7, project: str | None = None) -> dict:
    since = norm_ts(datetime.now(timezone.utc) - timedelta(days=days))
    pf, pargs = "", []
    if project:
        pf, pargs = " AND (project = ? OR project LIKE ?)", [project, project + "/%"]

    metrics = _rows(store, "SELECT ts, project, name, value, attrs FROM metrics WHERE ts >= ?" + pf,
                    [since] + pargs)
    per_day = defaultdict(lambda: defaultdict(lambda: {"tokens": 0.0, "cost": 0.0}))
    per_project = defaultdict(lambda: defaultdict(float))
    totals = defaultdict(float)
    for m in metrics:
        attrs = json.loads(m["attrs"])
        proj = m["project"] or "(ohne Projekt)"
        v = m["value"] or 0
        kind = attrs.get("type", "")
        if m["name"] == "token.usage":
            per_day[_day(m["ts"])][proj]["tokens"] += v
            per_project[proj]["tokens"] += v
            totals["tokens"] += v
            totals[f"tokens_{kind}"] += v
        elif m["name"] == "cost.usage":
            per_day[_day(m["ts"])][proj]["cost"] += v
            per_project[proj]["cost"] += v
            totals["cost"] += v
        elif m["name"] == "active_time.total":
            key = "active_user_s" if kind == "user" else "active_agent_s"
            per_project[proj][key] += v
            totals[key] += v
        elif m["name"] == "lines_of_code.count":
            key = "lines_added" if kind == "added" else "lines_removed"
            per_project[proj][key] += v
            totals[key] += v
        elif m["name"] in ("commit.count", "pull_request.count"):
            key = m["name"].split(".")[0] + "s"
            per_project[proj][key] += v
            totals[key] += v

    api = _rows(store, "SELECT project, event, json_extract(data, '$.duration_ms') AS ms FROM events"
                       " WHERE source='otel' AND event IN ('api_request', 'api_error') AND ts >= ?" + pf,
                [since] + pargs)
    durations = sorted(float(r["ms"]) for r in api if r["event"] == "api_request" and r["ms"] is not None)
    for r in api:
        proj = r["project"] or "(ohne Projekt)"
        key = "api_errors" if r["event"] == "api_error" else "api_requests"
        per_project[proj][key] += 1
        totals[key] += 1

    hooks = _rows(store, "SELECT ts, project, session_id, event, data FROM events WHERE source='hook'"
                         " AND category IN ('waiting', 'notification', 'tool', 'prompt', 'stop', 'error',"
                         " 'subagent', 'context') AND ts >= ?" + pf + " ORDER BY ts, id", [since] + pargs)
    for h in hooks:
        h["data"] = json.loads(h["data"])
    waits = permission_waits(hooks)
    for w in waits:
        proj = w["project"] or "(ohne Projekt)"
        per_project[proj]["wait_ms"] += w["ms"]
        per_project[proj]["waits"] += 1
    totals["wait_ms"] = sum(w["ms"] for w in waits)
    totals["waits"] = len(waits)

    samples = _rows(store, "SELECT ts, data FROM samples WHERE ts >= ?" + pf + " ORDER BY ts", [since] + pargs)
    limits, cache = [], []
    last_key = None
    for s in samples:
        d = json.loads(s["data"])
        rl = d.get("rate_limits") or {}
        five, seven = (rl.get("five_hour") or {}).get("used_percentage"), (rl.get("seven_day") or {}).get("used_percentage")
        if (five, seven) != last_key and (five is not None or seven is not None):
            limits.append({"ts": s["ts"], "five_hour": five, "seven_day": seven})
            last_key = (five, seven)
        if d.get("cache_hit_ratio") is not None:
            cache.append(d["cache_hit_ratio"])
    if len(limits) > 400:  # enough points for a chart
        last = limits[-1]
        limits = limits[:: len(limits) // 400 + 1]
        if limits[-1] is not last:
            limits.append(last)

    day_list = [(datetime.now() - timedelta(days=i)).strftime("%Y-%m-%d") for i in range(days - 1, -1, -1)]
    projects = sorted(per_project, key=lambda p: -per_project[p]["tokens"])
    return {
        "days": day_list,
        "projects": projects,
        "per_day": {d: dict(per_day.get(d, {})) for d in day_list},
        "per_project": {p: dict(per_project[p]) for p in projects},
        "totals": dict(totals) | {
            "api_ms_median": durations[len(durations) // 2] if durations else None,
            "cache_hit_ratio": sum(cache) / len(cache) if cache else None,
        },
        "limits": limits,
    }


def session_detail(store: Store, cfg: Config, session_id: str) -> dict | None:
    rows = _rows(store, "SELECT * FROM sessions WHERE session_id = ?", [session_id])
    if not rows:
        return None
    s = rows[0]
    snap_path = cfg.state_dir / f"{session_id}.json"
    try:
        snap = json.loads(snap_path.read_text())
    except (OSError, ValueError):
        snap = None
    series = []
    for r in _rows(store, "SELECT ts, data FROM samples WHERE session_id = ? ORDER BY ts", [session_id]):
        d = json.loads(r["data"])
        series.append({"ts": r["ts"], "context_pct": (d.get("context_window") or {}).get("used_percentage"),
                       "cost": (d.get("cost") or {}).get("total_cost_usd")})
    counts = {r["category"]: r["n"] for r in _rows(
        store, "SELECT category, COUNT(*) AS n FROM events WHERE session_id = ? GROUP BY category", [session_id])}
    tokens = defaultdict(float)
    for r in _rows(store, "SELECT value, attrs FROM metrics WHERE session_id = ? AND name = 'token.usage'", [session_id]):
        tokens[json.loads(r["attrs"]).get("type", "other")] += r["value"] or 0
    return {"session": s, "snapshot": snap, "series": series, "counts": counts, "tokens": dict(tokens)}


def _blocks(content) -> list[dict]:
    if isinstance(content, str):
        return [{"type": "text", "text": content}]
    return [b for b in content or [] if isinstance(b, dict)]


def transcript(store: Store, cfg: Config, session_id: str, limit: int = 400) -> dict | None:
    """The conversation as compact items. Only files below ~/.claude/projects are read."""
    rows = _rows(store, "SELECT transcript_path FROM sessions WHERE session_id = ?", [session_id])
    if not rows or not rows[0]["transcript_path"]:
        return None
    path = Path(rows[0]["transcript_path"])
    try:
        path = path.resolve(strict=True)
        path.relative_to((cfg.claude_dir / "projects").resolve())
    except (OSError, ValueError):
        return None
    items = []
    with path.open(encoding="utf-8", errors="replace") as f:
        for line in f:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            msg = rec.get("message") or {}
            role = msg.get("role") or rec.get("type")
            if role not in ("user", "assistant") or rec.get("isMeta"):
                continue
            for b in _blocks(msg.get("content")):
                kind = b.get("type")
                if kind == "text" and b.get("text", "").strip():
                    items.append({"ts": rec.get("timestamp"), "role": role, "kind": "text", "text": b["text"][:4000]})
                elif kind == "tool_use":
                    items.append({"ts": rec.get("timestamp"), "role": role, "kind": "tool",
                                  "tool": b.get("name"), "text": tool_target(b.get("input"))})
                elif kind == "tool_result":
                    content = b.get("content")
                    text = content if isinstance(content, str) else " ".join(
                        x.get("text", "") for x in _blocks(content) if x.get("type") == "text")
                    items.append({"ts": rec.get("timestamp"), "role": "tool", "kind": "result",
                                  "error": bool(b.get("is_error")), "text": text[:600]})
    return {"path": str(path), "total": len(items), "items": items[-limit:]}
