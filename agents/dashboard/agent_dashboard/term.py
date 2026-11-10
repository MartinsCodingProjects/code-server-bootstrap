"""Web terminal: forwards /term/ to ttyd (s6 service svc-agent-term, 127.0.0.1:7681, base path
/term), which runs `agent-attach <session>` for ?arg=<session>. ttyd itself is reachable only
from inside the container; this app's Access check is what guards it."""

import asyncio
import contextlib

import httpx
from fastapi import Request, WebSocket, WebSocketDisconnect
from fastapi.responses import Response
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

TTYD = "127.0.0.1:7681"
_PASS_HEADERS = {"content-type", "cache-control", "etag", "last-modified"}  # body arrives decoded


async def forward_http(request: Request) -> Response:
    url = f"http://{TTYD}{request.url.path}"
    if request.url.query:
        url += "?" + request.url.query
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            r = await client.get(url)
    except httpx.HTTPError:
        return Response("the web terminal (ttyd) is not running", 502, media_type="text/plain")
    headers = {k: v for k, v in r.headers.items() if k.lower() in _PASS_HEADERS}
    return Response(r.content, r.status_code, headers=headers)


async def forward_ws(ws: WebSocket):
    url = f"ws://{TTYD}{ws.url.path}"
    if ws.url.query:
        url += "?" + ws.url.query
    try:
        upstream = await connect(url, subprotocols=["tty"], max_size=None, open_timeout=10)
    except (OSError, ConnectionClosed, asyncio.TimeoutError):
        await ws.close(code=1011)
        return
    await ws.accept(subprotocol="tty")

    async def client_to_ttyd():
        while True:
            msg = await ws.receive()
            if msg["type"] == "websocket.disconnect":
                return
            await upstream.send(msg["bytes"] if msg.get("bytes") is not None else msg.get("text", ""))

    async def ttyd_to_client():
        async for msg in upstream:
            if isinstance(msg, bytes):
                await ws.send_bytes(msg)
            else:
                await ws.send_text(msg)

    tasks = [asyncio.create_task(client_to_ttyd()), asyncio.create_task(ttyd_to_client())]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for t in tasks:
            t.cancel()
        with contextlib.suppress(Exception):
            await upstream.close()
        with contextlib.suppress(Exception, WebSocketDisconnect):
            await ws.close()
