import json
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from agent_dashboard import ingest, live
from agent_dashboard.config import Config, normalize_team
from agent_dashboard.events import from_hook, from_otel_logs, from_otel_metrics, hook_status, norm_ts, project_from_cwd
from agent_dashboard.main import create_app
from agent_dashboard.store import Store


@pytest.fixture
def cfg(tmp_path) -> Config:
    (tmp_path / "projects" / "client-x" / "webshop").mkdir(parents=True)
    (tmp_path / "projects" / "solo" / ".git").mkdir(parents=True)
    for d in ("agent-events", "agent-samples", "agent-state"):
        (tmp_path / "claude" / d).mkdir(parents=True)
    return Config(projects_dir=tmp_path / "projects", claude_dir=tmp_path / "claude", data_dir=tmp_path / "data",
                  code_server_url="https://dev.example.com", access_team="", access_aud="", retention_days=90)


def write_events(cfg: Config, *lines: dict, day="2026-11-10"):
    with (cfg.events_dir / f"{day}.jsonl").open("a") as f:
        for line in lines:
            f.write(json.dumps(line) + "\n")


def hook(event, sid="s1", ts="2026-11-10T10:00:00.000Z", **kw):
    return {"ts": ts, "project": "client-x/webshop", "tmux": "client-x_webshop", "session_id": sid,
            "hook_event_name": event, "cwd": "/x", **kw}


def test_norm_ts_sorts_across_formats():
    assert norm_ts("2026-11-10T10:00:00Z") == "2026-11-10T10:00:00.000Z"
    assert norm_ts("2026-11-10T11:00:00+01:00") == "2026-11-10T10:00:00.000Z"
    assert norm_ts(1794304800) == norm_ts(str(1794304800 * 10**9))
    assert norm_ts(datetime(2026, 11, 10, 10, tzinfo=timezone.utc)) == "2026-11-10T10:00:00.000Z"


def test_normalize_team():
    assert normalize_team("myteam") == "myteam.cloudflareaccess.com"
    assert normalize_team("https://myteam.cloudflareaccess.com/") == "myteam.cloudflareaccess.com"


def test_project_from_cwd(cfg):
    p = cfg.projects_dir
    assert project_from_cwd(str(p / "client-x" / "webshop" / "src"), p) == "client-x/webshop"
    assert project_from_cwd(str(p / "solo" / "src" / "deep"), p) == "solo"  # first level is a repository
    assert project_from_cwd("/etc", p) is None


def test_hook_categories_and_status(cfg):
    e = from_hook(hook("PreToolUse", tool_name="Bash", tool_input={"command": "npm test"}), cfg.projects_dir)
    assert (e["category"], e["summary"]) == ("tool", "Bash: npm test")
    n = from_hook(hook("Notification", notification_type="permission_prompt", message="Claude needs permission"),
                  cfg.projects_dir)
    assert n["category"] == "waiting"
    assert hook_status(n["data"]) == "permission"
    assert hook_status({"hook_event_name": "Stop"}) == "input"
    assert hook_status({"hook_event_name": "StopFailure"}) == "error"
    assert hook_status({"hook_event_name": "Notification", "notification_type": "auth_success"}) is None
    # sessions outside agent-start: project from the working directory
    raw = {"session_id": "s9", "hook_event_name": "Stop", "cwd": str(cfg.projects_dir / "solo" / "app")}
    assert from_hook(raw, cfg.projects_dir)["project"] == "solo"


def test_ingest_is_incremental_and_tracks_status(cfg):
    store = Store(cfg.data_dir / "agents.db")
    write_events(cfg, hook("SessionStart"), hook("UserPromptSubmit", ts="2026-11-10T10:00:01.000Z", prompt="hi"))
    assert len(ingest.ingest(store, cfg)) == 2
    assert ingest.ingest(store, cfg) == []
    # a half-written line waits for its newline
    with (cfg.events_dir / "2026-11-10.jsonl").open("a") as f:
        f.write(json.dumps(hook("PermissionRequest", ts="2026-11-10T10:00:02.000Z", tool_name="Bash")))
    assert ingest.ingest(store, cfg) == []
    with (cfg.events_dir / "2026-11-10.jsonl").open("a") as f:
        f.write("\nnot json\n")
    new = ingest.ingest(store, cfg)
    assert [e["event"] for e in new] == ["PermissionRequest"]
    s = store.latest_sessions_by_tmux()["client-x_webshop"]
    assert s["status"] == "permission"
    # housekeeping events do not replace the last action shown on the card
    write_events(cfg, hook("InstructionsLoaded", ts="2026-11-10T10:00:03.000Z", file_path="CLAUDE.md"))
    ingest.ingest(store, cfg)
    s = store.latest_sessions_by_tmux()["client-x_webshop"]
    assert s["last_event"] == "PermissionRequest" and s["last_ts"] == "2026-11-10T10:00:03.000Z"
    # an older event arriving late does not overwrite the status
    write_events(cfg, hook("Stop", ts="2026-11-10T09:00:00.000Z"))
    ingest.ingest(store, cfg)
    assert store.latest_sessions_by_tmux()["client-x_webshop"]["status"] == "permission"


def test_query_filters_and_paging(cfg):
    store = Store(cfg.data_dir / "agents.db")
    lines = [hook("PreToolUse", ts=f"2026-11-10T10:00:{i:02d}.000Z", tool_name="Read",
                  tool_input={"file_path": f"f{i}"}) for i in range(10)]
    lines.append({**hook("Stop", sid="s2", ts="2026-11-10T11:00:00.000Z"), "project": "other"})
    write_events(cfg, *lines)
    ingest.ingest(store, cfg)
    assert len(store.query_events(project="client-x")) == 10  # parent folder covers subfolders
    assert len(store.query_events(categories=["stop"])) == 1
    assert len(store.query_events(q="f3")) == 1
    page1 = store.query_events(limit=4)
    page2 = store.query_events(limit=4, before=f"{page1[-1]['ts']}|{page1[-1]['id']}")
    assert page1[0]["event"] == "Stop" and not {e["id"] for e in page1} & {e["id"] for e in page2}
    assert len(store.query_events(since="2026-11-10T10:00:05Z", until="2026-11-10T10:59:00Z")) == 5


OTLP_LOGS = {"resourceLogs": [{
    "resource": {"attributes": [{"key": "agent.project", "value": {"stringValue": "client-x/webshop"}}]},
    "scopeLogs": [{"logRecords": [{
        "timeUnixNano": "1794304800000000000",
        "body": {"stringValue": "claude_code.api_request"},
        "attributes": [
            {"key": "event.name", "value": {"stringValue": "api_request"}},
            {"key": "session.id", "value": {"stringValue": "s1"}},
            {"key": "model", "value": {"stringValue": "claude-opus-5-5"}},
            {"key": "input_tokens", "value": {"intValue": "1200"}},
            {"key": "output_tokens", "value": {"intValue": "300"}},
            {"key": "cost_usd", "value": {"doubleValue": 0.0123}},
            {"key": "duration_ms", "value": {"intValue": "2100"}},
        ]}]}]}]}
OTLP_METRICS = {"resourceMetrics": [{
    "resource": {"attributes": [{"key": "agent.project", "value": {"stringValue": "solo"}}]},
    "scopeMetrics": [{"metrics": [{"name": "claude_code.token.usage", "sum": {"dataPoints": [{
        "timeUnixNano": "1794304800000000000", "asDouble": 1500,
        "attributes": [{"key": "type", "value": {"stringValue": "input"}},
                       {"key": "session.id", "value": {"stringValue": "s1"}}]}]}}]}]}]}


def test_otel_parsing():
    noisy = json.loads(json.dumps(OTLP_LOGS))
    records = noisy["resourceLogs"][0]["scopeLogs"][0]["logRecords"]
    records[0]["attributes"].append({"key": "user.email", "value": {"stringValue": "me@example.com"}})
    records.append({"attributes": [{"key": "event.name", "value": {"stringValue": "hook_registered"}}]})
    records.append({"attributes": [{"key": "event.name", "value": {"stringValue": "mcp_server_connection"}},
                                   {"key": "status", "value": {"stringValue": "failed"}},
                                   {"key": "server_scope", "value": {"stringValue": "github"}}]})
    api, mcp = from_otel_logs(noisy)
    assert "user.email" not in api["data"]
    assert (mcp["category"], mcp["summary"]) == ("error", "MCP-Server github: failed")
    [e] = from_otel_logs(OTLP_LOGS)
    assert (e["event"], e["project"], e["session_id"], e["category"]) == ("api_request", "client-x/webshop", "s1", "api")
    assert "1200 ein / 300 aus" in e["summary"]
    [m] = from_otel_metrics(OTLP_METRICS)
    assert (m["name"], m["value"], m["project"], m["attrs"]["type"]) == ("token.usage", 1500, "solo", "input")


def test_overview_cards(cfg, monkeypatch):
    store = Store(cfg.data_dir / "agents.db")
    now = norm_ts(time.time())
    write_events(cfg, hook("PermissionRequest", ts=now, tool_name="Bash", tool_input={"command": "rm -rf build"}),
                 day=now[:10])
    ingest.ingest(store, cfg)
    (cfg.state_dir / "s1.json").write_text(json.dumps({
        "session_id": "s1", "model": {"display_name": "Opus"},
        "context_window": {"used_percentage": 42, "total_input_tokens": 84000, "total_output_tokens": 1000},
        "rate_limits": {"five_hour": {"used_percentage": 61, "resets_at": 1794310000}},
        "_updated_at": 1}))
    (cfg.data_dir / "selection.json").write_text(json.dumps({"folders": ["solo"]}))
    monkeypatch.setattr(live, "tmux_sessions", lambda: {"client-x_webshop": {
        "name": "client-x_webshop", "project": "client-x/webshop", "created": 1, "attached": 1, "dead": False}})
    o = live.overview(store, cfg)
    by = {c["project"]: c for c in o["cards"]}
    assert by["client-x/webshop"]["status"] == "permission"
    assert by["client-x/webshop"]["context_pct"] == 42
    assert by["client-x/webshop"]["code_server_url"].startswith("https://dev.example.com/?folder=")
    assert by["solo"]["status"] == "idle"
    monkeypatch.setattr(live, "tmux_sessions", lambda: {})
    by = {c["project"]: c for c in live.overview(store, cfg)["cards"]}
    assert by["client-x/webshop"]["status"] == "permission"  # recent session outside tmux
    assert by["client-x/webshop"]["external"] and not by["solo"]["external"]
    assert o["cards"][0]["project"] == "client-x/webshop"  # needs you: first
    assert o["limits"]["five_hour"]["used_percentage"] == 61


def test_api_local_and_otlp(cfg):
    with TestClient(create_app(cfg)) as client:
        assert client.get("/healthz").json() == {"ok": True}
        assert client.post("/otlp/v1/logs", json=OTLP_LOGS).status_code == 200
        assert client.post("/otlp/v1/metrics", json=OTLP_METRICS).status_code == 200
        events = client.get("/api/events", params={"cat": "api"}).json()["events"]
        assert events[0]["event"] == "api_request"
        detail = client.get(f"/api/events/{events[0]['id']}").json()
        assert detail["data"]["input_tokens"] == 1200
        assert client.get("/api/events/export", params={"format": "csv", "cat": "api"}).text.startswith("ts,project")
        assert "categories" in client.get("/api/meta").json()
        page = client.get("/")
        assert page.status_code == 200 and 'static/app.js?v=' in page.text and 'style.css?v=' in page.text
        assert client.get("/static/app.js").headers["cache-control"] == "no-cache"


def test_access_required_when_configured(cfg):
    secured = Config(**{**cfg.__dict__, "access_team": "myteam.cloudflareaccess.com", "access_aud": "abc"})
    with TestClient(create_app(secured)) as client:
        assert client.get("/healthz").status_code == 200
        r = client.get("/api/overview")
        assert r.status_code == 403 and "no Cloudflare Access token" in r.text
        r = client.get("/api/overview", headers={"Cf-Access-Jwt-Assertion": "not-a-jwt"})
        assert r.status_code == 403


def test_remote_rejected_without_access(cfg):
    with TestClient(create_app(cfg), client=("172.18.0.5", 5000)) as client:
        assert client.get("/api/overview").status_code == 403
        assert client.post("/otlp/v1/logs", json=OTLP_LOGS).status_code == 403
        assert client.get("/healthz").status_code == 200


def test_prune(cfg):
    store = Store(cfg.data_dir / "agents.db")
    write_events(cfg, hook("Stop", ts="2020-01-01T00:00:00.000Z"), day="2020-01-01")
    ingest.ingest(store, cfg)
    ingest.prune(store, cfg)
    assert store.query_events() == []
    assert not (cfg.events_dir / "2020-01-01.jsonl").exists()


# --- stage 3: control --------------------------------------------------------------------------

from agent_dashboard import control, usage  # noqa: E402


def test_folders_and_selection(cfg, monkeypatch, tmp_path):
    (cfg.projects_dir / "client-x" / "node_modules").mkdir()
    (cfg.projects_dir / ".hidden").mkdir()
    (tmp_path / "outside").mkdir()
    (cfg.projects_dir / "escape").symlink_to(tmp_path / "outside")
    monkeypatch.setattr(control, "tmux_sessions", lambda: {"solo": {
        "name": "solo", "project": "solo", "created": 1, "attached": 0, "dead": False}})
    rels = [f["rel"] for f in control.folders(cfg, ["client-x/webshop"])]
    assert rels[:3] == ["client-x", "client-x/webshop", "escape"]
    assert "client-x/node_modules" not in rels and ".hidden" not in rels
    by = {f["rel"]: f for f in control.folders(cfg, ["client-x/webshop"])}
    assert by["client-x/webshop"]["selected"] and by["solo"]["running"] and by["solo"]["git"]
    assert not control.valid_folder(cfg, "escape")  # symlink out of PROJECTS_DIR
    assert not control.valid_folder(cfg, "../outside") and not control.valid_folder(cfg, "/etc")
    assert not control.valid_folder(cfg, "") and not control.valid_folder(cfg, "nope")
    assert control.save_selection(cfg, ["solo", "nope", "client-x/webshop/", "../outside"]) == ["client-x/webshop", "solo"]
    assert json.loads((cfg.data_dir / "selection.json").read_text())["folders"] == ["client-x/webshop", "solo"]


def test_control_api_needs_header_and_valid_folders(cfg, monkeypatch):
    calls = []
    monkeypatch.setattr(control, "_agent", lambda *a: calls.append(a) or {"ok": True, "output": "started"})
    with TestClient(create_app(cfg)) as client:
        assert client.post("/api/sessions/start", json={"folders": ["solo"]}).status_code == 403
        hdr = {"X-Agent-Dashboard": "1"}
        evil = {**hdr, "Origin": "https://evil.example", "Host": "agents.example.com"}
        assert client.post("/api/sessions/start", json={"folders": ["solo"]}, headers=evil).status_code == 403
        r = client.post("/api/sessions/start", json={"folders": ["solo", "../x"], "resume": True}, headers=hdr).json()
        assert [x["ok"] for x in r["results"]] == [True, False]
        assert calls == [("agent-start", "solo", "--continue")]
        assert client.post("/api/sessions/stop", json={"folder": "solo"}, headers=hdr).json()["ok"]
        assert client.put("/api/selection", json={"folders": ["solo"]}, headers=hdr).json() == {"selection": ["solo"]}
        assert client.get("/api/folders").json()["selection"] == ["solo"]
        assert client.get("/term/").status_code == 502  # ttyd not running here


def test_terminal_websocket_refuses_foreign_origin(cfg):
    from starlette.websockets import WebSocketDisconnect
    with TestClient(create_app(cfg)) as client:
        with pytest.raises(WebSocketDisconnect):
            with client.websocket_connect("/term/ws?arg=solo", headers={"Origin": "https://evil.example"}) as ws:
                ws.receive_bytes()


# --- stage 4: usage, session detail, transcript -------------------------------------------------

def test_permission_waits():
    ev = lambda ts, name, **d: {"ts": f"2026-11-10T10:{ts}.000Z", "session_id": "s", "project": "p", "event": name, "data": d}
    waits = usage.permission_waits([
        ev("00:00", "PermissionRequest"), ev("00:30", "Notification", notification_type="permission_prompt"),
        ev("02:00", "PostToolUse"), ev("03:00", "PreToolUse")])
    assert [w["ms"] for w in waits] == [120000]


def test_usage_and_session_detail(cfg):
    with TestClient(create_app(cfg)) as client:
        now = norm_ts(time.time())
        ns = str(int(time.time() * 1e9))
        metrics = {"resourceMetrics": [{"resource": {"attributes": [{"key": "agent.project", "value": {"stringValue": "solo"}}]},
            "scopeMetrics": [{"metrics": [
                {"name": "claude_code.token.usage", "sum": {"dataPoints": [{"timeUnixNano": ns, "asDouble": 1000,
                    "attributes": [{"key": "type", "value": {"stringValue": "input"}}, {"key": "session.id", "value": {"stringValue": "s1"}}]}]}},
                {"name": "claude_code.cost.usage", "sum": {"dataPoints": [{"timeUnixNano": ns, "asDouble": 0.5, "attributes": []}]}},
                {"name": "claude_code.active_time.total", "sum": {"dataPoints": [{"timeUnixNano": ns, "asDouble": 90,
                    "attributes": [{"key": "type", "value": {"stringValue": "cli"}}]}]}}]}]}]}
        client.post("/otlp/v1/metrics", json=metrics)
        u = client.get("/api/usage", params={"days": 7}).json()
        assert u["totals"]["tokens"] == 1000 and u["totals"]["cost"] == 0.5 and u["totals"]["active_agent_s"] == 90
        assert u["per_project"]["solo"]["tokens"] == 1000 and len(u["days"]) == 7
        assert client.get("/api/usage", params={"project": "client-x"}).json()["totals"].get("tokens") is None

        tdir = cfg.claude_dir / "projects" / "x"
        tdir.mkdir(parents=True)
        tpath = tdir / "s1.jsonl"
        tpath.write_text("\n".join(json.dumps(r) for r in [
            {"type": "user", "timestamp": now, "message": {"role": "user", "content": "Baue den Login"}},
            {"type": "assistant", "timestamp": now, "message": {"role": "assistant", "content": [
                {"type": "text", "text": "Mache ich."},
                {"type": "tool_use", "name": "Bash", "input": {"command": "npm test"}}]}},
            {"type": "user", "timestamp": now, "message": {"role": "user", "content": [
                {"type": "tool_result", "content": "1 failed", "is_error": True}]}},
        ]) + "\n")
        write_events(cfg, {**hook("SessionStart", ts=now), "transcript_path": str(tpath)}, day=now[:10])
        (cfg.samples_dir / f"{now[:10]}.jsonl").write_text(json.dumps(
            {"ts": now, "session_id": "s1", "project": "client-x/webshop", "context_window": {"used_percentage": 12},
             "rate_limits": {"five_hour": {"used_percentage": 30}}}) + "\n")
        for _ in range(30):
            if client.get("/api/session/s1").status_code == 200:
                break
            time.sleep(0.1)
        d = client.get("/api/session/s1").json()
        assert d["session"]["project"] == "client-x/webshop" and d["series"][0]["context_pct"] == 12
        assert d["tokens"] == {"input": 1000}
        t = client.get("/api/session/s1/transcript").json()
        assert [(i["kind"], i["role"]) for i in t["items"]] == [("text", "user"), ("text", "assistant"), ("tool", "assistant"), ("result", "tool")]
        assert t["items"][2]["text"] == "npm test" and t["items"][3]["error"]
        assert client.get("/api/usage").json()["limits"][0]["five_hour"] == 30


def test_transcript_outside_claude_dir_refused(cfg, tmp_path):
    store = Store(cfg.data_dir / "agents.db")
    secret = tmp_path / "secret.jsonl"
    secret.write_text('{"type":"user","message":{"role":"user","content":"x"}}\n')
    write_events(cfg, {**hook("SessionStart"), "transcript_path": str(secret)})
    ingest.ingest(store, cfg)
    assert usage.transcript(store, cfg, "s1") is None


def test_old_telemetry_rows_cleaned(cfg):
    store = Store(cfg.data_dir / "agents.db")
    with store.db:
        store.db.execute("INSERT INTO events(ts, source, event, category, data) VALUES"
                         " ('t', 'otel', 'hook_registered', 'api', '{}'),"
                         " ('t', 'otel', 'api_request', 'api', '{\"user.email\": \"a@b\", \"model\": \"m\"}')")
    store = Store(cfg.data_dir / "agents.db")
    rows = store.db.execute("SELECT event, data FROM events").fetchall()
    assert [(r["event"], json.loads(r["data"])) for r in rows] == [("api_request", {"model": "m"})]


# --- creating and deleting project folders ------------------------------------------------------

import subprocess  # noqa: E402


def git(path, *args):
    subprocess.run(["git", "-C", str(path), *args], check=True, capture_output=True,
                   env={"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                        "GIT_COMMITTER_EMAIL": "t@t", "HOME": str(path), "PATH": "/usr/bin:/bin"})


def test_create_folder(cfg):
    r = control.create_folder(cfg, "new-app")
    assert r["ok"] and (cfg.projects_dir / "new-app" / ".git").is_dir()
    assert not control.create_folder(cfg, "new-app")["ok"]  # exists
    for bad in ("", ".hidden", "../up", "a/b", "x" * 65, "sp ace"):
        assert not control.create_folder(cfg, bad)["ok"], bad


def test_folder_info_and_trash(cfg, monkeypatch):
    repo = cfg.projects_dir / "client-x" / "webshop"
    git(repo, "init", "-q", "-b", "main")
    (repo / "a.txt").write_text("x")
    git(repo, "add", ".")
    git(repo, "commit", "-q", "-m", "one")
    (repo / "b.txt").write_text("y")
    monkeypatch.setattr(control, "tmux_sessions", lambda: {})
    info = control.folder_info(cfg, "client-x")
    [r] = info["repos"]
    assert (r["folder"], r["changed"], r["remote"], r["unpushed"], r["commits"]) == ("client-x/webshop", 1, None, None, 1)
    assert info["files"] >= 2 and info["running"] == []

    control.save_selection(cfg, ["client-x/webshop", "solo"])
    assert not control.trash_folder(cfg, "client-x", "wrong")["ok"]
    monkeypatch.setattr(control, "tmux_sessions", lambda: {"x": {
        "name": "client-x_webshop", "project": "client-x/webshop", "created": 1, "attached": 0, "dead": False}})
    assert "stoppen" in control.trash_folder(cfg, "client-x", "client-x")["output"]
    monkeypatch.setattr(control, "tmux_sessions", lambda: {})
    r = control.trash_folder(cfg, "client-x", "client-x")
    assert r["ok"] and not (cfg.projects_dir / "client-x").exists()
    assert (Path(r["trash"]) / "webshop" / "a.txt").exists()
    assert json.loads((cfg.data_dir / "selection.json").read_text())["folders"] == ["solo"]
    assert ".trash" not in [f["rel"] for f in control.folders(cfg, [])]
    assert not control.trash_folder(cfg, ".trash", ".trash")["ok"]  # the trash itself
    [t] = control.trash_list(cfg)
    assert (t["folder"], t["days_left"], t["occupied"]) == ("client-x", 30, False)
    (cfg.projects_dir / "client-x").mkdir()
    assert "inzwischen" in control.restore_folder(cfg, t["id"])["output"]
    (cfg.projects_dir / "client-x").rmdir()
    assert control.restore_folder(cfg, t["id"])["ok"]
    assert (repo / "a.txt").exists() and control.trash_list(cfg) == []
    assert not control.restore_folder(cfg, t["id"])["ok"]
    old = cfg.projects_dir / ".trash" / "gone--20200101-000000"
    old.mkdir()
    control.purge_trash(cfg)
    assert not old.exists()


def test_folder_api(cfg, monkeypatch):
    monkeypatch.setattr(control, "tmux_sessions", lambda: {})
    hdr = {"X-Agent-Dashboard": "1"}
    with TestClient(create_app(cfg)) as client:
        assert client.post("/api/folders", json={"name": "fresh"}).status_code == 403  # no header
        r = client.post("/api/folders", json={"name": "fresh"}, headers=hdr).json()
        assert r["ok"] and client.get("/api/folders").json()["selection"] == ["fresh"]
        info = client.get("/api/folders/info", params={"folder": "fresh"}).json()
        assert info["repos"][0]["commits"] == 0 and info["recent"] == []
        assert client.get("/api/folders/info", params={"folder": "../x"}).status_code == 404
        r = client.post("/api/folders/delete", json={"folder": "fresh", "confirm": "fresh"}, headers=hdr).json()
        assert r["ok"] and client.get("/api/folders").json()["selection"] == []
        [t] = client.get("/api/trash").json()["entries"]
        assert client.post("/api/trash/restore", json={"id": t["id"]}).status_code == 403  # no header
        assert client.post("/api/trash/restore", json={"id": t["id"]}, headers=hdr).json()["ok"]
        assert (cfg.projects_dir / "fresh" / ".git").is_dir()
