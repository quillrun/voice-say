"""In-memory registry of in-flight streaming episodes.

A `mode="stream"` render keeps its `POST /render_longform` request open until
the whole episode finishes, so the only way to cancel or save-and-stop it is a
SEPARATE request (`POST /episode/<id>/cancel` | `/finalize`). Those routes need
a handle on the long-running render task that owns `<id>` — this registry is
that handle.

Single process, single aiohttp event loop: every access happens on the loop
thread, so a plain dict plus per-episode asyncio primitives need no extra
locking. Entries live only while an episode renders — `register()` at
episode_start, `unregister()` in the render's `finally`.
"""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field


@dataclass
class EpisodeControl:
    """Control surface for one in-flight streaming episode."""

    episode_id: str
    cancel: asyncio.Event = field(default_factory=asyncio.Event)
    finalize: asyncio.Event = field(default_factory=asyncio.Event)
    # Force save-and-stop: like `finalize` (keep the rendered-so-far chunks)
    # but DROP the chunk currently in flight instead of waiting for it. Set
    # alongside `finalize` by request_force_finalize, which ALSO cancels
    # current_chunk_task — the render's CancelledError handler tells this apart
    # from a plain cancel and finalizes from the completed chunks.
    force: asyncio.Event = field(default_factory=asyncio.Event)
    # The asyncio Task currently awaiting a chunk's TTS POST, if any. Cancel
    # cancels it so the render stops at the current chunk boundary promptly
    # instead of waiting for a multi-second synth to return. Set/cleared by
    # the render loop around each `await`.
    current_chunk_task: "asyncio.Task | None" = None
    # Set once every chunk is in and the join + save has begun: past this
    # point a cancel can no longer stop the row from being written.
    finishing: bool = False

    @property
    def cancelled(self) -> bool:
        return self.cancel.is_set()

    @property
    def finalize_requested(self) -> bool:
        return self.finalize.is_set()

    @property
    def force_finalize_requested(self) -> bool:
        return self.force.is_set()


class EpisodeRegistry:
    """Maps episode_id → EpisodeControl for the lifetime of each render."""

    def __init__(self) -> None:
        self._episodes: dict[str, EpisodeControl] = {}
        # Draft `ts` values with a resume currently in flight. Guards against a
        # double-fired POST /episode/resume (a double-click on "Continue render"
        # or a client retry) both rendering the remainder and writing duplicate
        # superset rows. Single loop thread → a plain set needs no locking,
        # same rationale as `_episodes`.
        self._resuming: set[str] = set()

    def begin_resume(self, draft_ts: str) -> bool:
        """Claim an exclusive in-flight resume for `draft_ts`. Returns False if
        a resume of the same draft is already running (caller should 409)."""
        if draft_ts in self._resuming:
            return False
        self._resuming.add(draft_ts)
        return True

    def end_resume(self, draft_ts: str) -> None:
        """Release the in-flight resume claim for `draft_ts` (idempotent)."""
        self._resuming.discard(draft_ts)

    def register(self, episode_id: str) -> EpisodeControl:
        ctl = EpisodeControl(episode_id=episode_id)
        self._episodes[episode_id] = ctl
        return ctl

    def unregister(self, episode_id: str) -> None:
        self._episodes.pop(episode_id, None)

    def get(self, episode_id: str) -> "EpisodeControl | None":
        return self._episodes.get(episode_id)

    def is_finishing(self, episode_id: str) -> bool:
        """True while <id> is past its chunks, joining and saving."""
        ctl = self._episodes.get(episode_id)
        return ctl is not None and ctl.finishing

    def request_cancel(self, episode_id: str) -> bool:
        """Signal cancel for <id>. Returns False if it isn't a live episode.

        Also cancels the in-flight chunk task so the render unblocks now
        rather than after the current (possibly many-second) synth returns.
        """
        ctl = self._episodes.get(episode_id)
        if ctl is None:
            return False
        ctl.cancel.set()
        task = ctl.current_chunk_task
        if task is not None and not task.done():
            task.cancel()
        return True

    def request_finalize(self, episode_id: str) -> bool:
        """Signal save-and-stop for <id>. Returns False if it isn't live.

        Unlike cancel, this does NOT interrupt the current chunk — the render
        finishes the in-flight chunk, then stops before the next one and
        finalizes what it has.
        """
        ctl = self._episodes.get(episode_id)
        if ctl is None:
            return False
        ctl.finalize.set()
        return True

    def request_force_finalize(self, episode_id: str) -> bool:
        """Force save-and-stop for <id>: keep the completed chunks but DROP the
        in-flight chunk (cancel its synth) instead of waiting for it. Returns
        False if it isn't live.

        Sets BOTH finalize and force, then cancels the current chunk task. The
        render's CancelledError handler checks `force_finalize_requested` to
        keep what it has (finalize) rather than discard everything (cancel). If
        no chunk is in flight, this degrades to a plain finalize (the loop's
        finalize gate stops it before the next chunk).
        """
        ctl = self._episodes.get(episode_id)
        if ctl is None:
            return False
        ctl.finalize.set()
        ctl.force.set()
        task = ctl.current_chunk_task
        if task is not None and not task.done():
            task.cancel()
        return True
