"""Per-entry playback progress, persisted in the SQLite store (latest-wins).

Schema (the `progress` table, one row per ts):
  {"ts": "...", "played_s": 12.3, "duration_s": 45.6,
   "play_count": 2, "completed": false, "last_played": "..."}

Disk mechanics live in `_db.py`; this module owns the row-shape contract
(play_count accounting, duration stickiness) and the on-write callback hook.

This is mutable client-state; it is NOT part of the render record. It can
be cleared without losing render history — just resets the "played to
here" memory.
"""
from __future__ import annotations

import math
from datetime import datetime, timezone
from typing import Any, Callable

from . import _db


# Wired by http_server._startup so the in-memory cache picks up each write.
on_progress_written: Callable[[dict[str, Any]], None] | None = None


read_all = _db.read_progress_all
read = _db.read_progress


def write(
    ts: str,
    *,
    played_s: float,
    duration_s: float | None = None,
    completed: bool | None = None,
    started: bool = False,
    prev: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Upsert a progress row and return the resulting aggregate state.

    started=True bumps play_count; use it on the first POST of a new
    playback session (when the player swaps in a new entry). Subsequent
    ticks during the same session pass started=False so play_count
    reflects sessions, not heartbeats.

    `prev` is the previous row to inherit from. The daemon passes
    `state.progress.get(ts)` so the write path stays O(1). When omitted we
    fall back to `read(ts)`.
    """
    if not ts:
        raise ValueError("ts required")
    # json.loads accepts NaN/Infinity by default, so reject non-finite floats
    # before they poison the cached aggregate.
    if not math.isfinite(played_s):
        raise ValueError("played_s must be finite")
    if played_s < 0:
        raise ValueError("played_s must be >= 0")
    if duration_s is not None and not math.isfinite(duration_s):
        raise ValueError("duration_s must be finite")
    if duration_s is not None and duration_s < 0:
        raise ValueError("duration_s must be >= 0")

    if prev is None:
        prev = read(ts) or {}
    play_count = int(prev.get("play_count") or 0) + (1 if started else 0)
    row: dict[str, Any] = {
        "ts": ts,
        "played_s": float(played_s),
        "play_count": play_count,
        "completed": bool(completed) if completed is not None else bool(prev.get("completed", False)),
        "last_played": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ"),
    }
    # duration_s sticks once known — caller may omit on follow-up writes.
    if duration_s is not None:
        row["duration_s"] = float(duration_s)
    elif "duration_s" in prev:
        row["duration_s"] = float(prev["duration_s"])
    _db.upsert_progress(row)
    if on_progress_written is not None:
        on_progress_written(row)
    return row
