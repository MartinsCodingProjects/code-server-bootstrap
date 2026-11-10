"""Turns raw records (hook lines, OpenTelemetry log records) into history events:
category, a one-line summary in German, and the session status they imply."""

import json
from datetime import datetime, timezone
from pathlib import Path

# Categories, as filtered in the history ("api" holds telemetry details and is hidden by default).
CATEGORIES = {
    "lifecycle": "Start/Ende",
    "prompt": "Eingabe",
    "tool": "Werkzeug",
    "waiting": "Wartet auf dich",
    "stop": "Zug beendet",
    "error": "Fehler",
    "context": "Kontext",
    "subagent": "Subagent/Task",
    "config": "Konfiguration",
    "notification": "Hinweis",
    "api": "API/Telemetrie",
}

# Session status (the last relevant event decides it).
STATUS_LABELS = {
    "working": "arbeitet",
    "permission": "braucht Freigabe",
    "input": "wartet auf Eingabe",
    "error": "Fehler",
    "ended": "beendet",
}

WAITING_NOTIFICATIONS = {
    "permission_prompt": "permission",
    "elicitation_dialog": "permission",
    "elicitation_url_dialog": "permission",
    "idle_prompt": "input",
    "agent_needs_input": "input",
}

_WORKING = {
    "UserPromptSubmit", "UserPromptExpansion", "PreToolUse", "PostToolUse", "PostToolUseFailure",
    "PostToolBatch", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact", "TaskCreated",
    "TaskCompleted", "ElicitationResult", "PermissionDenied",
}

_HOOK_CATEGORY = {
    "SessionStart": "lifecycle", "SessionEnd": "lifecycle", "CwdChanged": "lifecycle",
    "DirectoryAdded": "lifecycle",
    "UserPromptSubmit": "prompt", "UserPromptExpansion": "prompt",
    "PreToolUse": "tool", "PostToolUse": "tool", "PostToolBatch": "tool",
    "PostToolUseFailure": "error", "StopFailure": "error", "PermissionDenied": "error",
    "PermissionRequest": "waiting", "Elicitation": "waiting", "ElicitationResult": "prompt",
    "Stop": "stop",
    "PreCompact": "context", "PostCompact": "context",
    "SubagentStart": "subagent", "SubagentStop": "subagent", "TaskCreated": "subagent",
    "TaskCompleted": "subagent", "TeammateIdle": "subagent",
    "PreModelSwitch": "config", "PostModelSwitch": "config", "ConfigChange": "config",
    "InstructionsLoaded": "config",
    "Notification": "notification",
}


def norm_ts(value) -> str:
    """Any timestamp (ISO string, epoch seconds or nanoseconds) -> 'YYYY-MM-DDTHH:MM:SS.mmmZ' (UTC),
    so that timestamps from all sources sort as strings."""
    if isinstance(value, datetime):
        dt = value if value.tzinfo else value.replace(tzinfo=timezone.utc)
    elif isinstance(value, (int, float)) or (isinstance(value, str) and value.isdigit()):
        n = float(value)
        dt = datetime.fromtimestamp(n / 1e9 if n > 1e12 else n, timezone.utc)
    elif isinstance(value, str) and value:
        try:
            dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            dt = datetime.now(timezone.utc)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
    else:
        dt = datetime.now(timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _short(text, n=160) -> str:
    text = " ".join(str(text or "").split())
    return text if len(text) <= n else text[: n - 1] + "…"


def tool_target(tool_input) -> str:
    """The most telling argument of a tool call: command, file, pattern, URL, ..."""
    if not isinstance(tool_input, dict):
        return ""
    for key in ("command", "file_path", "notebook_path", "path", "pattern", "url", "query",
                "skill", "description", "prompt"):
        if tool_input.get(key):
            return _short(tool_input[key], 120)
    return ""


def project_from_cwd(cwd: str, projects_dir: Path) -> str | None:
    """Fallback for sessions not started by agent-start: the folder below PROJECTS_DIR.
    A first-level folder that is a repository is the project; otherwise the second level."""
    if not cwd:
        return None
    try:
        rel = Path(cwd).resolve().relative_to(projects_dir.resolve())
    except (ValueError, OSError):
        return None
    parts = rel.parts
    if not parts:
        return None
    if len(parts) == 1 or (projects_dir / parts[0] / ".git").exists():
        return parts[0]
    return "/".join(parts[:2])


def _hook_summary(e: dict) -> str:
    name = e.get("hook_event_name", "")
    tool = e.get("tool_name", "")
    target = tool_target(e.get("tool_input"))
    match name:
        case "SessionStart":
            return f"Session gestartet ({e.get('source', 'startup')})" + (f", {e['model']}" if e.get("model") else "")
        case "SessionEnd":
            return f"Session beendet ({e.get('reason', 'other')})"
        case "UserPromptSubmit":
            return "Eingabe: " + _short(e.get("prompt"), 140)
        case "UserPromptExpansion":
            return "Befehl: " + _short(e.get("command_name") or e.get("prompt"), 140)
        case "PreToolUse":
            return f"{tool}: {target}" if target else tool
        case "PostToolUse":
            return f"{tool} fertig" + (f": {target}" if target else "")
        case "PostToolUseFailure":
            return f"{tool} fehlgeschlagen: " + _short(e.get("error") or target, 140)
        case "PostToolBatch":
            return "Werkzeug-Batch abgeschlossen"
        case "PermissionRequest":
            return f"Braucht Freigabe: {tool}" + (f": {target}" if target else "")
        case "PermissionDenied":
            return f"Abgelehnt (Auto-Modus): {tool}" + (f": {target}" if target else "")
        case "Notification":
            return _short(e.get("message") or e.get("notification_type"), 160)
        case "Stop":
            msg = e.get("last_assistant_message")
            return "Zug beendet" + (": " + _short(msg, 150) if msg else "")
        case "StopFailure":
            return "Abbruch durch Fehler: " + _short(e.get("error") or e.get("error_type") or "unbekannt", 140)
        case "PreCompact":
            return f"Kontext wird komprimiert ({e.get('trigger', 'auto')})"
        case "PostCompact":
            return f"Kontext komprimiert ({e.get('trigger', 'auto')})"
        case "SubagentStart":
            return f"Subagent gestartet: {e.get('agent_type', '')}"
        case "SubagentStop":
            return f"Subagent fertig: {e.get('agent_type', '')}"
        case "TaskCreated":
            return "Task angelegt: " + _short(e.get("task_subject") or e.get("subject") or e.get("description"), 140)
        case "TaskCompleted":
            return "Task erledigt: " + _short(e.get("task_subject") or e.get("subject") or e.get("description"), 140)
        case "TeammateIdle":
            return f"Teammate wartet: {e.get('teammate_name', '')}"
        case "PreModelSwitch" | "PostModelSwitch":
            return f"Modellwechsel: {e.get('from_model', '?')} → {e.get('to_model', '?')}"
        case "CwdChanged":
            return "Verzeichnis: " + _short(e.get("new_cwd") or e.get("cwd"), 140)
        case "DirectoryAdded":
            return "Verzeichnis hinzugefügt: " + _short(e.get("directory") or e.get("path"), 140)
        case "InstructionsLoaded":
            return "Anweisungen geladen: " + _short(e.get("file_path") or e.get("load_reason"), 140)
        case "ConfigChange":
            return "Konfiguration geändert: " + _short(e.get("source") or e.get("file_path"), 140)
        case "Elicitation":
            return f"Rückfrage von {e.get('mcp_server_name', 'MCP')}: " + _short(e.get("message"), 120)
        case "ElicitationResult":
            return f"Rückfrage beantwortet ({e.get('mcp_server_name', 'MCP')})"
    return name


def hook_status(e: dict) -> str | None:
    """New session status implied by a hook event (None: unchanged)."""
    name = e.get("hook_event_name", "")
    if name in _WORKING:
        return "working"
    if name in ("PermissionRequest", "Elicitation"):
        return "permission"
    if name in ("Stop", "SessionStart"):
        return "input"
    if name == "StopFailure":
        return "error"
    if name == "SessionEnd":
        return "ended"
    if name == "Notification":
        return WAITING_NOTIFICATIONS.get(e.get("notification_type", ""))
    return None


def from_hook(line: dict, projects_dir: Path) -> dict:
    name = line.get("hook_event_name") or "unknown"
    category = _HOOK_CATEGORY.get(name, "notification")
    if name == "Notification" and line.get("notification_type") in WAITING_NOTIFICATIONS:
        category = "waiting"
    if name == "StopFailure":
        category = "error"
    return {
        "ts": norm_ts(line.get("ts")),
        "source": "hook",
        "project": line.get("project") or project_from_cwd(line.get("cwd", ""), projects_dir),
        "session_id": line.get("session_id"),
        "event": name,
        "category": category,
        "summary": _hook_summary(line),
        "data": line,
    }


# --- OpenTelemetry (OTLP/HTTP JSON) -------------------------------------------------------------

def _any_value(v: dict):
    if "stringValue" in v:
        return v["stringValue"]
    if "intValue" in v:
        return int(v["intValue"])
    if "doubleValue" in v:
        return float(v["doubleValue"])
    if "boolValue" in v:
        return bool(v["boolValue"])
    if "arrayValue" in v:
        return [_any_value(x) for x in v["arrayValue"].get("values", [])]
    if "kvlistValue" in v:
        return attrs(v["kvlistValue"].get("values", []))
    return None


def attrs(items) -> dict:
    return {a.get("key"): _any_value(a.get("value", {})) for a in items or []}


def _num(v, default=0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return default


def _otel_summary(name: str, a: dict) -> str:
    match name:
        case "api_request":
            return (f"API {a.get('model', '')}: {int(_num(a.get('input_tokens')))} ein / "
                    f"{int(_num(a.get('output_tokens')))} aus, Cache {int(_num(a.get('cache_read_tokens')))}, "
                    f"{_num(a.get('cost_usd')):.4f} $, {int(_num(a.get('duration_ms')))} ms")
        case "api_error":
            return f"API-Fehler {a.get('status_code', '')}: " + _short(a.get("error"), 140)
        case "api_refusal":
            return f"API-Ablehnung ({a.get('model', '')})"
        case "tool_result":
            ok = str(a.get("success")).lower() == "true"
            return f"{a.get('tool_name', '')} {'ok' if ok else 'fehlgeschlagen'} ({int(_num(a.get('duration_ms')))} ms)"
        case "tool_decision":
            return f"{a.get('tool_name', '')}: {a.get('decision', '')} ({a.get('source', '')})"
        case "user_prompt":
            return f"Eingabe ({int(_num(a.get('prompt_length')))} Zeichen)"
        case "assistant_response":
            return f"Antwort ({int(_num(a.get('response_length')))} Zeichen)"
        case "mcp_server_connection":
            server = a.get("mcp_server.name") or a.get("server_name") or a.get("server_scope") or "MCP"
            return f"MCP-Server {server}: {a.get('status', '?')}" + (f" ({_short(a.get('error'), 100)})" if a.get("error") else "")
    return name


# Startup bookkeeping Claude Code sends with every session (our own hooks being registered
# and run, plugins, managed settings): nothing to learn from, so not stored.
OTEL_IGNORED = {"hook_registered", "hook_execution_start", "hook_execution_complete", "plugin_loaded",
                "managed_settings_resolved"}
# Account identity on every record: not needed for the history, so not stored either.
OTEL_IDENTITY = {"user.email", "user.id", "user.account_uuid", "user.account_id", "organization.id"}


def _otel_category(name: str, a: dict) -> str:
    if name == "api_error":
        return "error"
    if name == "mcp_server_connection":
        return "config" if a.get("status") in ("connected", "success") else "error"
    return "api"


def from_otel_logs(body: dict) -> list[dict]:
    out = []
    for rl in body.get("resourceLogs", []):
        res = attrs(rl.get("resource", {}).get("attributes"))
        for sl in rl.get("scopeLogs", []):
            for rec in sl.get("logRecords", []):
                a = attrs(rec.get("attributes"))
                name = str(a.get("event.name") or _any_value(rec.get("body", {})) or "otel")
                name = name.removeprefix("claude_code.")
                if name in OTEL_IGNORED:
                    continue
                for key in OTEL_IDENTITY:
                    a.pop(key, None)
                ts = a.get("event.timestamp") or rec.get("timeUnixNano") or rec.get("observedTimeUnixNano")
                out.append({
                    "ts": norm_ts(ts),
                    "source": "otel",
                    "project": res.get("agent.project") or a.get("agent.project"),
                    "session_id": a.get("session.id") or res.get("session.id"),
                    "event": name,
                    "category": _otel_category(name, a),
                    "summary": _otel_summary(name, a),
                    "data": a,
                })
    return out


def from_otel_metrics(body: dict) -> list[dict]:
    out = []
    for rm in body.get("resourceMetrics", []):
        res = attrs(rm.get("resource", {}).get("attributes"))
        for sm in rm.get("scopeMetrics", []):
            for m in sm.get("metrics", []):
                data = m.get("sum") or m.get("gauge") or {}
                for dp in data.get("dataPoints", []):
                    a = {k: v for k, v in attrs(dp.get("attributes")).items() if k not in OTEL_IDENTITY}
                    value = dp.get("asDouble", dp.get("asInt"))
                    out.append({
                        "ts": norm_ts(dp.get("timeUnixNano")),
                        "project": res.get("agent.project") or a.get("agent.project"),
                        "session_id": a.get("session.id") or res.get("session.id"),
                        "name": m.get("name", "").removeprefix("claude_code."),
                        "value": _num(value, None),
                        "attrs": a,
                    })
    return out


def dumps(obj) -> str:
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))
