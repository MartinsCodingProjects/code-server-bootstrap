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
        assert client.get("/").status_code == 200


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
