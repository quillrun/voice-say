"""HTTP daemon for the voice-say render pipeline.

Listens on 127.0.0.1:8890 (the daemon's default loopback port; see
config.py PORT). All clients
(the app, the `voice-say` CLI) talk to this daemon.

This module owns app assembly, lifecycle hooks, the request-logging
middleware, and the SSE endpoint (single small handler over
`state.iter_events`). Route handlers live in the cohesive `_routes_*`
modules; helpers in `_validators.py`; app keys in `_keys.py`.

Endpoints:
  POST /render               JSON body → entry              (_routes_render)
  POST /render_longform      JSON body → entry (1 row)      (_routes_render)
  POST /episode/resume        continue a finalized-early draft (_routes_render)
  POST /episode/{id}/cancel   abort an in-flight stream      (_routes_render)
  POST /episode/{id}/finalize save-and-stop a stream         (_routes_render)
  POST /episode/{id}/force_finalize  save-and-stop, drop in-flight chunk (_routes_render)
  GET  /history?limit=       → {entries, total}             (_routes_history)
  GET  /search?q=&limit=     → {entries, total} (FTS5)      (_routes_history)
  GET/POST /progress/{ts}                                   (_routes_history)
  GET/POST /overlays/{ts}                                   (_routes_history)
  GET  /audio/{ts}           → file response                (_routes_history)
  POST /reload               re-hydrate cache from voice.db (_routes_history)
  GET  /backends             → list[backend]                (_routes_meta)
  GET  /voices/{backend_id}  → {backend, voices}            (_routes_meta)
  GET  /tags                 → {tags: [...in use...]}       (_routes_meta)
  POST /playback/active      → {ok: true}                   (_routes_meta)
  GET  /health[?deep=1]      → {status: ok, ...}            (_routes_meta)
  GET  /config               → {version, backends, ...}     (_routes_meta)
  POST /config               write default_backend/_voice/say_threshold_chars (_routes_meta)
  GET  /events               → SSE stream                   (this file)

Run:
  python -m voice_say.http_server
  python -m voice_say.http_server --port 8891

There is no authentication. --host other than 127.0.0.1 still answers only
loopback and Tailscale host names (_hostguard), so a LAN address is refused,
but every device on the tailnet gets read and write access to the library.

Logs to stderr (or LAUNCHD_STDOUT_PATH if set by LaunchAgent).
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import os
import secrets
import sys
import time
from typing import Any

from aiohttp import web
import httpx

from . import __version__, _db, _sinks, align, config, engine, overlays, progress
from . import _routes_history, _routes_meta, _routes_render
from ._hostguard import refusal
from ._keys import HTTPX_KEY, STATE_KEY
from .state import State


log = logging.getLogger("voice_say")
SSE_KEEPALIVE_S = 15.0


async def events_handler(request: web.Request) -> web.StreamResponse:
    """Server-Sent Events stream.

    Snapshot/backlog/live ordering + keepalive cadence live in
    `state.iter_events`; this handler is the wire-format adapter.

    SSE format (one event per record):
      id: 42
      event: progress
      data: {"id":42,"type":"progress","ts":"...","progress":{...}}

    Keepalive: a `:keepalive\\n\\n` comment is written every
    SSE_KEEPALIVE_S seconds of quiet. macOS `URLSession.bytes` buffers
    small chunks until enough bytes accumulate; without periodic ticks,
    a render or overlay event could sit in CFNetwork's read buffer for
    ~tens of seconds before the VoiceSay UI sees it.
    """
    state: State = request.app[STATE_KEY]
    last_event_id = state.parse_last_event_id(request.headers.get("Last-Event-ID"))

    resp = web.StreamResponse(
        status=200,
        headers={
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "X-Accel-Buffering": "no",
        },
    )
    resp.enable_chunked_encoding()
    await resp.prepare(request)

    t0 = time.monotonic()
    try:
        async for ev in state.iter_events(last_event_id, keepalive_s=SSE_KEEPALIVE_S):
            if ev is None:
                line = b":keepalive\n\n"
            else:
                payload = json.dumps(ev, ensure_ascii=False)
                kind = ev.get("type", "message")
                sid = state.wire_event_id(ev["id"])
                line = f"id: {sid}\nevent: {kind}\ndata: {payload}\n\n".encode("utf-8")
            try:
                await resp.write(line)
            except ConnectionError:
                # Benign client disconnect (VoiceSay quit, curl aborted, mpv
                # stopped). aiohttp surfaces it as ConnectionError("Connection
                # lost") from the drain, or ConnectionResetError /
                # BrokenPipeError from the transport — all subclasses of
                # ConnectionError, so this catches exactly the disconnect
                # family and nothing else. One INFO line instead of a
                # 30-line chained ERROR traceback that buries real errors
                # in the daemon's error log.
                _emit_log(event="client_disconnect",
                          req_id=request.get("req_id"),
                          remote=request.remote, path=request.path,
                          ms=(time.monotonic() - t0) * 1000)
                break
            except asyncio.CancelledError:
                break
    except asyncio.CancelledError:
        pass
    return resp


# CORS — opt-in via VOICE_SAY_CORS / cors_origins.
#
# Registered as an on_response_prepare hook, NOT middleware: middleware
# runs after resp.prepare() has flushed headers for StreamResponse (SSE)
# and FileResponse (/audio), so a browser on another origin couldn't read
# those. The prepare hook lands the header before the flush.

async def _on_prepare_cors(request: web.Request, response: web.StreamResponse) -> None:
    response.headers["Access-Control-Allow-Origin"] = config.CORS_ORIGIN or ""
    response.headers["Access-Control-Allow-Headers"] = "Content-Type, Last-Event-ID"
    response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"


async def _cors_preflight(request: web.Request) -> web.Response:
    return web.Response(status=204)


def build_app() -> web.Application:
    app = web.Application(middlewares=[_logging_middleware, _host_guard])
    r = app.router
    r.add_post("/render",                 _routes_render.render)
    r.add_post("/render_longform",        _routes_render.render_longform)
    r.add_post("/episode/resume",                _routes_render.episode_resume)
    r.add_post("/episode/{episode_id}/cancel",   _routes_render.episode_cancel)
    r.add_post("/episode/{episode_id}/finalize", _routes_render.episode_finalize)
    r.add_post("/episode/{episode_id}/force_finalize",
               _routes_render.episode_force_finalize)
    r.add_get ("/history",                _routes_history.history)
    r.add_get ("/search",                 _routes_history.search)
    r.add_get ("/progress/{ts}",          _routes_history.progress_get)
    r.add_post("/progress/{ts}",          _routes_history.progress_post)
    r.add_get ("/overlays/{ts}",          _routes_history.overlays_get)
    r.add_post("/overlays/{ts}",          _routes_history.overlays_post)
    r.add_get ("/audio/{ts}",             _routes_history.audio)
    r.add_post("/reload",                 _routes_history.reload)
    r.add_post("/align/{ts}",             _routes_history.align)
    r.add_get ("/backends",               _routes_meta.backends)
    r.add_get ("/voices/{backend_id}",    _routes_meta.voices)
    r.add_get ("/tags",                   _routes_meta.tags)
    r.add_get ("/stats",                  _routes_meta.stats)
    r.add_post("/playback/active",        _routes_meta.playback_active)
    r.add_get ("/health",                 _routes_meta.health)
    r.add_get ("/config",                 _routes_meta.config)
    r.add_post("/config",                 _routes_meta.config_post)
    r.add_post("/backends/{backend}/restart", _routes_meta.backend_restart)
    r.add_get ("/events",                 events_handler)
    if config.CORS_ORIGIN:
        r.add_route("OPTIONS", "/{tail:.*}", _cors_preflight)
        app.on_response_prepare.append(_on_prepare_cors)
    app.on_startup.append(_startup)
    app.on_cleanup.append(_cleanup)
    return app


_voices_task: asyncio.Task | None = None


async def _startup(app: web.Application) -> None:
    # Reusable client — longform MLX renders can take minutes, so the
    # timeout is generous and the connection pool stays warm.
    app[HTTPX_KEY] = httpx.AsyncClient(timeout=httpx.Timeout(600.0))

    # Open the SQLite store + ensure schema before hydrating the cache.
    _db.connect()
    _db.init_schema()

    # In-memory state cache. Hydrate from the store once, then every write
    # goes through engine/progress/overlays hooks so reads never touch the db.
    state = State()
    state.load_from_disk()
    app[STATE_KEY] = state
    engine.on_history_appended = state.record_history
    engine.aligner = align.align if align.available() else None
    progress.on_progress_written = state.record_progress
    overlays.on_overlay_written = state.record_overlay

    # Voices of servers that list their own, so the first /config has them.
    global _voices_task
    _voices_task = asyncio.create_task(engine.refresh_voices(app[HTTPX_KEY]))

    swept = await asyncio.to_thread(_sinks.sweep_stale_temps)
    _emit_log(event="startup", version=__version__,
              read_along_alignment=engine.aligner is not None,
              history_rows=len(state.history),
              progress_rows=len(state.progress),
              overlay_rows=len(state.overlays),
              stale_temps_swept=swept)


async def _cleanup(app: web.Application) -> None:
    # Detach hooks so re-creating the app in tests doesn't double-fire.
    engine.on_history_appended = None
    engine.aligner = None
    progress.on_progress_written = None
    overlays.on_overlay_written = None
    if _voices_task is not None:
        _voices_task.cancel()
    client: httpx.AsyncClient = app[HTTPX_KEY]
    await client.aclose()
    _db.close()


@web.middleware
async def _host_guard(request: web.Request, handler: Any) -> web.StreamResponse:
    """403 for requests a web page could forge (DNS rebinding, cross-site
    writes); see _hostguard. Inside the logging middleware so refusals log."""
    why = refusal(request.method, request.headers.get("Host"),
                  request.headers.get("Origin"), config.CORS_ORIGIN)
    if why:
        return web.json_response({"error": "forbidden", "message": why}, status=403)
    return await handler(request)


@web.middleware
async def _logging_middleware(request: web.Request, handler: Any) -> web.Response:
    req_id = secrets.token_hex(4)
    request["req_id"] = req_id
    t0 = time.monotonic()
    try:
        resp = await handler(request)
    except web.HTTPException as exc:
        _emit_log(req_id=req_id, method=request.method, path=request.path,
                  status=exc.status, ms=(time.monotonic() - t0) * 1000)
        raise
    except Exception as exc:  # noqa: BLE001 — audit then re-raise
        # An unhandled exception in a handler would otherwise vanish from
        # the structured log (aiohttp renders a bare 500 and middleware
        # never logs success). Emit the error class + message so the
        # operator can postmortem from the daemon's error log.
        _emit_log(req_id=req_id, method=request.method, path=request.path,
                  status=500, ms=(time.monotonic() - t0) * 1000,
                  error=type(exc).__name__, message=str(exc)[:200])
        raise
    # /health is polled every ~10s by the macOS client (menu-bar status);
    # a passing poll is never actionable and would be about half the log
    # volume — only log it when it fails.
    if request.path == "/health" and resp.status == 200:
        return resp
    _emit_log(req_id=req_id, method=request.method, path=request.path,
              status=resp.status, ms=(time.monotonic() - t0) * 1000)
    return resp


def _emit_log(**fields: Any) -> None:
    """One-line JSON log record. Guarded by isEnabledFor so the
    `json.dumps` is skipped when logging is suppressed (e.g. WARNING-
    level systemd configurations)."""
    if not log.isEnabledFor(logging.INFO):
        return
    payload = {"t": time.time(), **fields}
    log.info(json.dumps(payload, ensure_ascii=False, default=str))


def main() -> None:
    parser = argparse.ArgumentParser(description="voice-say HTTP daemon")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=config.PORT)
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        stream=sys.stderr,
    )
    # aiohttp's own access logger duplicates every request the
    # `_logging_middleware` above already logs (same method/path/status,
    # minus req_id/latency) — it would double stderr volume for no new
    # information.
    web.run_app(build_app(), host=args.host, port=args.port,
                access_log=None, print=lambda _: None)


if __name__ == "__main__":
    main()
