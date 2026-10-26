"""Tests for the in-memory cache + event ring buffer.

The cache is single-process / single-writer (the daemon owns mutation).
These tests verify the projection from the SQLite store → memory and that
subscribers receive broadcasts via the ring buffer + queue path.
"""
from __future__ import annotations

import asyncio

import pytest

import voice_say._db as _db
from voice_say.state import State


def _seed_db(rows: list[dict]) -> None:
    """Insert render rows, filling the required columns with defaults and
    overlaying each test's given fields."""
    for r in rows:
        full_entry = {
            "ts": r["ts"],
            "kind": "render",
            "backend": "kokoro",
            "voice": "af_alloy",
            "speed": 1.0,
            "format": "mp3",
            "chars": 5,
            "words": 1,
            "duration_s": 0.0,
            "bytes": 100,
            "archive_name": "a.mp3",
            "archive_path": "/tmp/x.mp3",
            "text": "x",
            "tags": [],
        }
        full_entry.update(r)
        _db.insert_render(full_entry)


def test_load_from_disk_hydrates_both_caches(isolated_paths):
    _seed_db([
        {"ts": "2026-05-25T01:00:00Z", "backend": "kokoro", "chars": 5,
         "words": 1, "bytes": 100, "archive_name": "a.mp3"},
        {"ts": "2026-05-25T02:00:00Z", "backend": "kokoro", "chars": 5,
         "words": 1, "bytes": 100, "archive_name": "b.mp3"},
    ])
    _db.upsert_progress({
        "ts": "2026-05-25T01:00:00Z", "played_s": 30.0, "play_count": 1,
        "completed": False, "last_played": "2026-05-25T02:00:00Z",
    })

    s = State()
    s.load_from_disk()
    assert set(s.history.keys()) == {"2026-05-25T01:00:00Z", "2026-05-25T02:00:00Z"}
    assert set(s.progress.keys()) == {"2026-05-25T01:00:00Z"}


def test_load_from_disk_empty_files(isolated_paths):
    """Empty store must not crash the daemon at boot."""
    s = State()
    s.load_from_disk()
    assert s.history == {}
    assert s.progress == {}


def test_record_history_appends_and_bumps_seq(isolated_paths):
    s = State()
    assert s.event_seq == 0
    s.record_history({"ts": "x", "backend": "kokoro"})
    s.record_history({"ts": "y", "backend": "kokoro"})
    assert s.event_seq == 2
    assert list(s.history.keys()) == ["x", "y"]


def test_record_drops_entry_with_missing_ts(isolated_paths):
    s = State()
    s.record_history({"backend": "kokoro"})  # no ts
    s.record_progress({})
    assert s.history == {}
    assert s.progress == {}
    assert s.event_seq == 0


def test_history_newest_first_merges_progress(isolated_paths):
    s = State()
    s.record_history({"ts": "1", "backend": "kokoro"})
    s.record_history({"ts": "2", "backend": "kokoro"})
    s.record_progress({"ts": "1", "played_s": 5.0})

    rows = s.history_newest_first(limit=10)
    assert [r["ts"] for r in rows] == ["2", "1"]
    assert rows[0]["progress"] is None
    assert rows[1]["progress"]["played_s"] == 5.0


def test_history_newest_first_limit_zero_returns_all(isolated_paths):
    s = State()
    for i in range(5):
        s.record_history({"ts": str(i), "backend": "kokoro"})
    rows = s.history_newest_first(limit=0)
    assert len(rows) == 5


async def test_subscribe_emits_snapshot_for_new_subscriber(isolated_paths):
    s = State()
    s.record_history({"ts": "a", "backend": "kokoro"})

    sub = s.iter_events(last_event_id=None)
    first = await asyncio.wait_for(sub.__anext__(), timeout=0.5)
    assert first["type"] == "snapshot"
    assert len(first["history"]) == 1
    await sub.aclose()


async def test_subscribe_replays_ring_buffer(isolated_paths):
    s = State()
    s.record_history({"ts": "a", "backend": "kokoro"})  # seq 1
    s.record_history({"ts": "b", "backend": "kokoro"})  # seq 2
    s.record_progress({"ts": "a", "played_s": 5.0})     # seq 3

    sub = s.iter_events(last_event_id=1)
    events = []
    async def _collect():
        async for ev in sub:
            events.append(ev)
            if len(events) == 2:
                break
    try:
        await asyncio.wait_for(_collect(), timeout=0.5)
    finally:
        await sub.aclose()
    assert [ev["id"] for ev in events] == [2, 3]


async def test_subscribe_stale_id_falls_back_to_snapshot(isolated_paths):
    s = State()
    # Manually shrink the ring so we can simulate "old id aged out" cheaply.
    s.ring.clear()
    # Bump seq past the buffer and add fresh events.
    for i in range(5):
        s.record_history({"ts": f"t{i}", "backend": "kokoro"})
    # Manipulate the ring to simulate eviction of older ids.
    while len(s.ring) > 2:
        s.ring.popleft()

    sub = s.iter_events(last_event_id=1)  # ancient, before ring window
    first = await asyncio.wait_for(sub.__anext__(), timeout=0.5)
    assert first["type"] == "snapshot"
    await sub.aclose()


async def test_subscribe_broadcasts_live_events(isolated_paths):
    s = State()
    sub = s.iter_events(last_event_id=None)
    # Drain the initial snapshot
    _ = await asyncio.wait_for(sub.__anext__(), timeout=0.5)

    s.record_history({"ts": "live", "backend": "kokoro"})
    ev = await asyncio.wait_for(sub.__anext__(), timeout=0.5)
    assert ev["type"] == "render"
    assert ev["ts"] == "live"
    await sub.aclose()


async def test_full_subscriber_queue_is_dropped(isolated_paths):
    """A subscriber whose queue fills up is dropped; other subscribers survive."""
    s = State()
    # Subscribe but never consume → queue fills up
    fast_sub = s.iter_events(last_event_id=None)
    _ = await fast_sub.__anext__()  # drain snapshot

    slow_q = asyncio.Queue(maxsize=2)  # tiny
    s.subscribers.add(slow_q)

    for i in range(10):
        s.record_history({"ts": f"x{i}", "backend": "kokoro"})

    # slow_q got dropped after going full
    assert slow_q not in s.subscribers
    # fast subscriber still works for next event
    s.record_history({"ts": "post", "backend": "kokoro"})
    ev = await asyncio.wait_for(fast_sub.__anext__(), timeout=0.5)
    assert ev["ts"] in {f"x{i}" for i in range(10)} | {"post"}
    await fast_sub.aclose()


async def test_dropped_subscriber_wakes_on_drop_sentinel(isolated_paths):
    """A subscriber kicked out for being slow must receive the _DROP
    sentinel so its iter_events() generator returns cleanly — without the
    sentinel, await q.get() would hang forever after the discard, leaking
    the SSE handler task.
    """
    s = State()
    sub = s.iter_events(last_event_id=None)
    _ = await sub.__anext__()  # consume initial snapshot

    # Find the queue we just registered and force it past capacity by
    # filling beyond the SUBSCRIBER_QUEUE_SIZE without ever consuming.
    assert len(s.subscribers) == 1
    q = next(iter(s.subscribers))

    for i in range(s.SUBSCRIBER_QUEUE_SIZE + 5):
        s.record_history({"ts": f"flood-{i}", "backend": "kokoro"})

    assert q not in s.subscribers  # dropped
    # The next iteration should return (StopAsyncIteration), not hang.
    with pytest.raises(StopAsyncIteration):
        await asyncio.wait_for(sub.__anext__(), timeout=0.5)


def test_reload_from_disk_picks_up_external_appends(isolated_paths):
    """An external process appends a row to the store; the daemon's
    in-memory cache must reflect that row after reload_from_disk without
    needing a restart.
    """
    # Initial state: one row in the store.
    _seed_db([
        {"ts": "2026-05-26T01:00:00Z", "backend": "kokoro", "chars": 5,
         "words": 1, "bytes": 100, "archive_name": "a.mp3"},
    ])
    s = State()
    s.load_from_disk()
    assert set(s.history.keys()) == {"2026-05-26T01:00:00Z"}

    # External append (simulates register-fn.sh).
    _db.insert_render({
        "ts": "2026-05-26T02:00:00Z", "kind": "render", "backend": "qwen3",
        "voice": "af_alloy", "speed": 1.0, "format": "mp3", "chars": 5,
        "words": 1, "duration_s": 0.0, "bytes": 100,
        "archive_name": "ep-99-qwen3.mp3", "archive_path": "/tmp/x.mp3",
        "text": "x", "tags": [],
    })

    counts = s.reload_from_disk()
    assert set(s.history.keys()) == {
        "2026-05-26T01:00:00Z", "2026-05-26T02:00:00Z",
    }
    assert counts["history"] == 2


async def test_reload_broadcasts_reloaded_event(isolated_paths):
    """reload_from_disk should fire a `reloaded` SSE event so connected
    subscribers know to re-fetch (otherwise they'd be staring at the old
    snapshot forever)."""
    s = State()
    s.load_from_disk()

    sub = s.iter_events(last_event_id=None)
    _ = await sub.__anext__()  # consume snapshot

    s.reload_from_disk()

    ev = await asyncio.wait_for(sub.__anext__(), timeout=0.5)
    assert ev["type"] == "reloaded"
    assert "history" in ev and "progress" in ev and "overlays" in ev
    await sub.aclose()


def test_tags_in_use_matches_the_app_formula():
    """Union of render + overlay tags, minus removed_tags, live rows only —
    the vocabulary voice-say checks tags against."""
    s = State()
    s.history = {
        "a": {"ts": "a", "tags": ["applied", "Daily-Notes-v6"]},
        "b": {"ts": "b", "tags": ["news"]},
        "c": {"ts": "c", "tags": ["gone"]},
        "d": {"ts": "d", "tags": ["kept", "dropped"]},
    }
    s.overlays = {
        "a": {"tags": ["map"]},                       # overlay adds, render tags stay
        "c": {"deleted": True},                       # deleted rows don't count
        "d": {"tags": ["extra"], "removed_tags": ["dropped"]},
    }
    assert s.tags_in_use() == ["applied", "daily-notes-v6", "extra", "kept", "map", "news"]


def test_last_event_id_resumes_only_within_this_instance(isolated_paths):
    s = State()
    assert s.wire_event_id(7) == f"{s.instance_id}-7"
    assert s.parse_last_event_id(s.wire_event_id(7)) == 7
    assert s.parse_last_event_id("feedface00000000-7") is None   # earlier daemon
    assert s.parse_last_event_id("7") == 7                       # bare int, as before
    assert s.parse_last_event_id(None) is None
    assert s.parse_last_event_id("") is None
    assert s.parse_last_event_id("junk") is None
    assert s.parse_last_event_id(f"{s.instance_id}-x") is None
