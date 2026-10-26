"""SQLite/voice.db read-side surfaces (history/search/progress/overlays/
audio) served from the in-memory state cache. Plus the /reload escape
hatch — they all read from `state.history` so they live together.
"""
from __future__ import annotations

from pathlib import Path

from aiohttp import web

from . import _db, _sinks, engine, overlays, progress
from ._keys import STATE_KEY
from ._validators import json_error, parse_json, typed_list_of_str, typed_of
from .state import State


def _clamp_limit(raw: str, default: int) -> int:
    """Parse a `limit` query value and clamp to [1, MAX_HISTORY_LIMIT]. Both
    state.history_newest_first and _db.search treat limit<=0 as "all" (internal
    use only); this guard makes sure the HTTP surface never exposes that."""
    try:
        n = int(raw)
    except ValueError:
        n = default
    return max(1, min(n, _db.MAX_HISTORY_LIMIT))


async def history(request: web.Request) -> web.Response:
    """Newest first, or with `?series=NAME` that series in episode order."""
    limit = _clamp_limit(request.query.get("limit", "200"), 200)
    state: State = request.app[STATE_KEY]
    series = request.query.get("series")
    if series:
        entries = state.series_in_order(series)[:limit]
    else:
        entries = state.history_newest_first(limit=limit)
    return web.json_response({"entries": entries, "total": len(entries)})


async def search(request: web.Request) -> web.Response:
    """Full-text transcript search (FTS5), newest-first. `q` is the query;
    `limit` clamps results. Progress + overlay are merged in like /history
    so a hit row renders the same as a list row."""
    q = request.query.get("q", "")
    limit = _clamp_limit(request.query.get("limit", "50"), 50)
    state: State = request.app[STATE_KEY]
    hits = _db.search(q, limit=limit)
    entries = [{
        **e,
        "progress": state.progress.get(e.get("ts")),
        "overlay": state.overlays.get(e.get("ts")),
    } for e in hits]
    return web.json_response({"entries": entries, "total": len(entries)})


async def progress_get(request: web.Request) -> web.Response:
    ts = request.match_info["ts"]
    state: State = request.app[STATE_KEY]
    row = state.progress.get(ts)
    if row is None:
        return json_error("not_found", ts, status=404)
    return web.json_response(row)


def _no_render(state: State, ts: str) -> web.Response | None:
    """404 for a write to a ts with no render row. Without it a typo, a
    streaming card's provisional id or a deleted render left orphan
    progress/overlay rows behind."""
    if ts in state.history or _db.get_render(ts) is not None:
        return None
    return json_error("not_found", f"no render with ts={ts}", status=404)


async def progress_post(request: web.Request) -> web.Response:
    ts = request.match_info["ts"]
    if (missing := _no_render(request.app[STATE_KEY], ts)) is not None:
        return missing
    body = await parse_json(request)
    if "played_s" not in body:
        return json_error("request", "missing 'played_s'", status=400)
    state: State = request.app[STATE_KEY]
    try:
        row = progress.write(
            ts,
            played_s=float(body["played_s"]),
            duration_s=float(body["duration_s"]) if body.get("duration_s") is not None else None,
            completed=bool(body["completed"]) if "completed" in body else None,
            started=bool(body.get("started", False)),
            prev=state.progress.get(ts),  # avoid a per-tick db read
        )
    except (ValueError, TypeError) as exc:
        # TypeError covers non-numeric JSON (e.g. {"played_s": null} →
        # float(None)); both are client-input errors, not server faults.
        return json_error("request", str(exc), status=400)
    return web.json_response(row)


async def overlays_get(request: web.Request) -> web.Response:
    ts = request.match_info["ts"]
    state: State = request.app[STATE_KEY]
    row = state.overlays.get(ts)
    if row is None:
        return json_error("not_found", ts, status=404)
    return web.json_response(row)


async def overlays_post(request: web.Request) -> web.Response:
    ts = request.match_info["ts"]
    if (missing := _no_render(request.app[STATE_KEY], ts)) is not None:
        return missing
    body = await parse_json(request)
    state: State = request.app[STATE_KEY]
    prev = state.overlays.get(ts) or {}

    for flag in ("starred", "deleted"):
        typed_of(body.get(flag), flag, bool, "true or false")
    typed_list_of_str(body.get("tags"), "tags")
    typed_list_of_str(body.get("removed_tags"), "removed_tags")
    typed_of(body.get("bookmarks"), "bookmarks", list, "a list")
    typed_of(body.get("title"), "title", str, "a string")
    try:
        row = overlays.write(
            ts,
            starred=body.get("starred"),
            deleted=body.get("deleted"),
            tags=body.get("tags"),
            removed_tags=body.get("removed_tags"),
            bookmarks=body.get("bookmarks"),
            title=body.get("title"),
            series=body["series"] if "series" in body else overlays.KEEP,
            episode=body["episode"] if "episode" in body else overlays.KEEP,
            prev=prev,
        )
    except ValueError as exc:
        return json_error("request", str(exc), status=400)
    return web.json_response(row)


# Mime types we can serve. Anything else falls back to octet-stream so
# the daemon never echoes a wrong audio/* type the client would mishandle.
_AUDIO_MIME = {"mp3": "audio/mpeg", "wav": "audio/wav", "pcm": "audio/L16"}


async def audio(request: web.Request) -> web.Response:
    """Stream the mp3 for a render. Path-traversal guard: the resolved
    archive path must live inside ARCHIVE_ROOT, refusing a maliciously-
    seeded entry pointing at /etc/passwd with 403.
    """
    ts = request.match_info["ts"]
    state: State = request.app[STATE_KEY]
    entry = state.history.get(ts)
    if entry is None:
        return json_error("not_found", f"no render with ts={ts}", status=404)
    archive_path = entry.get("archive_path")
    if not archive_path:
        return json_error("not_found", "entry has no archive_path", status=404)
    p = Path(archive_path).resolve()
    try:
        p.relative_to(engine.ARCHIVE_ROOT.resolve())
    except ValueError:
        return json_error("forbidden", "archive_path escapes ARCHIVE_ROOT", status=403)
    found = _sinks.locate_audio(p)
    if found is None:
        return json_error("archived", f"audio file not on disk: {p}", status=404)
    p = found
    fmt = entry.get("format", "mp3")
    mime = _AUDIO_MIME.get(fmt, "application/octet-stream")
    return web.FileResponse(
        p,
        headers={"Content-Type": mime,
                 "Content-Disposition": f'inline; filename="{p.name}"'},
    )


async def align(request: web.Request) -> web.Response:
    """Measure one render's word timings now (align.py) and store them as its
    read-along seam_map; the reader picks them up from the re-announced row.
    For rows without word timings (`voice-say align`)."""
    ts = request.match_info["ts"]
    if engine.aligner is None:
        return json_error("unavailable", "read-along alignment is off "
                          "(align = false, or the helper not built: make setup)", status=503)
    if _db.get_render(ts) is None:
        return json_error("not_found", f"no render with ts={ts}", status=404)
    points = await engine.align_entry(ts)
    if points is None:
        return json_error("align_failed", "alignment failed or the audio is "
                          "missing; the row keeps its seams (see the daemon log)", status=422)
    return web.json_response({"ok": True, "ts": ts, "points": points})


async def reload(request: web.Request) -> web.Response:
    """Re-hydrate the in-memory cache from the SQLite store. External
    processes (a manual sqlite3 write, a restore from backup, another tool)
    call this after writing to voice.db so VoiceSay + SSE
    subscribers see the new rows without a daemon restart."""
    state: State = request.app[STATE_KEY]
    counts = state.reload_from_disk()
    return web.json_response({"ok": True, "counts": counts})
