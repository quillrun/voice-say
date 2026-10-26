"""Catalog + config + tag-vocab + playback-coordination routes.

These are small enough to live together; splitting them per-endpoint
would be one-handler-per-file dust.
"""
from __future__ import annotations

import asyncio
import logging
import os
import time
from typing import Any

from aiohttp import web
import httpx

from . import __version__, _db, align, engine
from . import config as cfg
from ._keys import HTTPX_KEY, STATE_KEY
from ._validators import json_error, parse_json
from .state import State


log = logging.getLogger("voice_say")


async def health(request: web.Request) -> web.Response:
    body: dict[str, Any] = {
        "status": "ok",
        "version": __version__,
        "db_path": str(cfg.DB_PATH),
        "archive_root": str(engine.ARCHIVE_ROOT),
        # Render queue: callers waiting for their turn, and how long the
        # running episode (if any) has been going.
        "queue": engine._GATE.snapshot(),
        # Read-along alignment: on or off, the file being aligned, the queue.
        "alignment": {"on": engine.aligner is not None, "running": align.running,
                      "waiting": align.waiting},
    }
    if request.query.get("deep") == "1":
        body["backends"] = await _deep_probe_backends(request.app[HTTPX_KEY])
    return web.json_response(body)


async def _deep_probe_backends(client: httpx.AsyncClient) -> dict[str, str]:
    results: dict[str, str] = {}
    for bid, backend in engine.BACKENDS.items():
        try:
            r = await client.get(f"{backend.base_url}/", timeout=1.5)
            results[bid] = "up" if r.status_code < 500 else "down"
        except Exception:  # noqa: BLE001 — one bad backend must not 500 the probe
            results[bid] = "down"
    return results


def _config_body() -> dict[str, Any]:
    return {
        "version": __version__,
        # Read the LIVE value from config (refreshed by cfg.reload() after a
        # POST /config write) so a written threshold echoes back correctly.
        "say_threshold_chars": cfg.SAY_THRESHOLD_CHARS,
        "backends": engine.list_backends(),
        "default_backend": cfg.DEFAULT_BACKEND,
        "default_voice": cfg.DEFAULT_VOICE,
        "allowed_tags": cfg.ALLOWED_TAGS,
        # Absolute paths (same host as clients) so the app resolves audio
        # without compiling in any location.
        "archive_root": str(engine.ARCHIVE_ROOT),
        "db_path": str(cfg.DB_PATH),
    }


async def config(request: web.Request) -> web.Response:
    await engine.refresh_voices(request.app[HTTPX_KEY])
    return web.json_response(_config_body())


async def config_post(request: web.Request) -> web.Response:
    """Persist the runtime-mutable defaults (default_backend / default_voice)
    to config.local.toml and live-reload them. Validated against the active
    backend catalog so a bad id/voice can never be written.

    Persisting here makes the choice authoritative for every surface — the
    `voice-say` CLI (`render` included) and the macOS app all read the same
    `config.DEFAULT_BACKEND` at render time.
    """
    body = await parse_json(request)
    updates: dict[str, Any] = {}
    warnings: list[str] = []

    # default_backend: must be a known backend id.
    if "default_backend" in body:
        be = body["default_backend"]
        if not isinstance(be, str) or be not in engine.BACKENDS:
            return json_error("request",
                              f"unknown default_backend {be!r}", status=400)
        updates["default_backend"] = be
        if cfg.env_overrides_default_backend():
            warnings.append("VOICE_SAY_DEFAULT_BACKEND env var shadows the "
                            "written value until it is unset")

    # default_voice: null/""/"default" clears it (backend picks its own).
    # Any other string is accepted as-is — we do NOT require membership in the
    # backend's advertised `voices` list, because /render passes the voice
    # straight through to the backend (the advertised list drives UI pickers,
    # it is not an allowlist). A voice the server has but doesn't list works at
    # render time. The macOS picker still constrains
    # normal app users to advertised voices.
    if "default_voice" in body:
        voice = body["default_voice"]
        if voice in (None, "", "default"):
            updates["default_voice"] = ""   # "" round-trips to None via _val
        elif not isinstance(voice, str):
            return json_error("request", "default_voice must be a string", status=400)
        else:
            updates["default_voice"] = voice
        if cfg.env_overrides_default_voice():
            warnings.append("VOICE_SAY_DEFAULT_VOICE env var shadows the "
                            "written value until it is unset")

    # say_threshold_chars: int >= 0. Renders <= this many chars classify as
    # kind="say". Runtime-mutable so the macOS Settings panel can tune it.
    if "say_threshold_chars" in body:
        raw = body["say_threshold_chars"]
        try:
            n = int(raw)
        except (TypeError, ValueError):
            return json_error("request",
                              "say_threshold_chars must be an integer", status=400)
        if n < 0:
            return json_error("request",
                              "say_threshold_chars must be >= 0", status=400)
        updates["say_threshold_chars"] = n
        if cfg.env_overrides_say_threshold_chars():
            warnings.append("VOICE_SAY_SAY_THRESHOLD_CHARS env var shadows the "
                            "written value until it is unset")

    if not updates:
        return json_error("request",
                          "no writable keys (default_backend, default_voice, "
                          "say_threshold_chars)",
                          status=400)

    try:
        path = cfg.write_local(updates)
    except cfg.ConfigError as e:
        return json_error("config", str(e), status=409)
    except OSError:
        log.exception("config write failed")
        return json_error("config", "could not write config", status=500)
    cfg.reload()

    log.info("config updated via POST: %s → %s", updates, path)
    resp = _config_body()
    if warnings:
        resp["warnings"] = warnings
    return web.json_response(resp)


async def backends(request: web.Request) -> web.Response:
    await engine.refresh_voices(request.app[HTTPX_KEY])
    return web.json_response(engine.list_backends())


_RESTART_UP_WAIT_S = 30.0


async def backend_restart(request: web.Request) -> web.Response:
    """POST /backends/{backend}/restart — `launchctl kickstart -k` on the
    backend's catalog launchd label, then wait for it to answer. Only a catalog
    id is accepted (never a free label), and it refuses while a render runs or
    waits. The daemon runs it so a client that may POST to loopback but cannot
    run launchctl itself (a sandboxed tool, say) can still restart a backend."""
    bid = request.match_info["backend"]
    backend = engine.BACKENDS.get(bid)
    if backend is None:
        return json_error("not_found", f"unknown backend {bid!r}", 404)
    svc = backend.service or {}
    if svc.get("kind") != "launchd" or not svc.get("label"):
        return json_error("no_service", f"backend {bid!r} has no launchd service to restart", 409)
    if engine._GATE.busy():   # includes a single /render holding the backend
        return json_error("busy", "a render is running or queued; retry when the queue is empty", 409)
    label = str(svc["label"])
    target = f"gui/{os.getuid()}/{label}"
    try:
        proc = await asyncio.create_subprocess_exec(
            "launchctl", "kickstart", "-k", target,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        _, err = await asyncio.wait_for(proc.communicate(), timeout=20)
    except (OSError, asyncio.TimeoutError) as exc:
        return json_error("launchctl", f"launchctl kickstart -k {target}: {exc}", 502)
    if proc.returncode != 0:
        return json_error("launchctl",
                          f"launchctl kickstart -k {target} exited {proc.returncode}: "
                          f"{err.decode(errors='replace').strip()}", 502)
    client = request.app[HTTPX_KEY]
    t0 = time.monotonic()
    up = False
    while time.monotonic() - t0 < _RESTART_UP_WAIT_S:
        try:
            r = await client.get(f"{backend.base_url}/", timeout=1.5)
            if r.status_code < 500:
                up = True
                break
        except Exception:  # noqa: BLE001 — not up yet
            pass
        await asyncio.sleep(0.5)
    log.info("backend %s restarted (%s): %s after %.1f s", bid, label,
             "up" if up else "not answering", time.monotonic() - t0)
    return web.json_response({"backend": bid, "label": label, "restarted": True,
                              "up": up, "waited_s": round(time.monotonic() - t0, 1)})


async def voices(request: web.Request) -> web.Response:
    bid = request.match_info["backend_id"]
    if bid not in engine.BACKENDS:
        return json_error("unknown_backend", bid, status=404)
    await engine.refresh_voices(request.app[HTTPX_KEY], only=bid)
    return web.json_response({"backend": bid, "voices": engine.list_voices(bid)})


async def stats(request: web.Request) -> web.Response:
    """Lifetime totals (never decrease, survive deleted recordings) next to
    what the library holds on disk now."""
    return web.json_response({"lifetime": _db.lifetime(), "library": _db.library()})


async def tags(request: web.Request) -> web.Response:
    """Distinct tags currently in use across history. Open vocabulary —
    new tags appear here as soon as any render or overlay-edit uses them."""
    state: State = request.app[STATE_KEY]
    return web.json_response({"tags": state.tags_in_use()})


async def playback_active(request: web.Request) -> web.Response:
    """Broadcast a `playback_active` SSE event so other surfaces can
    pause themselves and avoid doubled audio."""
    body = await parse_json(request)
    source = str(body.get("source") or "").strip()
    ts = str(body.get("ts") or "").strip()
    if not source:
        return json_error("request", "missing 'source'", status=400)
    state: State = request.app[STATE_KEY]
    state.broadcast({"type": "playback_active", "source": source, "ts": ts})
    return web.json_response({"ok": True})
