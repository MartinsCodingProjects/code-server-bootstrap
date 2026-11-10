"""Agent dashboard: status, history and usage of the Claude Code sessions in code-server.

Runs inside the code-server container (s6 service svc-agent-dashboard) on port 8790, reached
through the Cloudflare Tunnel at AGENTS_HOST. Every request must carry a valid Cloudflare
Access token for CF_ACCESS_AUD; without that configuration only this container may connect.
/otlp accepts Claude Code's telemetry from this container only.
"""

import asyncio
import csv
import io
import ipaddress
import logging
from contextlib import asynccontextmanager
from pathlib import Path

import jwt
from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse, PlainTextResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from . import config, ingest, live
from .events import CATEGORIES, dumps, from_otel_logs, from_otel_metrics
from .store import Store

log = logging.getLogger("agent_dashboard")
STATIC = Path(__file__).parent / "static"


class Hub:
    """Fans new history events out to the open live streams."""

    def __init__(self):
        self.queues: set[asyncio.Queue] = set()

    def publish(self, events: list[dict]):
        for q in list(self.queues):
            for e in events:
                if q.qsize() < 1000:
                    q.put_nowait(e)


class AccessAuth:
    """Verifies the Cloudflare Access JWT (header Cf-Access-Jwt-Assertion or cookie CF_Authorization)."""

    def __init__(self, team: str, aud: str):
        self.team, self.aud = team, aud
        self.jwks = jwt.PyJWKClient(f"https://{team}/cdn-cgi/access/certs", cache_keys=True, lifespan=3600)

    def verify(self, token: str) -> dict:
        key = self.jwks.get_signing_key_from_jwt(token).key
        return jwt.decode(token, key, algorithms=["RS256"], audience=self.aud, issuer=f"https://{self.team}")


def is_local(request: Request) -> bool:
    host = request.client.host if request.client else ""
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return host == "testclient"


def create_app(cfg: config.Config | None = None) -> FastAPI:
    cfg = cfg or config.load()
    store = Store(cfg.data_dir / "agents.db")
    hub = Hub()
    auth = AccessAuth(cfg.access_team, cfg.access_aud) if cfg.access_enabled else None

    async def ingest_loop():
        last_prune = 0.0
        while True:
            try:
                new = await asyncio.to_thread(ingest.ingest, store, cfg)
                if new:
                    hub.publish(new)
                loop_time = asyncio.get_running_loop().time()
                if loop_time - last_prune > 6 * 3600:
                    await asyncio.to_thread(ingest.prune, store, cfg)
                    last_prune = loop_time
            except Exception:  # keep going; the files stay the record
                log.exception("ingest failed")
            await asyncio.sleep(1)

    @asynccontextmanager
    async def lifespan(app):
        task = asyncio.create_task(ingest_loop())
        yield
        task.cancel()

    app = FastAPI(title="Agent dashboard", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.store, app.state.cfg, app.state.hub = store, cfg, hub

    @app.middleware("http")
    async def guard(request: Request, call_next):
        path = request.url.path
        if path == "/healthz":
            return await call_next(request)
        if path.startswith("/otlp/"):
            if not is_local(request):
                return PlainTextResponse("telemetry is accepted from this container only", 403)
            return await call_next(request)
        if auth is None:
            if not is_local(request):
                return PlainTextResponse(
                    "Cloudflare Access is not configured for the dashboard (CF_ACCESS_TEAM_DOMAIN, "
                    "CF_ACCESS_AUD; ./bootstrap.sh --agents), so only local requests are allowed.", 403)
            return await call_next(request)
        token = request.headers.get("cf-access-jwt-assertion") or request.cookies.get("CF_Authorization")
        if not token:
            return PlainTextResponse("no Cloudflare Access token: open the dashboard through its hostname", 403)
        try:
            request.state.user = (await asyncio.to_thread(auth.verify, token)).get("email")
        except Exception as exc:  # invalid, expired, wrong audience, keys unreachable
            log.warning("Access token rejected: %s", exc)
            return PlainTextResponse("Cloudflare Access token rejected", 403)
        return await call_next(request)

    @app.get("/healthz")
    async def healthz():
        return {"ok": True}

    # --- telemetry from Claude Code (OTLP/HTTP, JSON encoding) ---------------------------------

    @app.post("/otlp/v1/logs")
    async def otlp_logs(request: Request):
        events = from_otel_logs(await request.json())
        if events:
            hub.publish(store.add_events(events))
        return JSONResponse({})

    @app.post("/otlp/v1/metrics")
    async def otlp_metrics(request: Request):
        metrics = [m for m in from_otel_metrics(await request.json()) if m["value"] is not None]
        if metrics:
            store.add_metrics(metrics)
        return JSONResponse({})

    @app.post("/otlp/v1/traces")
    async def otlp_traces():
        return JSONResponse({})

    # --- API ----------------------------------------------------------------------------------

    @app.get("/api/overview")
    async def api_overview():
        return await asyncio.to_thread(live.overview, store, cfg)

    def _filters(project, session, cat, source, q, since, until):
        return {
            "project": project or None,
            "session": session or None,
            "categories": [c for c in (cat or "").split(",") if c] or None,
            "sources": [s for s in (source or "").split(",") if s] or None,
            "q": q or None,
            "since": since or None,
            "until": until or None,
        }

    @app.get("/api/events")
    async def api_events(project: str = "", session: str = "", cat: str = "", source: str = "", q: str = "",
                         since: str = "", until: str = "", before: str = "",
                         limit: int = Query(200, ge=1, le=1000)):
        rows = store.query_events(**_filters(project, session, cat, source, q, since, until),
                                  before=before or None, limit=limit + 1)
        return {"events": rows[:limit], "more": len(rows) > limit}

    @app.get("/api/events/export")
    async def api_export(format: str = "jsonl", project: str = "", session: str = "", cat: str = "",
                         source: str = "", q: str = "", since: str = "", until: str = ""):
        rows = store.query_events(**_filters(project, session, cat, source, q, since, until), limit=100_000)
        rows.reverse()  # oldest first in a file
        if format == "csv":
            buf = io.StringIO()
            w = csv.DictWriter(buf, fieldnames=["ts", "project", "session_id", "source", "category", "event", "summary", "id"])
            w.writeheader()
            w.writerows(rows)
            body, media, ext = buf.getvalue(), "text/csv", "csv"
        else:
            body, media, ext = "".join(dumps(r) + "\n" for r in rows), "application/x-ndjson", "jsonl"
        return PlainTextResponse(body, media_type=media,
                                 headers={"Content-Disposition": f'attachment; filename="agent-events.{ext}"'})

    @app.get("/api/events/{event_id}")
    async def api_event(event_id: int):
        e = store.event(event_id)
        if not e:
            raise HTTPException(404)
        return e

    @app.get("/api/meta")
    async def api_meta(request: Request):
        return {
            "projects": store.projects(),
            "categories": CATEGORIES,
            "user": getattr(request.state, "user", None),
            "code_server_url": cfg.code_server_url or None,
        }

    @app.get("/api/stream")
    async def api_stream(request: Request):
        q: asyncio.Queue = asyncio.Queue()
        hub.queues.add(q)

        async def gen():
            try:
                yield "retry: 3000\n\n"
                while not await request.is_disconnected():
                    try:
                        e = await asyncio.wait_for(q.get(), timeout=15)
                        yield f"data: {dumps(e)}\n\n"
                    except asyncio.TimeoutError:
                        yield ": ping\n\n"  # keeps Cloudflare and proxies from closing an idle stream
            finally:
                hub.queues.discard(q)

        return StreamingResponse(gen(), media_type="text/event-stream",
                                 headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})

    # --- pages --------------------------------------------------------------------------------

    @app.get("/")
    async def index():
        return FileResponse(STATIC / "index.html", headers={"Cache-Control": "no-cache"})

    app.mount("/static", StaticFiles(directory=STATIC), name="static")
    return app


def app():  # uvicorn --factory agent_dashboard.main:app
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    return create_app()
