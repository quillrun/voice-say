"""Runtime state — the daemon's in-memory cache.

Single-process, single-writer (only the daemon mutates the SQLite store),
so we can serve /history and /progress reads from RAM with no concurrency
gymnastics. The `voice.db` store (`_db.py`) is the durability layer; this
cache is purely the read-side projection, hydrated from it at startup.

Layout:
- `history`: ts -> entry, insertion-ordered (so newest-last is just the
  reverse iteration; matches engine.read_history's "newest-first" output).
- `progress`: ts -> latest progress row, last-write-wins.
- `event_seq` + `ring`: monotonically-increasing event id + bounded buffer
  of recent events, for SSE delivery + resume.
- `subscribers`: live SSE subscriber queues; broadcast on every record_*.

The hooks `engine.on_history_appended` and `progress.on_progress_written`
get wired to `record_history` / `record_progress` at daemon startup so
every write path lands in the cache after the voice.db write succeeds.
"""
from __future__ import annotations

import asyncio
import secrets
from collections import deque
from typing import Any, AsyncIterator

from . import engine
from . import progress
from . import overlays
from ._episode_registry import EpisodeRegistry


class State:
    """Mutable runtime state. Lives on `app["state"]`."""

    RING_SIZE = 256
    SUBSCRIBER_QUEUE_SIZE = 64
    # Sentinel sent to a subscriber's queue when they get kicked out for
    # being too slow. `iter_events()` returns when it sees this, so the
    # SSE handler unwinds cleanly instead of hanging on q.get() forever.
    _DROP = object()

    def __init__(self) -> None:
        self.history: dict[str, dict[str, Any]] = {}
        self.progress: dict[str, dict[str, Any]] = {}
        self.overlays: dict[str, dict[str, Any]] = {}
        self.event_seq: int = 0
        self.ring: deque[tuple[int, dict[str, Any]]] = deque(maxlen=self.RING_SIZE)
        self.subscribers: set[asyncio.Queue[Any]] = set()
        # Per-process random tag, carried in every SSE `id:` line
        # (`<instance_id>-<seq>`, see wire_event_id). A client echoes the id
        # back as Last-Event-ID, so after a daemon restart the instance no
        # longer matches and the client gets a snapshot instead of a replay
        # of the NEW process's ring from an id that belonged to the old one
        # (which skipped every event up to that number).
        self.instance_id: str = secrets.token_hex(8)
        # In-flight streaming episodes keyed by episode_id, so the cancel /
        # finalize routes can signal a long-running render_longform task.
        self.episodes = EpisodeRegistry()


    def load_from_disk(self) -> None:
        """One-shot at startup: hydrate caches from voice.db (the SQLite store)."""
        rows = engine.read_history(limit=0)
        # engine.read_history returns newest-first; rebuild as insertion-
        # ordered oldest->newest so iteration order matches append order.
        for entry in reversed(rows):
            ts = entry.get("ts")
            if ts:
                self.history[ts] = entry
        self.progress = progress.read_all()
        self.overlays = overlays.read_all()

    def reload_from_disk(self) -> dict[str, int]:
        """Re-hydrate caches from voice.db. Use when an external
        process has written to voice.db out-of-band and clients need to pick up
        the new state without a daemon restart.
        Broadcasts a `reloaded` event so SSE subscribers can re-fetch.

        Returns post-reload counts so callers can verify the size delta.
        """
        # Full reset so entries deleted on disk don't linger in the
        # cache. progress.read_all / overlays.read_all
        # already return fresh dicts, but history is built by iteration.
        self.history.clear()
        self.load_from_disk()
        counts = {
            "history": len(self.history),
            "progress": len(self.progress),
            "overlays": len(self.overlays),
        }
        self._broadcast({"type": "reloaded", **counts})
        return counts


    def record_history(self, entry: dict[str, Any]) -> None:
        ts = entry.get("ts")
        if not ts:
            return
        self.history[ts] = entry
        self._broadcast({"type": "render", "ts": ts, "entry": entry})

    def record_progress(self, row: dict[str, Any]) -> None:
        ts = row.get("ts")
        if not ts:
            return
        self.progress[ts] = row
        self._broadcast({"type": "progress", "ts": ts, "progress": row})

    def record_overlay(self, row: dict[str, Any]) -> None:
        ts = row.get("ts")
        if not ts:
            return
        self.overlays[ts] = row
        self._broadcast({"type": "overlay", "ts": ts, "overlay": row})


    def history_newest_first(self, limit: int) -> list[dict[str, Any]]:
        """Return entries newest-first with progress + overlay merged in.
        Limit <= 0 returns all rows."""
        rows = list(reversed(self.history.values()))
        if limit > 0:
            rows = rows[:limit]
        return [{
            **r,
            "progress": self.progress.get(r.get("ts")),
            "overlay": self.overlays.get(r.get("ts")),
        } for r in rows]

    def series_in_order(self, name: str) -> list[dict[str, Any]]:
        """One series (name matched case-insensitively), soft-deleted rows
        left out, in episode order (no number last, then by render time);
        progress + overlay merged in like history_newest_first."""
        key = " ".join(name.split()).casefold()     # stored names are whitespace-collapsed
        rows = []
        for ts, entry in self.history.items():
            ov = self.overlays.get(ts) or {}
            if (ov.get("series") or "").casefold() != key or ov.get("deleted"):
                continue
            rows.append(({**entry, "progress": self.progress.get(ts), "overlay": ov},
                         ov.get("episode")))
        rows.sort(key=lambda r: (r[1] is None, r[1] or 0, r[0].get("ts") or ""))
        return [r[0] for r in rows]

    def tags_in_use(self) -> list[str]:
        """Distinct normalized tags on live (not deleted) rows — the same
        formula the app shows per row: render tags ∪ overlay tags, minus the
        overlay's removed_tags. This is the vocabulary `voice-say render --tag` and
        `voice-say set --tag` are checked against."""
        seen: set[str] = set()
        for ts, entry in self.history.items():
            ov = self.overlays.get(ts) or {}
            if ov.get("deleted"):
                continue
            removed = {engine.normalize_tag(t) for t in (ov.get("removed_tags") or [])}
            for t in list(entry.get("tags") or []) + list(ov.get("tags") or []):
                n = engine.normalize_tag(t)
                if n and n not in removed:
                    seen.add(n)
        return sorted(seen)


    def broadcast(self, event: dict[str, Any]) -> None:
        """Public broadcast entry point — used by ephemeral events
        (playback coordination) that don't have a corresponding cache
        mutator. Internal mutators (record_history etc.) go through
        `_broadcast` directly."""
        self._broadcast(event)

    def _broadcast(self, event: dict[str, Any]) -> None:
        self.event_seq += 1
        event_with_id = {"id": self.event_seq, **event}
        self.ring.append((self.event_seq, event_with_id))
        dead: list[asyncio.Queue[Any]] = []
        for q in self.subscribers:
            try:
                q.put_nowait(event_with_id)
            except asyncio.QueueFull:
                dead.append(q)
        for q in dead:
            self.subscribers.discard(q)
            # Drain the consumer's queue so we can hand them the _DROP
            # sentinel — they'll wake on the next `q.get()`, see the
            # sentinel, and `iter_events()` returns. Without this, a
            # slow consumer hangs forever after draining their buffered
            # events because put_nowait(_DROP) hits QueueFull silently.
            while not q.empty():
                try:
                    q.get_nowait()
                except asyncio.QueueEmpty:
                    break
            try:
                q.put_nowait(self._DROP)
            except asyncio.QueueFull:
                pass  # shouldn't happen; queue was just drained

    def snapshot(self) -> dict[str, Any]:
        """Full state dump used when a reconnecting client's Last-Event-Id
        has fallen out of the ring buffer (or the daemon has restarted —
        see `instance_id`)."""
        return {
            "type": "snapshot",
            "id": self.event_seq,
            "instance_id": self.instance_id,
            "history": list(reversed(self.history.values())),
            "progress": self.progress,
            "overlays": self.overlays,
        }

    async def iter_events(
        self,
        last_event_id: int | None = None,
        *,
        keepalive_s: float | None = None,
    ) -> AsyncIterator[dict[str, Any] | None]:
        """The sole public SSE subscriber API. Yields:
          - one snapshot dict (when caller is fresh / behind / past restart),
          - or replay dicts (when caller is inside the ring),
          - then live events as they arrive,
          - `None` every `keepalive_s` seconds of quiet (when set) so the
            handler can flush a `:keepalive\\n\\n` to the wire. Without the
            keepalive, macOS `URLSession.bytes` buffers small chunks in
            CFNetwork for tens of seconds before VoiceSay's reader sees them.

        Returns when the consumer is dropped for being too slow. The
        snapshot/backlog/register ordering is enforced once, here.
        """
        q: asyncio.Queue[Any] = asyncio.Queue(maxsize=self.SUBSCRIBER_QUEUE_SIZE)
        # Snapshot backlog FIRST, then add to subscribers. Both are
        # synchronous — asyncio's single-threaded loop guarantees no
        # `_broadcast` interleaves. Any event broadcast before this pair
        # lands in the ring (and is in `replay`); any after lands in `q`.
        # Without this order an in-flight broadcast would be delivered
        # twice (once via ring replay, once via the queue).
        replay = self._backlog_since(last_event_id)
        self.subscribers.add(q)
        try:
            if replay is None:
                yield self.snapshot()
            else:
                for ev in replay:
                    yield ev
            while True:
                if keepalive_s is None:
                    item = await q.get()
                else:
                    try:
                        item = await asyncio.wait_for(q.get(), timeout=keepalive_s)
                    except asyncio.TimeoutError:
                        yield None
                        continue
                if item is self._DROP:
                    # Kicked out for being slow. Stop yielding; the
                    # caller unwinds and closes the connection.
                    return
                yield item
        finally:
            self.subscribers.discard(q)

    def wire_event_id(self, seq: int) -> str:
        """The SSE `id:` field for event `seq`: `<instance_id>-<seq>`."""
        return f"{self.instance_id}-{seq}"

    def parse_last_event_id(self, header: str | None) -> int | None:
        """Last-Event-ID → this process's seq, or None (= send a snapshot).

        `<instance_id>-<seq>` resumes only when the instance is this one; an
        id from an earlier daemon process names a seq in a different
        numbering. A bare integer (older clients, a hand-typed curl) is
        taken as this process's seq, as before.
        """
        if not header:
            return None
        instance, sep, seq = header.strip().rpartition("-")
        if sep and instance != self.instance_id:
            return None
        try:
            return int(seq)
        except ValueError:
            return None

    def _backlog_since(self, last_event_id: int | None) -> list[dict[str, Any]] | None:
        """Return buffered events with id > last_event_id, or None when
        the caller needs a fresh snapshot.

        Returns None for three cases:
          1. last_event_id is None (first connect or no prior id).
          2. last_event_id has aged out of the ring (we lost their backlog).
          3. last_event_id > event_seq (caller is impossibly ahead —
             happens after daemon restart when event_seq resets to 0 and
             the client still holds a pre-restart id). Without this branch,
             the handler would return [] (no events newer than `last`),
             skip the snapshot, and the client would sit on dead air
             until the next broadcast.
        """
        if last_event_id is None:
            return None
        if last_event_id > self.event_seq:
            return None
        if not self.ring:
            # Nothing has happened yet — no snapshot needed; return [].
            return []
        oldest_id = self.ring[0][0]
        if last_event_id < oldest_id - 1:
            # We've already overwritten what the caller missed.
            return None
        return [ev for (sid, ev) in self.ring if sid > last_event_id]
