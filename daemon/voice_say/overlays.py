"""User overlays — star / soft-delete / tags / bookmarks per entry.

Persisted in the SQLite store (latest-wins, one row per ts). Disk
mechanics live in `_db.py`; this module owns row-shape validation and the
on-write callback hook.

Schema (the `overlays` table):
  {
    "ts": "...",                     // entry id (render ts)
    "starred": bool,
    "deleted": bool,                 // soft-delete, hide in list
    "tags": ["completed", "draft"],  // user tags, lowercase kebab-case
    "removed_tags": [...],           // suppression list (see write())
    "bookmarks": [
      {"id": "uuid", "position": 0.42, "note": "..."}
    ],
    "title": "...",                  // display title override
    "series": "Daily Notes",         // series name (None = not in a series)
    "episode": 12,                   // episode number within the series
    "last_modified": "2026-05-25T..."
  }

This is mutable client-state, NOT part of the render record. Clearing it
loses bookmarks/stars but never touches audio or render history.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Any, Callable

from . import _db, engine


# Wired by http_server._startup so the in-memory cache picks up each write.
on_overlay_written: Callable[[dict[str, Any]], None] | None = None


read_all = _db.read_overlays_all
read = _db.read_overlay

# Default for series/episode: keep the previous value. (None clears them, so
# "not passed" needs its own marker.)
KEEP: Any = object()


def write(ts: str, *, starred: bool | None = None, deleted: bool | None = None,
          tags: list[str] | None = None,
          removed_tags: list[str] | None = None,
          bookmarks: list[dict[str, Any]] | None = None,
          title: str | None = None,
          series: str | None = KEEP,
          episode: int | None = KEEP,
          prev: dict[str, Any] | None = None) -> dict[str, Any]:
    """Upsert an overlay row. Fields not passed inherit from the previous
    row (latest-wins per field) but the row is stored whole so reads need
    not merge across rows.

    `removed_tags` is a suppression list: tags the user has deleted from
    this entry. Render history (entry.tags) is immutable, so deleting a
    *server* tag can't rewrite it — instead the effective tag set a client
    shows is (server ∪ overlay.tags) − removed_tags.

    `prev` lets the daemon pass its in-memory `state.overlays.get(ts)`
    snapshot. Standalone callers can omit; we fall back to `read(ts)`.

    `series` / `episode`: omitted (KEEP) inherits; None or "" clears. An
    episode must be a whole number >= 0.
    """
    if not ts:
        raise ValueError("ts required")
    if prev is None:
        prev = read(ts) or {}
    # Closed-vocabulary enforcement (allowed_tags): only *added* tags are gated;
    # removed_tags may name a now-disallowed tag the user is clearing.
    new_tags = _clean_tags(tags) if tags is not None else list(prev.get("tags") or [])
    if tags is not None:
        bad = engine.unknown_tags(new_tags)
        if bad:
            raise ValueError(
                f"tag(s) not in allowed_tags: {bad}; "
                f"allowed={sorted(engine.allowed_tag_set())}")
    row: dict[str, Any] = {
        "ts": ts,
        "starred": bool(starred) if starred is not None else bool(prev.get("starred", False)),
        "deleted": bool(deleted) if deleted is not None else bool(prev.get("deleted", False)),
        "tags": new_tags,
        "removed_tags": _clean_tags(removed_tags) if removed_tags is not None
                        else list(prev.get("removed_tags") or []),
        "bookmarks": _clean_bookmarks(bookmarks) if bookmarks is not None
                     else list(prev.get("bookmarks") or []),
        # User-set display title; overrides the client's derived (first-sentence)
        # title. Passing "" clears it back to derived; None inherits prev.
        "title": _clean_title(title) if title is not None else prev.get("title"),
        "series": prev.get("series") if series is KEEP else _clean_title(series or ""),
        "episode": prev.get("episode") if episode is KEEP else _clean_episode(episode),
        "last_modified": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
    }
    _db.upsert_overlay(row)
    if on_overlay_written is not None:
        on_overlay_written(row)
    return row


# Display titles are a single line; cap length so a paste can't bloat the row.
_TITLE_MAX = 200


def _clean_title(title: str) -> str | None:
    """Trim to one line, cap length. Empty → None (clears the override)."""
    s = " ".join(str(title).split()).strip()
    return s[:_TITLE_MAX] if s else None


_EPISODE_MAX = 1_000_000_000


def _clean_episode(ep: Any) -> int | None:
    """None/"" clears; otherwise a whole number 0.._EPISODE_MAX (bools, 1.5,
    inf and nan refused — all as ValueError, so the route answers 400)."""
    if ep is None or ep == "":
        return None
    if isinstance(ep, bool) or not isinstance(ep, (int, float, str)):
        raise ValueError(f"episode must be a whole number, got {ep!r}")
    try:
        n = float(ep)
    except ValueError:
        raise ValueError(f"episode must be a whole number, got {ep!r}") from None
    if not 0 <= n <= _EPISODE_MAX or n != int(n):
        raise ValueError(f"episode must be a whole number >= 0, got {ep!r}")
    return int(n)


def _clean_tags(tags: list[str]) -> list[str]:
    """Normalize + dedupe via the canonical engine helper. Keeps overlay
    storage and `/render` route validation in lockstep."""
    seen: set[str] = set()
    out: list[str] = []
    for t in tags:
        s = engine.normalize_tag(t)
        if s and s not in seen:
            seen.add(s)
            out.append(s)
    return out


def _clean_bookmarks(bms: list[dict[str, Any]]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for b in bms:
        if not isinstance(b, dict):
            continue
        pos = b.get("position")
        if not isinstance(pos, (int, float)) or not (0.0 <= float(pos) <= 1.0):
            continue
        out.append({
            "id": str(b.get("id") or ""),
            "position": float(pos),
            "note": str(b.get("note") or ""),
        })
    return out
