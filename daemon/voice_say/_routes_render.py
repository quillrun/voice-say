"""Render route — POST /render. Handles body validation, dispatches
into `engine.render`, maps `RenderError` to the right HTTP status."""
from __future__ import annotations

import json

import logging
from collections.abc import Awaitable, Callable

from aiohttp import web

from . import _db, config, engine, overlays
from ._keys import HTTPX_KEY, STATE_KEY
from .state import State
from ._validators import (
    json_error,
    parse_json,
    stage_to_status,
    typed_list_of_str,
    typed_number,
    typed_of,
)


log = logging.getLogger("voice_say")



async def _parse_render_body(request: web.Request):
    """Shared body-validation prologue for /render and /render_longform.

    Returns either a `(body, backend, speed, tags, overlay)` tuple on success,
    or a `web.Response` (the json_error envelope) on validation failure —
    callers do `if isinstance(result, web.Response): return result`."""
    body = await parse_json(request)

    if "text" not in body:
        return json_error("request", "missing 'text' field", status=400)
    text = typed_of(body["text"], "text", str, "a string") or ""
    typed_of(body.get("voice"), "voice", str, "a string")
    if not str(text).strip():
        return json_error("request", "text is empty", status=400)
    # DoS guard: a generous abuse ceiling, not a functional limit (config
    # `max_render_chars`; engine.render enforces the same value).
    if len(str(text)) > config.MAX_RENDER_CHARS:
        return json_error("request",
                          f"text too long ({len(str(text))} chars > {config.MAX_RENDER_CHARS} limit)",
                          status=413)

    backend = body.get("backend") or body.get("backend_id") or config.DEFAULT_BACKEND
    if str(backend) not in engine.BACKENDS:
        return json_error("request",
                          f"unknown backend {str(backend)!r} "
                          f"(known: {sorted(engine.BACKENDS)})", status=400)

    speed = typed_number(body.get("speed"), "speed", default=1.0)
    raw_tags = typed_list_of_str(body.get("tags"), "tags") or []
    tags = [t.strip() for t in raw_tags if t.strip()]

    # Display fields set on the new row's overlay once it exists (title,
    # series, episode) — one call instead of render + POST /overlays.
    overlay: dict = {}
    if body.get("title"):
        overlay["title"] = str(body["title"])
    if body.get("series"):
        overlay["series"] = str(body["series"])
    if body.get("episode") not in (None, ""):
        try:
            overlay["episode"] = overlays._clean_episode(body["episode"])
        except ValueError as exc:
            return json_error("request", str(exc), status=400)

    return body, backend, speed, tags, overlay


def _with_saved(resp: web.Response, err: BaseException) -> web.Response:
    """Name the row a failed longform render's finished chunks were saved as
    (engine._salvage): `saved_ts`, and `partial` (true = a resumable draft)."""
    saved = getattr(err, "saved_ts", None)
    if not saved:
        return resp
    body = json.loads(resp.text)
    body.update(saved_ts=saved, partial=bool(getattr(err, "partial", True)))
    return web.json_response(body, status=resp.status)


def _gone(request: web.Request):
    """A probe for engine renders: True once the caller has hung up."""
    return lambda: request.transport is None or request.transport.is_closing()


def _set_overlay(ts: str, overlay: dict | None) -> dict | None:
    """Apply a render's title/series/episode to its row. Best-effort: the
    audio and row exist either way; a failure is logged, not returned."""
    if not overlay:
        return None
    try:
        return overlays.write(ts, **overlay)
    except Exception:  # noqa: BLE001
        log.exception("render %s: could not set %s", ts, sorted(overlay))
        return None


async def _run_render(name: str, coro: Awaitable[dict],
                      overlay: dict | None = None) -> web.Response:
    """Await a render coroutine and map its outcome to the HTTP response:
    entry → 200 JSON; RenderCancelled (a streaming episode cancelled via
    /episode/<id>/cancel — NO row written, the SSE already told the client) →
    200 with a cancelled marker so the long POST resolves cleanly;
    RenderError → its stage's status; anything else → a generic 500 (full
    detail is logged server-side so a 500 body never leaks internal
    paths/exception text)."""
    try:
        entry = await coro
    except engine.RenderCancelled as cancelled:
        return web.json_response(
            {"cancelled": True, "episode_id": cancelled.episode_id}, status=200)
    except engine.ClientGone:
        # Nobody is listening; the status only reaches the log.
        log.info("%s dropped: client disconnected while queued", name)
        return json_error("request", "client disconnected while queued", status=499)
    except engine.RenderError as err:
        log.warning("%s failed at %s: %s", name, err.stage, err.message)
        resp = json_error(err.stage, err.message, status=stage_to_status(err.stage))
        if getattr(err, "saved_ts", None):
            _set_overlay(err.saved_ts, overlay)
        return _with_saved(resp, err)
    except Exception as exc:  # noqa: BLE001 — last-resort handler
        log.exception("%s crashed", name)
        if getattr(exc, "saved_ts", None):
            _set_overlay(exc.saved_ts, overlay)
        return _with_saved(json_error("internal", "internal render error", status=500), exc)

    log.info("%s ok: %s (%d chars, backend=%s, voice=%s)", name,
             entry["archive_name"], entry["chars"], entry["backend"], entry["voice"])
    row = _set_overlay(entry["ts"], overlay)
    if row is not None:
        entry = {**entry, "overlay": row}
    return web.json_response(entry)


async def render(request: web.Request) -> web.Response:
    result = await _parse_render_body(request)
    if isinstance(result, web.Response):
        return result
    body, backend, speed, tags, overlay = result
    text = body["text"] or ""

    return await _run_render("render", engine.render(
        text,
        backend_id=str(backend),
        voice=body.get("voice"),
        speed=speed,
        tags=tags,
        httpx_client=request.app[HTTPX_KEY],
        is_gone=_gone(request),
    ), overlay)


async def render_longform(request: web.Request) -> web.Response:
    """POST /render_longform — chunked longform render. Same body shape + the same
    RenderError→status mapping as /render. Chunks the text, renders each
    chunk serially to WAV, concatenates gaplessly into ONE mp3, and writes
    exactly ONE archive file + ONE db row (see engine.render_longform)."""
    result = await _parse_render_body(request)
    if isinstance(result, web.Response):
        return result
    body, backend, speed, tags, overlay = result
    text = body["text"] or ""

    # Render mode: "stream" (default — progressive per-chunk broadcast, so
    # every client's episode shows live in the app, whoever started it) or
    # "sequential" (no broadcasts). This 400 is a fast-fail mirror of engine's
    # render_longform mode guard — both validate against engine.LONGFORM_MODES.
    mode = body.get("mode") or "stream"
    if mode not in engine.LONGFORM_MODES:
        return json_error("request", f"unknown mode {mode!r}", status=400)

    # In stream mode the engine broadcasts episode_start/chunk_ready/
    # episode_complete via State.broadcast — the SAME public ephemeral path
    # the canonical render event rides. None for sequential (no streaming).
    state = request.app[STATE_KEY]
    on_episode_event = _episode_broadcaster(state, body, overlay) if mode == "stream" else None

    return await _run_render("render_longform", engine.render_longform(
        text,
        backend_id=str(backend),
        voice=body.get("voice"),
        speed=speed,
        tags=tags,
        httpx_client=request.app[HTTPX_KEY],
        mode=mode,
        on_episode_event=on_episode_event,
        episode_registry=state.episodes,
        mock=bool(body.get("mock")),
        is_gone=_gone(request),
    ), overlay)


def _episode_broadcaster(state: State, body: dict,
                         display: dict | None = None) -> Callable[[dict], None]:
    """State.broadcast that stamps episode_start with the request's optional
    `client_ref` (so a client can tell its own episode from one another client
    — an agent, the CLI — started) and with the display fields the row will
    get (title / series / episode, each only when set), so a live render shows
    what it is before its row exists."""
    extra: dict = {k: v for k, v in (display or {}).items()
                   if k in ("title", "series", "episode") and v not in (None, "")}
    ref = str(body.get("client_ref") or "")[:64]
    if ref:
        extra["client_ref"] = ref
    if not extra:
        return state.broadcast

    def send(ev: dict) -> None:
        state.broadcast({**ev, **extra} if ev.get("type") == "episode_start" else ev)
    return send


def _draft_display(draft_ts: str) -> dict:
    """The draft's title / series / episode, which a resume carries onto its
    continuation — stamped on the resume's episode_start. Best-effort."""
    try:
        ov = _db.read_overlay(draft_ts) or {}
    except Exception:  # noqa: BLE001 — display only
        return {}
    return {k: ov.get(k) for k in ("title", "series", "episode")}


async def episode_resume(request: web.Request) -> web.Response:
    """POST /episode/resume — continue a finalized-early draft.

    Body: {"from_ts": "<draft render ts>"}. The daemon re-chunks the draft's
    stored full text, skips the already-rendered prefix, renders the remainder,
    concatenates [draft mp3 + new chunks] into ONE new canonical row, and
    supersedes the draft (overlay deleted=true). Drives the SAME streaming SSE
    contract (episode_start/chunk_ready/episode_complete) as a fresh stream
    render, so the client reuses the play-while-render UI with no new events."""
    body = await parse_json(request)
    draft_ts = body.get("from_ts")
    if not draft_ts:
        return json_error("request", "missing 'from_ts'", status=400)

    state = request.app[STATE_KEY]
    # Guard against a double-fired resume of the SAME draft (double-click on
    # "Continue render" / a client retry): each would render the remainder and
    # write its own duplicate superset row. Allow ONE in-flight resume per
    # draft_ts; 409 the rest until it finishes (released in the finally).
    if not state.episodes.begin_resume(str(draft_ts)):
        return json_error(
            "conflict", f"a resume is already in progress for {draft_ts!r}",
            status=409)
    try:
        return await _run_render("episode_resume", engine.resume_longform(
            str(draft_ts),
            httpx_client=request.app[HTTPX_KEY],
            on_episode_event=_episode_broadcaster(state, body, _draft_display(str(draft_ts))),
            episode_registry=state.episodes,
        ))
    finally:
        state.episodes.end_resume(str(draft_ts))


async def episode_cancel(request: web.Request) -> web.Response:
    """POST /episode/{episode_id}/cancel — abort an in-flight streaming render.

    The render task (still inside its open /render_longform POST) sees the
    flag between chunks — and has its current chunk synth cancelled — then
    drops its transient chunks, writes NO canonical row, and emits
    episode_cancelled on the SSE bus. 404 if the id is not a currently
    rendering episode (already finished, or never existed); 409 once the
    episode is past its chunks and saving."""
    episode_id = request.match_info["episode_id"]
    state = request.app[STATE_KEY]
    # Too late once the chunks are in and the save has begun: say so instead
    # of answering ok while the row is written anyway.
    if state.episodes.is_finishing(episode_id):
        return json_error("conflict", "episode is already being saved; it can "
                          "no longer be cancelled (delete it once it lands)",
                          status=409)
    if not state.episodes.request_cancel(episode_id):
        return json_error("not_found", f"no active episode {episode_id!r}",
                          status=404)
    return web.json_response(
        {"ok": True, "episode_id": episode_id, "action": "cancel"})


async def episode_finalize(request: web.Request) -> web.Response:
    """POST /episode/{episode_id}/finalize — save-and-stop a streaming render.

    The render task finishes the in-flight chunk, stops starting new ones,
    concatenates what it has into the ONE canonical mp3 + row (tagged
    "draft"), and emits the normal episode_complete (save_and_stop=true).
    404 if the id is not currently rendering."""
    episode_id = request.match_info["episode_id"]
    state = request.app[STATE_KEY]
    if not state.episodes.request_finalize(episode_id):
        return json_error("not_found", f"no active episode {episode_id!r}",
                          status=404)
    return web.json_response(
        {"ok": True, "episode_id": episode_id, "action": "finalize"})


async def episode_force_finalize(request: web.Request) -> web.Response:
    """POST /episode/{episode_id}/force_finalize — save-and-stop NOW.

    Like /finalize it keeps the already-completed chunks as the ONE canonical
    row (tagged "draft") and emits episode_complete (save_and_stop=true). UNLIKE
    /finalize it does NOT wait for the in-flight chunk to finish — that chunk's
    synth is cancelled and dropped, so a long final chunk no longer holds the
    user on the "wrapping up" spinner. If no chunk has completed yet there
    is nothing to keep, so it falls back to a cancel (no row). 404 if the id is
    not currently rendering."""
    episode_id = request.match_info["episode_id"]
    state = request.app[STATE_KEY]
    if not state.episodes.request_force_finalize(episode_id):
        return json_error("not_found", f"no active episode {episode_id!r}",
                          status=404)
    return web.json_response(
        {"ok": True, "episode_id": episode_id, "action": "force_finalize"})
