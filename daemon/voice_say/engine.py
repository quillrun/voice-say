"""Canonical TTS render pipeline.

Inputs: text + backend + voice + speed + tags.
Outputs (atomic — all or nothing):
  - audio file at  <data_root>/voice-archive/YYYY/MM/<stem>.{mp3,wav}
  - db row in      <data_root>/voice.db  (renders table, incl. full text)

Returns the entry dict (the same shape the `renders` row stores).

Errors raise RenderError with a structured `stage`. The caller decides
whether to retry, surface to the user, or exit nonzero.

The audio sinks (`archive_write`, `build_entry`, `stem`, `probe_duration_s`)
live in `_sinks.py`; history reads (`read_history`) live in
`_db.py`. Both are re-exported here so existing callers (`from . import
engine; engine.read_history(...)`) keep working.
"""
from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
import io
import logging
import re
import secrets
import sqlite3
import tempfile
import time
import wave
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Awaitable, Callable
from urllib.parse import urlsplit

import httpx

from . import _db, _sinks, config
from .tags import normalize_tag
# Re-exports — keep `engine.ARCHIVE_ROOT`, `engine.read_history`, etc.
# discoverable so the rest of the package (and tests) doesn't have to
# import `_sinks` / `_db` directly.
from ._sinks import ARCHIVE_ROOT  # noqa: F401 — re-export
from ._db import read_history  # noqa: F401 — re-export
from ._episode_registry import EpisodeRegistry


# Render concurrency gate. Two FIFO locks:
#
# - `episode`: one longform render (sequential, stream or resume) at a time,
#   across all backends. The macOS client follows ONE `streamingEpisode`, and
#   two interleaved episodes would only both finish later.
# - `tts(key)`: one backend request per concurrency key at a time. ALL local
#   backends share the "__local__" key (one heavy model resident in memory at
#   a time — the OOM guard); a remote worker gets its own key, so renders to different
#   boxes still run concurrently.
#
# An episode takes the tts lock per CHUNK, not for the whole episode, and
# asyncio.Lock is FIFO: a short render that arrives mid-episode runs as soon as
# the current chunk finishes instead of waiting for the episode to end. Locks
# are never taken reentrantly (an episode holds `episode`, then tts per chunk;
# a short render holds only tts). BACKENDS is resolved at call time, so this
# block may sit above its definition.
_LOOPBACK_HOSTS = {"127.0.0.1", "localhost", "::1", "0.0.0.0"}


def _concurrency_key(backend: "Backend | None") -> str:
    """Renders sharing a key serialize. All loopback-hosted backends collapse to
    one "__local__" key (single resident heavy model = OOM guard); a remote worker
    keys on its id so it runs concurrently with the local box. Pure string test on
    backend.host — no DNS (would block the loop / could alias .local→loopback)."""
    if backend is None:
        return "__local__"
    host = (getattr(backend, "host", "") or "").strip().lower()
    return "__local__" if host in _LOOPBACK_HOSTS else backend.id


class _RenderGate:
    """The episode lock + per-key tts locks described above, with the queue
    state /health reports. try/finally releases on exception and cancellation."""

    def __init__(self) -> None:
        self._episode = asyncio.Lock()
        self._tts: dict[str, asyncio.Lock] = {}
        self.waiting = 0                        # callers parked on either lock
        self._episode_since: float | None = None

    @asynccontextmanager
    async def _hold(self, lock: asyncio.Lock):
        self.waiting += 1
        try:
            await lock.acquire()
        finally:
            self.waiting -= 1
        try:
            yield
        finally:
            lock.release()

    @asynccontextmanager
    async def episode(self):
        async with self._hold(self._episode):
            self._episode_since = time.monotonic()
            try:
                yield
            finally:
                self._episode_since = None

    def tts(self, key: str):
        return self._hold(self._tts.setdefault(key, asyncio.Lock()))

    def busy(self) -> bool:
        return (self.waiting > 0 or self._episode.locked()
                or any(lock.locked() for lock in self._tts.values()))

    async def idle(self, poll_s: float = 2.0) -> None:
        """Return once no render holds or awaits a lock (background work that
        must not slow a render, e.g. read-along alignment, waits here)."""
        while self.busy():
            await asyncio.sleep(poll_s)

    def snapshot(self) -> dict[str, Any]:
        since = self._episode_since
        return {"waiting": self.waiting,
                "episode_running_s": (round(time.monotonic() - since, 1)
                                      if since is not None else None)}


_GATE = _RenderGate()


class ClientGone(Exception):
    """The caller hung up while its render waited for its turn (e.g. the CLI
    timed out): the render is dropped instead of producing an orphan row."""


async def _synth(text: str, backend: "Backend", voice: str, speed: float,
                 client: httpx.AsyncClient | None,
                 is_gone: Callable[[], bool] | None = None, **kw: Any) -> bytes:
    """One backend request under its key's tts lock. `is_gone` (from the
    route) is checked once the lock is ours: a request whose client left while
    it queued is never sent."""
    async with _GATE.tts(_concurrency_key(backend)):
        if is_gone is not None and is_gone():
            raise ClientGone()
        return await _tts_post(text, backend, voice, speed, client, **kw)


# Set by http_server._startup so the in-memory cache stays in sync with
# voice.db. None when running engine standalone (tests, scripts).
on_history_appended: Callable[[dict[str, Any]], None] | None = None

# Set by http_server._startup to align.align when read-along alignment is
# available (macOS Speech, `align` on). None in tests and scripts, so nothing
# below spawns the recognizer there.
aligner: Callable[..., Awaitable[list | None]] | None = None
# Background alignments of finished rows, held so they are not collected mid-run.
_align_jobs: set[asyncio.Task] = set()


# Predicted-duration heuristic: characters per second of synthesized speech.
# Used ONLY for the episode_start.predicted_total_s estimate (snapped to the
# true probed concat duration once episode_complete fires). 17.8 chars/s is
# an empirical speech-rate average at speed=1.0 — an estimate, not a contract.
CHARS_PER_SECOND = 17.8


@dataclass(frozen=True)
class Backend:
    id: str
    label: str
    port: int
    default_voice: str
    voices: tuple[str, ...]
    supports_speed: bool
    # Some TTS engines accept inline [whisper] [chuckle] [excited] markers;
    # others silently truncate audio when the brackets are present.
    # When False, the engine strips brackets + collapses whitespace before POST.
    supports_emotion_tags: bool
    accent: str  # hex for UI consumers
    host: str = "127.0.0.1"
    timeout_s: float = 600.0
    # Container format the backend returns: "mp3", or "wav" for backends
    # that return PCM WAV. Threaded through to the
    # archive extension, the db `format` column, and the duration probe so
    # WAV flows through the pipeline without a transcode dep.
    output_format: str = "mp3"
    # Model id the daemon sends as the OpenAI `model` field, so a single
    # upstream host can serve several models on one port and route by it.
    # "tts-1" is the generic default for single-model backends.
    model: str = "tts-1"
    # Base URL of the speech server ("http://127.0.0.1:8000"; a trailing /v1 is
    # dropped). Empty = http://{host}:{port}, the host + port catalog form.
    url: str = ""
    # True when the catalog entry leaves `voices` out: the daemon then asks the
    # server (GET /v1/audio/voices?model=, mlx-audio's server answers it).
    lists_voices: bool = False
    # How clients start/stop this backend's OS service. Opaque pass-through
    # dict surfaced via /config + /backends so the macOS app can drive on/off:
    #   {"kind": "launchd", "label": "local.voicesay.my-tts"}       — native
    #   {"kind": "docker",  "compose_service": "my-tts", "container": "…"}
    #   {"kind": "none"} / None — not client-managed (start it yourself)
    # A custom catalog (VOICE_SAY_BACKENDS_CONFIG) can remap labels.
    service: dict[str, Any] | None = None
    # Per-request longform chunk ceiling for THIS backend. 0 = use the global
    # LONGFORM_CHUNK_MAX. A backend whose quality improves with longer context
    # (it splits and joins long input itself) sets this larger, so each daemon
    # request covers more text and there are fewer daemon-level seams. Set in
    # the backend's catalog entry (`longform_chunk_max`, docs/setup/backends.md).
    longform_chunk_max: int = 0

    @property
    def base_url(self) -> str:
        return self.url or f"http://{self.host}:{self.port}"

    @property
    def speech_url(self) -> str:
        return f"{self.base_url}/v1/audio/speech"

    @property
    def chunk_max(self) -> int:
        """Effective per-request chunk ceiling: the per-backend override or the
        global LONGFORM_CHUNK_MAX (a build-time module constant — there is no
        config key for it; resolved at call time so a module-level patch is seen,
        but config.reload() does NOT change it)."""
        return self.longform_chunk_max or LONGFORM_CHUNK_MAX


def _where(bid: str, spec: dict[str, Any]) -> tuple[str, str, int]:
    """(url, host, port) of one catalog entry: from `url`, else `host` + `port`."""
    raw = str(spec.get("url") or "")
    if raw:
        parts = urlsplit(raw)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise ValueError(f"backend {bid!r}: url {raw!r} is not http(s)://host[:port]")
        url = raw.rstrip("/").removesuffix("/v1")
        return url, parts.hostname, parts.port or (443 if parts.scheme == "https" else 80)
    if "port" not in spec:
        raise ValueError(f"backend {bid!r} needs a url (or host + port)")
    return "", str(spec.get("host", "127.0.0.1")), int(spec["port"])


# The catalog is built from config (committed Kokoro default, overridable
# via VOICE_SAY_BACKENDS_CONFIG). An entry needs `url` + `model`; the rest has
# defaults. Per-backend timeouts track the longest expected single render
# (whole-module longform POSTs can take minutes).
def _build_backends() -> dict[str, Backend]:
    out: dict[str, Backend] = {}
    for bid, spec in config.load_backends().items():
        url, host, port = _where(bid, spec)
        out[bid] = Backend(
            id=bid,
            label=spec.get("label", bid),
            url=url,
            host=host,
            port=port,
            lists_voices="voices" not in spec,
            default_voice=spec.get("default_voice", "default"),
            voices=tuple(spec.get("voices", []) or []),
            supports_speed=bool(spec.get("supports_speed", False)),
            supports_emotion_tags=bool(spec.get("supports_emotion_tags", False)),
            accent=spec.get("accent", "#888888"),
            timeout_s=float(spec.get("timeout_s", 600.0)),
            output_format=str(spec.get("output_format", "mp3")).lower(),
            model=str(spec.get("model", "tts-1")),
            service=spec.get("service"),
            longform_chunk_max=int(spec.get("longform_chunk_max", 0)),
        )
    return out


BACKENDS: dict[str, Backend] = _build_backends()


# Open tag vocabulary. Any tag is accepted from any render surface
# (`voice-say render`, the app's Compose); the user creates new
# tags simply by using them. Tags are normalized (trim → lowercase →
# hyphenate) so "Daily Notes" and "daily-notes" collapse to one entry.
# `star` and playback `completed` remain mechanisms (overlay boolean +
# progress field), not tags.


def allowed_tag_set() -> set[str]:
    """The closed vocabulary as a normalized set, read live from
    config.ALLOWED_TAGS. An empty set means OPEN mode (any tag accepted) —
    the committed default. Reading at call time mirrors classify_kind so a
    runtime config change applies without a daemon restart."""
    return {n for t in config.ALLOWED_TAGS if (n := normalize_tag(t))}


def unknown_tags(norm_tags: list[str]) -> list[str]:
    """Tags rejected by the closed vocabulary, in input order. Empty list in
    open mode (allowed_tags == []) or when every tag is permitted. Shared by
    the /render front door and overlay tag edits so both enforce identically."""
    allowed = allowed_tag_set()
    if not allowed:
        return []
    return [t for t in norm_tags if t not in allowed]



def classify_kind(text: str) -> str:
    """kind="say" for short utterances (<= the live say-threshold), else
    "render". Reads config.SAY_THRESHOLD_CHARS at CALL time (not the cached
    module alias) so a runtime POST /config change takes effect without a
    daemon restart."""
    return "say" if len(text) <= config.SAY_THRESHOLD_CHARS else "render"

# Inline emotion tags ([whisper], [laughs softly]) that some TTS engines accept:
# a bracketed word or phrase standing on its own. "arr[0]", "[1]" and a
# markdown link "[word](...)" are text, not tags, and stay.
_EMOTION_TAG_RE = re.compile(r"(?<!\S)\[[A-Za-z][A-Za-z ,'-]*\](?!\()")
_PARAGRAPH_RE = re.compile(r"\n\s*\n")
_WHITESPACE_RE = re.compile(r"\s+")


def _strip_emotion_tags(text: str) -> str:
    """Text for a backend with supports_emotion_tags=False: tags removed, and
    the gaps they leave collapsed (some engines truncate the audio on runs of
    whitespace). Paragraph breaks stay, since longform splits on them and the
    stored transcript keeps them. Idempotent.
    """
    paras = (_WHITESPACE_RE.sub(" ", _EMOTION_TAG_RE.sub("", p)).strip()
             for p in _PARAGRAPH_RE.split(text))
    return "\n\n".join(p for p in paras if p)


# Per-chunk character ceiling. Kept well under the backend's practical
# input limit so each chunk renders quickly and a single-stream backend host
# never holds a giant sequence in memory. Splitting on paragraph then
# sentence boundaries keeps prosody natural at the seams.
LONGFORM_CHUNK_MAX = 1200
# Upper bound on chunks per longform render. Backend hosts are single-stream,
# so chunks render serially (~RTF 1.4 each); an unbounded input would hold
# one HTTP request open for N×render_time and blow past any client timeout
# while the server keeps grinding (self-inflicted DoS). At 1200 chars/chunk
# this caps a single longform call at ~48k input chars / ~45 min of audio.
# Config-driven (default 40); the guard reads config.LONGFORM_MAX_CHUNKS at call
# time so a local TOML override / reload() takes effect without a restart.
# Accepted render_longform modes: "sequential" (the engine default; the HTTP
# route defaults to stream) and "stream"
# (progressive per-chunk broadcast). Single source for the guard shared by the
# engine and the /render_longform route's fast-fail mirror.
LONGFORM_MODES = ("sequential", "stream")

# The five streaming episode SSE event types, emitted by _render_longform_stream
# and consumed by the macOS client's EventStreamReader. One home so the wire
# contract has a greppable anchor (the string values are unchanged).
EVENT_EPISODE_START = "episode_start"
EVENT_CHUNK_READY = "chunk_ready"
EVENT_EPISODE_COMPLETE = "episode_complete"
EVENT_EPISODE_CANCELLED = "episode_cancelled"
EVENT_EPISODE_ERROR = "episode_error"


def _chunk_longform(text: str, MAX: int = LONGFORM_CHUNK_MAX) -> tuple[list[str], list[str]]:
    """Split longform text into chunks on paragraph/sentence boundaries (never
    mid-sentence if avoidable) AND return the per-chunk JOIN separators.

    Best-effort ceiling: chunks are <=MAX EXCEPT a single sentence longer than
    MAX (no '. ' boundary to split on), which is emitted whole rather than wrapped
    mid-word. Accumulate whole paragraphs until the next would overflow MAX; a
    single paragraph larger than MAX is sentence-split on '. '. Changing the
    split changes chunk counts, which the longform tests pin (a hard wrap here
    would move them).

    Returns ``(chunks, seps)``. ``seps[i]`` is the string that joins ``chunks[i]``
    to ``chunks[i-1]`` when reconstructing the full transcript: ``'\\n\\n'`` at a
    real paragraph boundary, ``' '`` between sentence-split pieces of a SINGLE
    over-long paragraph, and ``''`` for ``chunks[0]``. So
    ``''.join(s + c for c, s in zip(chunks, seps))`` is the normalized transcript
    with NO fabricated paragraph break inside a split paragraph (a uniform
    ``"\\n\\n".join(chunks)`` would add one in every paragraph longer than MAX,
    visible mainly on a backend with a small MAX)."""
    paras = [p.strip() for p in text.split('\n\n') if p.strip()]
    chunks: list[str] = []
    seps: list[str] = []
    cur = ''
    cur_sep = ''   # the join separator that precedes `cur` once it is flushed

    def emit(chunk: str, sep: str) -> None:
        seps.append('' if not chunks else sep)   # the first chunk has no leading sep
        chunks.append(chunk)

    for p in paras:
        if len(p) > MAX:
            if cur:
                emit(cur, cur_sep)
                cur = ''
            s = ''
            split_any = False   # have we already emitted a piece of THIS paragraph?
            for tok in p.replace('. ', '.\x00').split('\x00'):
                # `s.strip()`: a first sentence already over MAX must not
                # flush an EMPTY chunk ahead of itself (one wasted, silent POST).
                if len(s) + len(tok) > MAX and s.strip():
                    # First piece of p joins the prior paragraph ('\n\n'); later
                    # pieces continue the SAME paragraph (' ').
                    emit(s.strip(), ' ' if split_any else '\n\n')
                    split_any = True
                    s = ''
                s += tok + ' '
            if s.strip():
                cur = s.strip()
                cur_sep = ' ' if split_any else '\n\n'   # tail continues p, or p whole
            continue
        if len(cur) + len(p) + 2 > MAX:
            if cur:   # a first paragraph of MAX-1..MAX chars has nothing before it
                emit(cur, cur_sep)
            cur = p
            cur_sep = '\n\n'
        else:
            if cur:
                cur = cur + '\n\n' + p
            else:
                cur = p
                cur_sep = '\n\n'
    if cur:
        emit(cur, cur_sep)
    return chunks, seps


def chunk_text(text: str, MAX: int = LONGFORM_CHUNK_MAX) -> list[str]:
    """The chunks to render, on paragraph/sentence boundaries. Thin wrapper over
    `_chunk_longform` (which also returns the join separators the read-along
    transcript is reconstructed from). The chunk list is unchanged from the
    original algorithm."""
    return _chunk_longform(text, MAX)[0]


def _write_temp_wav(audio: bytes, prefix: str) -> Path:
    """Write audio bytes to a fresh temp .wav (mkstemp) and return its path.
    The caller owns cleanup; an OSError propagates for the caller to map."""
    fd, name = tempfile.mkstemp(suffix=".wav", prefix=prefix, dir=_sinks.temp_dir())
    with open(fd, "wb") as fh:
        fh.write(audio)
    return Path(name)


# A backend that drops the connection or answers 502/503/504 is usually
# restarting (launchd KeepAlive brings it back within seconds); a chunk is
# retried after a pause instead of failing the episode. A read timeout is NOT
# retried: the backend may still be rendering, and a resend would queue twice.
TTS_RETRIES = 2
TTS_RETRY_DELAY_S = 10.0
_TRANSIENT_ERRORS = (httpx.ConnectError, httpx.ConnectTimeout,
                     httpx.RemoteProtocolError, httpx.ReadError, httpx.WriteError)
_TRANSIENT_STATUS = frozenset({502, 503, 504})


class RenderError(Exception):
    """Render pipeline failed. .stage is one of:
       tts | request | archive | db
    """
    def __init__(self, stage: str, message: str):
        super().__init__(f"{stage}: {message}")
        self.stage = stage
        self.message = message


class RenderCancelled(Exception):
    """A streaming episode was cancelled via the episode registry. NOT a
    RenderError (no failed stage) — the route maps it to a 200 "cancelled"
    response and NO canonical row is written. Carries episode_id so the route
    can echo it back to the client."""
    def __init__(self, episode_id: str):
        super().__init__(f"episode {episode_id} cancelled")
        self.episode_id = episode_id


# --- Model-bypass mock (dev/test) -------------------------------------------
# When a POST /render_longform carries mock=true, the engine skips the
# model and, per chunk, returns a PRE-EXISTING fixture WAV from
# config.MOCK_CHUNK_DIR after a timer sleep — no model, no network. The render
# is split into exactly len(fixtures) chunks of the REAL text (so the reader
# still shows what was typed AND each pre-existing chunk is replayed once).
# Everything downstream (concat, probe, voice.db row, SSE contract) stays real.
# Fixtures are local-only (gitignored), never shipped.
_MOCK_FIXTURES: list[bytes] | None = None


def _load_mock_fixtures() -> list[bytes]:
    """Read + cache the pre-existing chunk WAVs (sorted) from MOCK_CHUNK_DIR."""
    global _MOCK_FIXTURES
    if _MOCK_FIXTURES is None:
        d = config.MOCK_CHUNK_DIR
        paths = sorted(d.glob("*.wav")) if d.is_dir() else []
        _MOCK_FIXTURES = [p.read_bytes() for p in paths]
    return _MOCK_FIXTURES


def _mock_chunk_plan(text: str, n: int) -> list[str]:
    """Exactly ``n`` non-empty contiguous slices of the real text on word
    boundaries — the reader still displays the typed text AND the render is
    deterministically ``n`` chunks. Empty slices fall back to a placeholder."""
    n = max(1, n)
    words = text.split()
    if not words:
        return [f"Mock chunk {i + 1}." for i in range(n)]
    # Even split: chunk i gets words[i*L//n : (i+1)*L//n] (balances remainder).
    total = len(words)
    out: list[str] = []
    for i in range(n):
        seg = words[i * total // n:(i + 1) * total // n]
        out.append(" ".join(seg) if seg else f"Mock chunk {i + 1}.")
    return out


def _mock_chunk_count() -> int:
    """Number of mock chunks = fixtures × MOCK_CHUNK_MULT (the fixture set is
    cycled). The fresh AND resume paths must use this SAME count so a draft's
    stored chunk-seam offset stays valid on resume."""
    return (len(_load_mock_fixtures()) or 1) * max(1, config.MOCK_CHUNK_MULT)


async def _mock_synth(chunk_index: int) -> bytes:
    """Return the chunk_index-th pre-existing fixture WAV after a realistic pause.

    The pause is paced to the chunk's OWN audio length (× config.MOCK_RTF), not a
    flat per-chunk timer: a flat MOCK_CHUNK_MS made an N-chunk mock "finish" in
    N×0.6s while the audio played for far longer, so the render frontier raced to
    100% almost instantly (mock felt "too quick"). Scaling by fixture duration
    keeps the render head a step ahead of playback. MOCK_CHUNK_MS is the floor for
    odd/zero-duration fixtures (and MOCK_RTF=0 lets the test suite skip the pause).
    """
    fixtures = _load_mock_fixtures()
    if not fixtures:
        raise RenderError(
            "tts", f"mock backend: no fixture WAVs in {config.MOCK_CHUNK_DIR}")
    idx = chunk_index % len(fixtures)
    durs = _mock_fixture_durations()
    audio_s = durs[idx] if idx < len(durs) else 0.0
    await asyncio.sleep(max(config.MOCK_CHUNK_MS / 1000.0, audio_s * config.MOCK_RTF))
    return fixtures[idx]


def _mock_fixture_durations() -> list[float]:
    """Per-fixture playback seconds, parsed from the WAV headers (stdlib `wave`,
    no ffmpeg). A mock render replays these FIXED fixtures regardless of the
    input text, so the text-derived `chars / CHARS_PER_SECOND` estimate is
    meaningless for it — these real durations let `predicted_total_s` track the
    audio the client actually plays (otherwise the progress bar / time / render
    frontier saturate to 100% on the first chunk). A bad header → 0.0 for that
    fixture (the caller then falls back to the text estimate). Reuses the cached
    fixture bytes (`_load_mock_fixtures`) and just re-parses headers — called
    once per episode_start (not hot), so no second cache that could drift."""
    durs: list[float] = []
    for data in _load_mock_fixtures():
        try:
            with wave.open(io.BytesIO(data), "rb") as w:
                rate = w.getframerate() or 1
                durs.append(w.getnframes() / float(rate))
        except Exception:  # noqa: BLE001 — a non-PCM/odd header just means no estimate
            durs.append(0.0)
    return durs


def _mock_total_audio_s(n_chunks: int) -> float:
    """Total seconds of the fixtures replayed for ``n_chunks`` chunks — cycling
    by ``i % len`` to match `_mock_synth`. Returns 0.0 when no duration is known
    (empty/odd fixtures) so the caller keeps the text estimate."""
    durs = _mock_fixture_durations()
    if not durs:
        return 0.0
    return sum(durs[i % len(durs)] for i in range(max(0, n_chunks)))


def _fire_history_appended(
    hook: Callable[[dict[str, Any]], None] | None,
    entry: dict[str, Any],
    ts: Any,
    align: bool = True,
) -> None:
    """Fire the best-effort history/SSE hook after the durable db write.

    The durable write ends at the db insert; this hook (cache invalidation, SSE
    broadcast) is best-effort. If it raises — dead subscriber queue, SSE
    bookkeeping bug — the render has ALREADY succeeded on disk, so we log and
    swallow: re-raising would 500 a succeeded render and the caller would retry
    into a duplicate. `ts` is used only for the warning line (callers pass the
    original ts_iso, or the row-PK entry["ts"] at the streaming site).

    ``align`` schedules the read-along alignment of the new row (see
    ``align_entry``); False when re-announcing a row that alignment updated."""
    if align:
        _align_later(entry)
    if hook is None:
        return
    try:
        hook(entry)
    except Exception as exc:  # noqa: BLE001
        logging.getLogger("voice_say").warning(
            "on_history_appended hook raised for ts=%s: %s", ts, exc,
        )


def _align_later(entry: dict[str, Any]) -> None:
    """Align a new row in the background when alignment is on and the render
    is long enough for the even pace to drift."""
    if aligner is None or (entry.get("duration_s") or 0) < config.ALIGN_MIN_S:
        return
    try:
        task = asyncio.get_running_loop().create_task(align_entry(entry["ts"]))
    except RuntimeError:  # no running loop (a sync caller): nothing to schedule on
        return
    _align_jobs.add(task)
    task.add_done_callback(_align_jobs.discard)


async def align_entry(ts: str) -> int | None:
    """Measure one row's word timings from its audio and store them as its
    seam_map, then re-announce the row so the app's reader picks them up.
    Returns the number of word points, or None when the row, its audio or the
    aligner is missing, or the alignment failed (the row keeps its seams)."""
    log = logging.getLogger("voice_say")
    entry = _db.get_render(ts)
    if aligner is None or entry is None or not entry.get("archive_path"):
        return None
    path = Path(entry["archive_path"])
    text = entry.get("text") or ""
    if not path.exists() or not text:
        return None
    # Never alongside a render: wait until no render holds or awaits a lock.
    await _GATE.idle()
    t0 = time.perf_counter()
    try:
        pts = await aligner(path, text)
    except Exception as exc:  # noqa: BLE001 — alignment is best-effort
        log.warning("align: %s failed: %s", ts, exc)
        return None
    if not pts:
        return None
    duration = float(entry.get("duration_s") or 0) or pts[-1][0]
    seam = _monotonic([[0.0, 0], *pts, [round(duration, 3), len(text)]])
    if not _db.set_seam_map(ts, seam):
        return None
    log.info("align: %s, %d word points in %.1f s", ts, len(pts), time.perf_counter() - t0)
    fresh = _db.get_render(ts)
    if fresh is not None:
        _fire_history_appended(on_history_appended, fresh, ts, align=False)
    return len(pts)


def _monotonic(points: list[list[float]]) -> list[list[float]]:
    """Sorted by audio time, keeping only points that advance in both audio
    and text, so the reader's play-head → char map never runs backwards."""
    out: list[list[float]] = []
    for a, c in sorted(points, key=lambda p: (p[0], p[1])):
        if out and (a <= out[-1][0] or c <= out[-1][1]):
            continue
        out.append([a, c])
    return out


async def render(
    text: str,
    *,
    backend_id: str | None = None,
    voice: str | None = None,
    speed: float = 1.0,
    tags: list[str] | None = None,
    httpx_client: httpx.AsyncClient | None = None,
    is_gone: Callable[[], bool] | None = None,
) -> dict[str, Any]:
    """Render text through the TTS chain. Returns the canonical entry dict.

    backend_id None → config.DEFAULT_BACKEND.

    The audio file and the db row both land (the db row carries the full
    transcript — it is the single source of truth for what was rendered).
    Each entry is stamped with a `kind` ("say" for short utterances,
    "render" otherwise; see `classify_kind`).
    """
    if backend_id is None:
        backend_id = config.DEFAULT_BACKEND
    text, voice, backend, tags = _validate(text, backend_id, voice, tags)
    kind = classify_kind(text)

    ts_dt = datetime.now(timezone.utc)
    ts_iso = ts_dt.strftime("%Y-%m-%dT%H:%M:%S.%fZ")

    # 1. TTS POST under the backend key's tts lock (see _RenderGate): waits at
    # most for the request ahead of it — one chunk of a running episode.
    audio = await _synth(text, backend, voice, speed, httpx_client, is_gone=is_gone)

    # 2. Archive. The backend's container format drives the file extension,
    # the duration probe, and the recorded `format` everywhere downstream.
    fmt = backend.output_format
    stem = _sinks.stem(text)
    try:
        archive_path = await asyncio.to_thread(_sinks.archive_write, audio, stem, fmt)
    except OSError as exc:
        raise RenderError("archive", str(exc)) from exc

    # 2.5 Probe duration so the db row carries it from render time, with no
    # later backfill by a client. File work runs off the event loop (see _finalize_longform).
    duration_s = await asyncio.to_thread(_sinks.probe_duration_s, archive_path, fmt)

    # 3. Persist the render row (full transcript included). Roll back the
    # audio file on failure so a half-recorded render leaves nothing behind.
    # `ts` is the row primary key (and the id for progress/overlays/audio),
    # so it must be unique — bump the microsecond on the rare collision.
    # Wall-clock render time = now − the start stamp (covers TTS + archive + probe).
    render_elapsed_s = (datetime.now(timezone.utc) - ts_dt).total_seconds()
    entry = _sinks.build_entry(text, kind, backend.id, voice, speed,
                               archive_path, audio, ts_iso, tags, duration_s, fmt,
                               render_elapsed_s=render_elapsed_s)
    try:
        _insert_unique(entry, ts_dt)
    except Exception as exc:
        _sinks.unlink_quiet(archive_path)
        raise RenderError("db", f"insert failed; archive rolled back ({exc})") from exc

    # Best-effort cache/SSE hook after the durable db write (see helper).
    _fire_history_appended(on_history_appended, entry, ts_iso)
    return entry


def _build_seam_map(chunk_seams: list | None, prefix_audio_s: float,
                    seam_start_chars: int, duration_s: float) -> list | None:
    """Per-chunk ``[audio_s, char_offset]`` points in FINISHED-file coordinates
    for the client read-along. Audio is scaled to the true probed ``duration_s``
    so the last point lands at the end of the file (the per-chunk wav durations
    sum to slightly less than the concat, which adds inter-chunk pauses). Returns
    None when there are no chunk seams — a single render maps uniformly and
    exactly without one."""
    if not chunk_seams:
        return None
    raw: list[list[float]] = [[0.0, 0]]
    if prefix_audio_s > 0:
        raw.append([float(prefix_audio_s), int(seam_start_chars)])
    for ca, rc in chunk_seams:
        raw.append([float(prefix_audio_s) + float(ca), int(rc)])
    last_audio = raw[-1][0]
    # Guard the NUMERATOR as well as the denominator: an unprobeable concat
    # (duration_s == 0) would otherwise scale every point to 0, collapsing the
    # whole map onto [0, char] and snapping the client read-head to the final
    # char. Fall back to the unscaled (1.0) per-chunk timeline in that
    # degenerate case — the chunk audio times are already monotonic, just not
    # snapped to the true file duration.
    scale = (duration_s / last_audio) if (last_audio > 0 and duration_s > 0) else 1.0
    return [[round(a * scale, 3), int(c)] for a, c in raw]


async def _finalize_longform(
    wavs: list[Path],
    text: str,
    kind: str,
    backend: "Backend",
    voice: str,
    speed: float,
    tags: list[str],
    ts_iso: str,
    ts_dt: datetime,
    resume_full_text: str | None = None,
    resume_char_offset: int | None = None,
    chunk_seams: list | None = None,
    prefix_audio_s: float = 0.0,
    seam_start_chars: int = 0,
) -> dict[str, Any]:
    """Shared longform finalize tail (sequential + stream).

    Pure code-motion: concat the per-chunk wavs → the ONE canonical archive
    mp3 (Trap 2) → probe its duration → read the final bytes → build the ONE
    entry → _insert_unique the ONE row (Trap 3), rolling back the archive on
    insert failure. Returns the entry dict.

    Invariants the callers rely on: the single libmp3lame encode
    (concat_wavs_to_mp3), the single mutagen probe, and the single
    _insert_unique each run EXACTLY ONCE per longform render. This helper does
    NOT clean up ``wavs`` (the caller's per-branch finally owns that), does NOT
    fire on_history_appended, and emits no episode_* events.
    """
    # Gapless concat → single archive mp3 (Trap 2). Longform always lands as
    # mp3 regardless of the backend's native container.
    fmt = "mp3"
    out_stem = _sinks.stem(text)

    # concat (ffmpeg + the pure-Python seam pad), probe and read run in a
    # worker thread: on the event loop they froze /health, SSE and cancel for
    # the whole 6-12 s finalize (up to the 900 s ffmpeg timeout if it hung).
    def _encode() -> tuple[Path, float, float, bytes]:
        t_enc = time.perf_counter()
        path = _sinks.concat_wavs_to_mp3(wavs, out_stem)
        enc = time.perf_counter() - t_enc
        try:
            data = path.read_bytes()
        except OSError as exc:
            raise OSError(f"reading final mp3: {exc}") from exc
        return path, enc, _sinks.probe_duration_s(path, fmt), data

    try:
        archive_path, enc_s, duration_s, final_bytes = await asyncio.to_thread(_encode)
    except (_sinks.ConcatError, OSError) as exc:
        raise RenderError("archive", str(exc)) from exc
    # Stage timing: decomposes the post-synth finalize block.
    logging.getLogger("voice_say").info(
        "finalize: concat+encode %.1fs (%d chunk(s), %.0fs audio)",
        enc_s, len(wavs), duration_s)

    # `bytes` (final_bytes) reflects the final archived mp3 (the single
    # artefact), not the sum of the discarded chunk WAVs.

    # Persist ONE render row (Trap 3) via the same _insert_unique path
    # render() uses. Roll back the archive on db failure.
    # Wall-clock render time = now − the episode/render start stamp (covers all
    # chunk renders + concat + probe). For a resume it's the remainder's time.
    render_elapsed_s = (datetime.now(timezone.utc) - ts_dt).total_seconds()
    seam_map = _build_seam_map(chunk_seams, prefix_audio_s, seam_start_chars,
                               duration_s)
    entry = _sinks.build_entry(text, kind, backend.id, voice, speed,
                               archive_path, final_bytes, ts_iso, tags,
                               duration_s, fmt,
                               resume_full_text=resume_full_text,
                               resume_char_offset=resume_char_offset,
                               render_elapsed_s=render_elapsed_s,
                               seam_map=seam_map)
    try:
        _insert_unique(entry, ts_dt)
    except Exception as exc:
        _sinks.unlink_quiet(archive_path)
        raise RenderError("db", f"insert failed; archive rolled back ({exc})") from exc
    return entry


async def _salvage(err: BaseException, wavs: list[Path], full_text: str,
             offset: int, kind: str, backend: "Backend", voice: str,
             speed: float, tags: list[str], ts_iso: str, ts_dt: datetime,
             keep_name: str, **seam_kwargs: Any) -> dict[str, Any] | None:
    """A longform render failed with ``wavs`` (the chunks up to ``offset`` in
    ``full_text``) already rendered: save them instead of discarding them.

    Short of the end → a resumable draft (tag "draft" + resume fields, same
    shape as a save-and-stop, so "Continue render" picks it up). Every chunk
    done (only the finalize failed) → the complete row, finalized again. If
    that save fails too, the wavs move to ARCHIVE_ROOT/.failed/<keep_name>.
    The saved row's ts is set on ``err.saved_ts`` (and ``err.partial``) so
    the route and the episode_error event can name it."""
    log = logging.getLogger("voice_say")
    partial = offset < len(full_text)
    kw: dict[str, Any] = dict(seam_kwargs)
    tags = list(tags)
    if partial:
        if "draft" not in tags:
            tags.append("draft")
        kw.update(resume_full_text=full_text, resume_char_offset=offset)
    try:
        entry = await _finalize_longform(wavs, full_text, kind, backend, voice, speed,
                                   tags, ts_iso, ts_dt, **kw)
    except Exception as exc:  # noqa: BLE001 — last resort: keep the audio files
        kept = await asyncio.to_thread(_sinks.keep_wavs, wavs, keep_name)
        log.error("render failed (%s) and saving its %d finished chunk(s) "
                  "failed too (%s); wavs kept in %s", err, len(wavs), exc, kept)
        return None
    log.warning("render failed (%s); %d finished chunk(s) saved as %s %s",
                err, len(wavs), "draft" if partial else "row", entry["ts"])
    err.saved_ts = entry["ts"]          # type: ignore[attr-defined]
    err.partial = partial               # type: ignore[attr-defined]
    _fire_history_appended(on_history_appended, entry, entry["ts"])
    return entry


async def render_longform(
    text: str,
    *,
    backend_id: str | None = None,
    voice: str | None = None,
    speed: float = 1.0,
    tags: list[str] | None = None,
    httpx_client: httpx.AsyncClient | None = None,
    mode: str = "sequential",
    on_episode_event: Callable[[dict[str, Any]], None] | None = None,
    episode_registry: "EpisodeRegistry | None" = None,
    mock: bool = False,
    is_gone: Callable[[], bool] | None = None,
) -> dict[str, Any]:
    """Longform render: chunk → per-chunk WAV → gapless concat to
    ONE mp3 → ONE archive file + ONE db row.

    Mirrors `render()`'s contract and error staging, but renders each
    chunk SERIALLY (see Trap 1 below) and joins
    the per-chunk WAVs at PCM before a single libmp3lame encode. The
    result is indistinguishable downstream from a normal `render()`:
    exactly one `renders` row (ts as PK), one audio file, one entry dict.

    ``mode``:
      - "sequential" (this function's default; the HTTP route defaults to
        "stream"). Renders all
        chunks one after another, concats once, inserts ONE
        row, fires the canonical render event. No streaming broadcasts.
      - "stream" — renders chunks serially the same way, archives EACH chunk to its own transient wav, and
        broadcasts episode_start (once, before the loop), chunk_ready
        (after each transient chunk lands, with cumulative_audio_s as the
        render-head), and episode_complete (after the canonical row is
        inserted) via ``on_episode_event``. Still exactly ONE voice.db row.

    ``on_episode_event`` is the injectable broadcaster (wired by the route
    to State.broadcast — the SAME public ephemeral-event path /render's
    'render' event rides for cache-less playback-coordination events). The
    engine stays import-clean of daemon state, mirroring the
    on_history_appended indirection.

    Trap 1 — SERIAL render: the chunk loop awaits each chunk before the
    next, and each chunk takes the backend's `_GATE.tts` lock, so a quick
    render can slip in between chunks but never runs alongside one (two
    requests at once would thrash or OOM a single-stream backend host).

    Trap 2 — gapless: each chunk is rendered to WAV (response_format=wav),
    then concatenated at PCM and re-encoded once to mp3 (see
    `_sinks.concat_wavs_to_mp3`). Never `mp3 -c copy`.

    Trap 3 — one render = one row: archive_write / probe_duration_s /
    build_entry / _insert_unique are the SAME sinks `render()` uses; no
    per-chunk rows are written. Transient stream chunks are NOT artefacts
    and are removed in a finally.

    Trap 4 — chunk boundaries: `chunk_text` splits on paragraph/sentence
    boundaries, never mid-sentence if avoidable.
    """
    if mode not in LONGFORM_MODES:
        raise RenderError("request", f"unknown mode {mode!r}")
    if backend_id is None:
        backend_id = config.DEFAULT_BACKEND
    text, voice, backend, tags = _validate(text, backend_id, voice, tags)
    # Mock renders are auto-tagged so they are trivially filtered + purged.
    if mock and "mock" not in tags:
        tags = [*tags, "mock"]
    kind = classify_kind(text)

    if mock:
        # Replay the pre-existing fixtures (cycled MOCK_CHUNK_MULT times), sliced
        # from the real text so the reader still shows what was typed. Each mock
        # boundary is treated as a paragraph break (the pre-seps behavior).
        chunks = _mock_chunk_plan(text, _mock_chunk_count())
        seps = [''] + ['\n\n'] * (len(chunks) - 1)
    else:
        chunks, seps = _chunk_longform(text, backend.chunk_max)
    if not chunks:
        raise RenderError("tts", "no renderable chunks after splitting")
    max_chunks = config.LONGFORM_MAX_CHUNKS
    if len(chunks) > max_chunks:
        raise RenderError(
            "request",
            f"longform input too large: {len(chunks)} chunks "
            f"(max {max_chunks}); split into multiple renders",
        )

    # One episode at a time (see _RenderGate). Validation ran above, so a bad
    # request fails at once instead of after the queue. The ts is stamped once
    # the episode starts, so render_elapsed_s doesn't count the wait.
    async with _GATE.episode():
        if is_gone is not None and is_gone():
            raise ClientGone()
        ts_dt = datetime.now(timezone.utc)
        ts_iso = ts_dt.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
        # Streaming mode (mode="stream") is the progressive-broadcast variant.
        # Sequential mode renders every chunk, then writes once.
        if mode == "stream":
            return await _render_longform_stream(
                text, kind, backend, voice, speed, tags,
                chunks, ts_dt, ts_iso, httpx_client, on_episode_event,
                episode_registry, mock=mock, _seps=seps,
            )
        return await _render_longform_sequential(
            text, kind, backend, voice, speed, tags, chunks, seps,
            ts_dt, ts_iso, httpx_client, mock)


def _keep_on_teardown(wavs: list[Path], keep_name: str) -> None:
    """The daemon is shutting down mid-episode (task cancelled): there is no
    time to encode a draft, so move the finished chunk wavs to
    ARCHIVE_ROOT/.failed/<keep_name>/ instead of letting the finally delete
    them. Synchronous (file moves only) so it completes during teardown."""
    if not wavs:
        return
    try:
        kept = _sinks.keep_wavs(wavs, keep_name)
    except OSError as exc:
        logging.getLogger("voice_say").error(
            "shutdown mid-render: could not keep %d chunk wav(s): %s", len(wavs), exc)
        return
    logging.getLogger("voice_say").warning(
        "shutdown mid-render: %d finished chunk wav(s) kept in %s", len(wavs), kept)


async def _render_longform_sequential(
    text: str, kind: str, backend: "Backend", voice: str, speed: float,
    tags: list[str], chunks: list[str], seps: list[str], ts_dt: datetime,
    ts_iso: str, httpx_client: httpx.AsyncClient | None, mock: bool,
) -> dict[str, Any]:
    """mode="sequential" body of render_longform (see its docstring)."""
    # 1. TTS POST per chunk → WAV, strictly serial (Trap 1). Each chunk is written to a temp WAV; the
    # temp files are cleaned up in the finally below regardless of outcome.
    tmp_wavs: list[Path] = []
    rendered_chars = 0          # chunk-boundary offset in the joined text
    try:
        for idx, chunk in enumerate(chunks):
            # response_format=wav forces PCM out of the backend even
            # for mp3 backends (the engine forwards response_format —
            # see _tts_post). Concat then re-encodes once to mp3.
            audio = await _synth(
                chunk, backend, voice, speed, httpx_client,
                response_format="wav", chunk_index=idx, mock=mock,
            )
            try:
                tmp_wavs.append(_write_temp_wav(audio, f"vs-lf-{idx:04d}-"))
            except OSError as exc:
                raise RenderError("archive", f"chunk {idx} temp write: {exc}") from exc
            rendered_chars += len(seps[idx]) + len(chunk)

        # 2-3. Gapless concat → probe → build → ONE row (Trap 2 + 3), via
        # the shared finalize tail. Same sinks render() uses.
        entry = await _finalize_longform(
            tmp_wavs, text, kind, backend, voice, speed, tags, ts_iso, ts_dt,
        )
    except asyncio.CancelledError:
        _keep_on_teardown(tmp_wavs, f"{ts_iso}-lf")
        raise
    except Exception as exc:
        # Keep the finished chunks (a draft in the joined-text space resume
        # re-chunks), then re-raise so the caller still sees the failure.
        if tmp_wavs:
            joined = "".join(sp + ch for sp, ch in zip(seps, chunks))
            await _salvage(exc, tmp_wavs, joined, rendered_chars, kind, backend,
                     voice, speed, tags, ts_iso, ts_dt, keep_name=f"{ts_iso}-lf")
        raise
    finally:
        # Temp chunk WAVs are not artefacts (Trap 3) — removed on success and
        # on failure alike.
        _sinks.unlink_quiet(*tmp_wavs)

    # Best-effort cache hook — same rationale as render().
    _fire_history_appended(on_history_appended, entry, ts_iso)
    return entry


async def _render_longform_stream(
    text: str,
    kind: str,
    backend: "Backend",
    voice: str,
    speed: float,
    tags: list[str],
    chunks: list[str],
    ts_dt: datetime,
    ts_iso: str,
    httpx_client: httpx.AsyncClient | None,
    on_episode_event: Callable[[dict[str, Any]], None] | None,
    episode_registry: "EpisodeRegistry | None" = None,
    mock: bool = False,
    *,
    _prepend_wavs: list[Path] | None = None,
    _start_chunk_offset_chars: int = 0,
    _full_text_override: str | None = None,
    _seps: list[str] | None = None,
) -> dict[str, Any]:
    """Progressive (mode="stream") longform render.

    Resume (continue-a-draft) reuses this core via three private params:
      - ``_prepend_wavs``  — leading WAV(s) (the decoded draft mp3) seeded into
        ``transient_wavs`` BEFORE the loop, so the final concat joins
        draft + remainder into ONE row. Cleaned in the same finally.
      - ``_start_chunk_offset_chars`` — the char render-head the draft already
        reached; ``rendered_chars`` starts here so the SSE render-head and the
        persisted resume offset stay in episode_full_text space.
      - ``_full_text_override`` — the FULL joined text (incl. the already-
        rendered prefix) for episode_start so the reader grays the rendered
        prefix and animates only the remaining (``chunks``) tail.

    Serial per-chunk render (Trap 1). Each chunk is archived to its own
    transient wav and announced via chunk_ready as soon as it lands, so a
    client can begin playback before the whole episode finishes. After the
    final chunk, the transient wavs are concatenated gaplessly into the ONE
    canonical mp3 + ONE voice.db row (Trap 3), then episode_complete fires.

    Broadcast ordering (verified against state.py / http_server.py):
      episode_start  (public State.broadcast — ephemeral, no cache row yet)
      chunk_ready ×N (public State.broadcast — cumulative_audio_s = head)
      {render}       (fired by the explicit _fire_history_appended call at the
                      end of the render — after finalize/cleanup, synchronously,
                      BEFORE episode_complete below; NOT inside _insert_unique)
      episode_complete (public State.broadcast — additional marker, carries
                        the canonical row ts so the client swaps to it)
      episode_error  (ON FAILURE only, in place of episode_complete — carries
                      stage+message so a streaming client stops waiting)
    """

    def emit(event: dict[str, Any]) -> None:
        if on_episode_event is None:
            return
        try:
            on_episode_event(event)
        except Exception as exc:  # noqa: BLE001 — broadcast is best-effort
            logging.getLogger("voice_say").warning(
                "on_episode_event hook raised: %s", exc,
            )

    episode_id = secrets.token_hex(8)
    chars = len(text)
    total_chunks = len(chunks)

    # Register this episode so a concurrent POST /episode/<id>/cancel or
    # /finalize (a SEPARATE request — this render's /render_longform POST
    # stays open until the episode finishes) can signal us between chunks.
    # Unregistered in the finally. A None registry (tests / standalone) → no
    # control surface: nothing can cancel or finalize it.
    ctl = episode_registry.register(episode_id) if episode_registry is not None else None

    # episode_start — ONCE, before the chunk loop. No voice.db row exists
    # yet, so this rides the PUBLIC ephemeral broadcast path.
    # The exact text that will be read, as the daemon chunked it. The client
    # displays this and grays past the render-head (rendered_chars below), so
    # the read-while-rendering boundary is precise (same representation, not
    # the pre-normalization original).
    # On resume, the reader needs the FULL text (rendered prefix + remainder)
    # so it can gray the already-rendered prefix; `chunks` here is only the
    # remainder. Fresh renders join `chunks` (the whole text) as before.
    if _full_text_override is not None:
        episode_full_text = _full_text_override
    elif _seps is not None:
        # Reconstruct with the real join separators so a sentence-split over-long
        # paragraph reads as ONE paragraph (not fabricated breaks). seps[0] == ''.
        episode_full_text = "".join(_seps[i] + chunks[i] for i in range(len(chunks)))
    else:
        episode_full_text = "\n\n".join(chunks)
    # Audio seconds already rendered into the draft prefix (resume only). On a
    # resume the prefix mp3 is concatenated server-side, NOT streamed as
    # chunk_ready, so the client's render-head + playhead would start at 0 while
    # predicted_total_s covers the WHOLE text — the progress bar under-fills by
    # the prefix fraction. Emitting the prefix duration lets the client seed
    # both heads into full-text space. 0.0 for a fresh render (no prepend).
    prefix_audio_s = 0.0
    for _w in (_prepend_wavs or []):
        try:
            prefix_audio_s += await asyncio.to_thread(_sinks.probe_duration_s, _w, "wav")
        except Exception as exc:  # noqa: BLE001 — a probe failure just means no offset
            logging.getLogger("voice_say").warning(
                "prefix-audio probe failed for %s: %s", _w, exc)
    # predicted_total_s: a coarse text-derived estimate (snapped to the true
    # probed duration on episode_complete). A MOCK render replays FIXED fixtures
    # whose real duration is unrelated to char count, so chars/17.8 ≪ the actual
    # seconds-long audio → the render-head fraction, the time readout, and the
    # waveform frontier all saturate to 100% on the first chunk. The mock owns
    # its fixtures, so predict from their real durations (+ any resume prefix).
    predicted_total_s = chars / CHARS_PER_SECOND
    if mock:
        mock_total = _mock_total_audio_s(total_chunks)
        if mock_total > 0:
            predicted_total_s = prefix_audio_s + mock_total
    emit({
        "type": EVENT_EPISODE_START,
        "episode_id": episode_id,
        "total_chunks": total_chunks,
        "predicted_total_s": predicted_total_s,
        "chars": chars,
        "backend": backend.id,
        "voice": voice,
        "text": episode_full_text,
        "prefix_audio_s": prefix_audio_s,
    })

    # On resume, seed the leading WAV(s) (the decoded draft mp3) so the final
    # concat joins draft + remainder into ONE row. These are transient — the
    # finally drops them with the per-chunk wavs. list() so we never mutate the
    # caller's argument.
    transient_wavs: list[Path] = list(_prepend_wavs) if _prepend_wavs else []
    cumulative_audio_s = 0.0
    # Per-chunk (audio_s, char_offset) seams → persisted as the row's seam_map so
    # the finished read-along piecewise-interpolates each chunk's real pace.
    chunk_seams: list[tuple[float, int]] = []
    # Cumulative char offset into episode_full_text rendered so far — the
    # read-while-rendering "render head" the client grays past. On resume it
    # starts at the draft's offset so the head stays in full-text space.
    rendered_chars = _start_chunk_offset_chars
    finalized_early = False
    try:
        for idx, chunk in enumerate(chunks):
            seq = idx + 1
            # Cancel is the more destructive intent — check it FIRST so a
            # cancel + finalize race resolves to cancel uniformly (the mid-chunk
            # re-check below already lets a cancel win). Abort, no row.
            if ctl is not None and ctl.cancelled:
                raise RenderCancelled(episode_id)
            # Save-and-stop: a finalize was requested and this run has rendered
            # at least one chunk — keep what we have and stop here (we simply
            # don't start the next synth). chunk_seams, not transient_wavs: on a
            # resume the latter already holds the draft's lead audio.
            if ctl is not None and ctl.finalize_requested and chunk_seams:
                finalized_early = True
                break
            # Wrap the per-chunk synth in a task so a cancel can interrupt
            # the in-flight await promptly (the synth itself can run for
            # many seconds) instead of waiting for it to return.
            chunk_task = asyncio.ensure_future(
                _synth(chunk, backend, voice, speed, httpx_client,
                          response_format="wav", chunk_index=idx, mock=mock)
            )
            if ctl is not None:
                ctl.current_chunk_task = chunk_task
            try:
                audio = await chunk_task
            except asyncio.CancelledError:
                # request_cancel AND request_force_finalize both cancel
                # current_chunk_task. Tell three cases apart:
                #   • cancel              → discard everything (no row)
                #   • force-finalize      → drop THIS chunk, keep the
                #                           already-completed chunks as a
                #                           draft (or cancel if none yet)
                #   • outer teardown      → re-raise
                if ctl is not None and ctl.cancelled:
                    raise RenderCancelled(episode_id)
                if ctl is not None and ctl.force_finalize_requested:
                    if chunk_seams:
                        # break runs the finally (clears the task ref), exits
                        # the `async with`, then leaves the loop — the archive
                        # block below is skipped, so this chunk is dropped.
                        finalized_early = True
                        break
                    # Nothing completed yet → nothing to keep → cancel.
                    raise RenderCancelled(episode_id)
                raise
            finally:
                if ctl is not None:
                    ctl.current_chunk_task = None
            # Archive the chunk to its OWN transient wav so it is playable
            # immediately (chunk_ready carries the abs path). Cleaned up in
            # the finally after concat — these are NOT artefacts (Trap 3).
            try:
                wav_path = _write_temp_wav(
                    audio, f"vs-stream-{episode_id}-{idx:04d}-")
                transient_wavs.append(wav_path)
            except OSError as exc:
                raise RenderError(
                    "archive", f"chunk {idx} transient write: {exc}") from exc

            # Seam parity with the archive: trim this chunk's leading/trailing
            # silence to the same uniform pause concat_wavs_to_mp3 applies, so
            # play-while-rendering doesn't play each chunk's raw ~480 ms tail as
            # a gap. In place + no-op on ffmpeg failure. Done BEFORE the probe so
            # cumulative_audio_s (the render-head) reflects the trimmed audio the
            # client actually plays. The final concat re-trims idempotently.
            #
            # The FINAL planned chunk keeps its natural tail (trailing=False):
            # it has no following seam, so trailing-trimming it would clip the
            # last word's soft decay — both for live playback AND in the
            # transient wav the final concat joins (which applies the same
            # last-chunk exception). A save-and-stop can still tail-trim its last
            # KEPT chunk (the loop broke before reaching idx == last) — an
            # explicit cut, and the draft is re-concatenated on resume.
            is_last_chunk = idx == len(chunks) - 1
            await asyncio.to_thread(_sinks.trim_chunk_silence_inplace, wav_path,
                                    trailing=not is_last_chunk)

            chunk_duration_s = await asyncio.to_thread(_sinks.probe_duration_s, wav_path, "wav")
            cumulative_audio_s += chunk_duration_s
            # Advance the char render-head over episode_full_text: this chunk's
            # text plus the join separator that precedes it. With _seps the
            # separator is exact ('\n\n' at a paragraph boundary, ' ' inside a
            # sentence-split paragraph, '' for the very first chunk); seps[0] on a
            # resume is the real separator joining this remainder to the draft.
            if _seps is not None:
                rendered_chars += len(_seps[idx]) + len(chunk)
            else:
                precedes_sep = idx > 0 or _start_chunk_offset_chars > 0
                rendered_chars += len(chunk) + (2 if precedes_sep else 0)
            # chunk_ready — after the transient chunk file lands. The
            # cumulative sum IS the render-head the client tracks.
            emit({
                "type": EVENT_CHUNK_READY,
                "episode_id": episode_id,
                "seq": seq,
                "total_chunks": total_chunks,
                "chunk_path": str(wav_path),
                "chunk_duration_s": chunk_duration_s,
                "cumulative_audio_s": cumulative_audio_s,
                "rendered_chars": rendered_chars,
            })
            chunk_seams.append((cumulative_audio_s, rendered_chars))
            # Cancel may have arrived while we archived this chunk — honor it
            # before starting the next synth.
            if ctl is not None and ctl.cancelled:
                raise RenderCancelled(episode_id)
            # Save-and-stop may have arrived while we synthesized/archived this
            # chunk. The top-of-loop gate only catches a finalize requested
            # BEFORE a chunk starts (and only when a prior chunk exists), so a
            # single-chunk render — or a finalize during the LAST chunk — would
            # otherwise finish normally and never get tagged "draft". Re-check
            # here so the rendered-so-far audio is kept as a draft.
            if ctl is not None and ctl.finalize_requested:
                finalized_early = True
                break

        # Save-and-stop keeps the rendered-so-far audio AND tags it "draft"
        # so it lands in the Drafts category; a normal completion does not.
        finalize_tags = list(tags)
        if finalized_early and "draft" not in finalize_tags:
            finalize_tags.append("draft")

        # Persist the resume boundary ONLY on a finalized-early draft: the
        # joined full text it was chunked from (idempotent to re-chunk) and the
        # clean chunk-boundary char offset rendered so far. A later
        # POST /episode/resume re-chunks `episode_full_text`, skips chunks whose
        # cumulative end <= `rendered_chars`, and renders only the remainder. A
        # normal completion leaves both None, as on a /render row.
        resume_kwargs: dict[str, Any] = {}
        if finalized_early:
            resume_kwargs = {
                "resume_full_text": episode_full_text,
                "resume_char_offset": rendered_chars,
            }

        # From here a cancel can't stop the row (the route answers 409).
        if ctl is not None:
            ctl.finishing = True
        # Gapless concat → probe → build → ONE canonical row (Trap 2 + 3),
        # via the shared finalize tail. Same path as sequential.
        # Store `episode_full_text`, NOT the raw `text`: the seam_map char
        # offsets (chunk_seams → rendered_chars) are measured in
        # episode_full_text space (the daemon-chunked, whitespace-normalized
        # join), and the client indexes the read-along highlight into the
        # stored text with those offsets. Persisting the raw input — whose
        # interior blank-line runs and per-paragraph whitespace chunk_text
        # collapses — would leave the two in different coordinate spaces, so
        # the highlight drifts early and the last paragraph never fully
        # highlights. This also matches what the streaming client already saw
        # (episode_start.text == episode_full_text). The resume path is
        # already immune: it passes full==episode_full_text as both.
        entry = await _finalize_longform(
            transient_wavs, episode_full_text, kind, backend, voice, speed,
            finalize_tags, ts_iso, ts_dt, **resume_kwargs,
            chunk_seams=chunk_seams, prefix_audio_s=prefix_audio_s,
            seam_start_chars=_start_chunk_offset_chars,
        )
    except RenderCancelled:
        # Aborted via the registry: NO canonical row; transient wavs dropped
        # in the finally. Emit a terminal episode_cancelled so the streaming
        # client tears its provisional card down, then re-raise so the route
        # maps it to a 200 "cancelled" response.
        emit({"type": EVENT_EPISODE_CANCELLED, "episode_id": episode_id})
        raise
    except asyncio.CancelledError:
        _keep_on_teardown(transient_wavs[:len(_prepend_wavs or []) + len(chunk_seams)],
                          f"{ts_iso}-{episode_id}")
        raise
    except Exception as exc:
        # Mid-render failure: keep the finished chunks (as a resumable draft,
        # or the whole row if only the finalize failed), then emit a terminal
        # episode_error so a streaming client stops waiting on the
        # play-while-render card (without it the card can hang forever) and
        # re-raise so the route still maps RenderError → the right HTTP code.
        # Only chunks that completed (a chunk_seams entry) are kept; a resume
        # with no new chunk leaves its draft as it was.
        if chunk_seams:
            kept = transient_wavs[:len(_prepend_wavs or []) + len(chunk_seams)]
            await _salvage(exc, kept, episode_full_text, chunk_seams[-1][1], kind,
                     backend, voice, speed, tags, ts_iso, ts_dt,
                     keep_name=f"{ts_iso}-{episode_id}", chunk_seams=chunk_seams,
                     prefix_audio_s=prefix_audio_s,
                     seam_start_chars=_start_chunk_offset_chars)
        emit({
            "type": EVENT_EPISODE_ERROR,
            "episode_id": episode_id,
            "stage": getattr(exc, "stage", "internal"),
            "message": getattr(exc, "message", str(exc)),
            "saved_ts": getattr(exc, "saved_ts", None),
            "partial": getattr(exc, "partial", None),
        })
        raise
    finally:
        if episode_registry is not None:
            episode_registry.unregister(episode_id)
        # Remove the transient per-chunk wavs (Trap 3 — not artefacts).
        _sinks.unlink_quiet(*transient_wavs)

    # Canonical render event fires synchronously here (before the marker
    # below), keeping the {render} → episode_complete ordering the SSE
    # contract relies on. Best-effort, same rationale as render().
    _fire_history_appended(on_history_appended, entry, entry.get("ts"))

    # episode_complete — AFTER the canonical row exists. The ts is the
    # renders-row PK (String), matching VoiceEntry.id for the client swap.
    # save_and_stop marks a finalized-early partial so the client can tell it
    # apart from a full completion.
    emit({
        "type": EVENT_EPISODE_COMPLETE,
        "episode_id": episode_id,
        "ts": entry["ts"],
        "archive_path": entry["archive_path"],
        "duration_s": entry["duration_s"],
        "save_and_stop": finalized_early,
    })
    return entry


async def resume_longform(
    draft_ts: str,
    *,
    httpx_client: httpx.AsyncClient | None = None,
    on_episode_event: Callable[[dict[str, Any]], None] | None = None,
    episode_registry: "EpisodeRegistry | None" = None,
) -> dict[str, Any]:
    """Continue a draft as one episode (see _RenderGate); _resume_longform."""
    async with _GATE.episode():
        return await _resume_longform(
            draft_ts, httpx_client=httpx_client,
            on_episode_event=on_episode_event, episode_registry=episode_registry)


async def _resume_longform(
    draft_ts: str,
    *,
    httpx_client: httpx.AsyncClient | None = None,
    on_episode_event: Callable[[dict[str, Any]], None] | None = None,
    episode_registry: "EpisodeRegistry | None" = None,
) -> dict[str, Any]:
    """Continue a finalized-early draft: re-chunk the stored full text, SKIP
    the already-rendered chunks, render the remainder, and concat
    [draft mp3 + new chunks] into ONE new canonical row. The draft is then
    superseded (overlay deleted=true) so Drafts doesn't accumulate partials.

    Reuses _render_longform_stream wholesale (same episode_start / chunk_ready /
    episode_complete SSE contract → the streaming client UI works unchanged).
    A resumed render can itself be stopped-and-kept again (the tail re-persists
    a fresh resume offset), so recursive drafts work for free.
    """
    row = _db.get_render(draft_ts)
    if row is None:
        raise RenderError("request", f"no render {draft_ts!r}")
    full = row.get("resume_full_text")
    offset = row.get("resume_char_offset")
    if not full or offset is None:
        raise RenderError("request", "render is not a resumable draft")
    # A superseded draft (soft-deleted when a continuation saved) must not be
    # continued again: that would render its remainder a second time.
    if (_db.read_overlay(draft_ts) or {}).get("deleted"):
        raise RenderError("request", "draft was superseded or deleted; nothing to resume")

    backend = BACKENDS.get(row["backend"])
    if backend is None:
        raise RenderError("request", f"unknown backend {row['backend']!r}")
    voice = row.get("voice") or backend.default_voice
    speed = row.get("speed") or 1.0
    # Kind/tags inherit the draft's: a resumed render is the same utterance,
    # and we re-chunk the SAME joined text so chunk boundaries are identical.
    kind = row.get("kind") or classify_kind(full)
    # Drop the "draft" tag from the continuation — if it runs to completion it
    # is no longer a partial. A second Stop&keep re-adds it via the finalize tail.
    base_tags = [t for t in (row.get("tags") or []) if t != "draft"]
    # A mock draft resumes as a mock render too (stay model-free end to end).
    mock = "mock" in base_tags

    # The offset is a clean seam (rendered_chars advances by whole chunks), so
    # full[offset:] is exactly the unrendered tail: its leading separator plus
    # the remaining chunks. Chunk that tail with today's chunk size — the draft
    # may have been rendered under a different one, and re-chunking the WHOLE
    # text would then put seams where the offset doesn't fall (duplicated or
    # skipped text). A mock draft MUST re-chunk with the same _mock_chunk_plan it
    # was drafted with (n = _mock_chunk_count) and skip whole chunks.
    remaining: list[str] = []
    remaining_seps: list[str] = []
    if mock:
        all_chunks = _mock_chunk_plan(full, _mock_chunk_count())
        all_seps = [''] + ['\n\n'] * (len(all_chunks) - 1)
        acc = 0
        for idx, ch in enumerate(all_chunks):
            acc += len(all_seps[idx]) + len(ch)
            if acc > offset:
                remaining.append(ch)
                remaining_seps.append(all_seps[idx])
    else:
        tail = full[offset:]
        body = tail.lstrip()
        remaining, remaining_seps = _chunk_longform(body, backend.chunk_max)
        if remaining:
            remaining_seps[0] = tail[:len(tail) - len(body)]
    if not remaining:
        raise RenderError("request", "draft already complete; nothing to resume")

    # The existing draft mp3 becomes the LEADING segment of the concat.
    draft_audio = _sinks.locate_audio(row["archive_path"])
    if draft_audio is None:
        raise RenderError("archive", "draft audio missing; cannot resume")
    # Surface a decode failure as a proper archive-stage error (like
    # _finalize_longform) instead of an opaque 500 / generic crash handler.
    try:
        lead_wav = await asyncio.to_thread(_sinks.decode_mp3_to_wav, draft_audio)
    except _sinks.ConcatError as exc:
        raise RenderError("archive", str(exc)) from exc

    ts_dt = datetime.now(timezone.utc)
    ts_iso = ts_dt.strftime("%Y-%m-%dT%H:%M:%S.%fZ")

    try:
        entry = await _render_longform_stream(
            full, kind, backend, voice, float(speed), base_tags,
            remaining, ts_dt, ts_iso, httpx_client, on_episode_event,
            episode_registry,
            mock=mock,
            _prepend_wavs=[lead_wav],
            _start_chunk_offset_chars=offset,
            _full_text_override=full,
            _seps=remaining_seps,
        )
    except RenderCancelled:
        # No new row; _render_longform_stream's finally already dropped the
        # lead wav (it was seeded into transient_wavs). Re-raise so the route
        # maps it to a 200 cancelled. The draft is left intact (not superseded).
        raise
    except Exception as exc:
        # A failure after ≥1 new chunk saved a longer draft (old audio + new
        # chunks): it supersedes this one, as a completed continuation would.
        if getattr(exc, "saved_ts", None):
            _carry_overlay(draft_ts, exc.saved_ts)  # type: ignore[attr-defined]
            _supersede_draft(draft_ts)
        raise
    finally:
        # Idempotent safety net for the leak window: the inner stream's finally
        # already drops lead_wav on the normal/cancel/error paths (it's seeded
        # into transient_wavs), so missing_ok makes this a no-op there; it only
        # actually deletes when that finally never ran (a raise before chunk
        # registration) — zero behaviour change on every reachable path.
        lead_wav.unlink(missing_ok=True)

    _carry_overlay(draft_ts, entry["ts"])
    _supersede_draft(draft_ts)
    return entry


def _carry_overlay(draft_ts: str, new_ts: str) -> None:
    """Give the continuation the draft's title, series/episode, star,
    bookmarks and user tag edits — without this a resumed series episode drops out of its series
    when the draft is superseded. Best-effort, like _supersede_draft."""
    ov = _db.read_overlay(draft_ts)
    if not ov:
        return
    try:
        from . import overlays
        overlays.write(new_ts, starred=bool(ov.get("starred")),
                       bookmarks=ov.get("bookmarks") or [],
                       tags=ov.get("tags") or [],
                       removed_tags=ov.get("removed_tags") or [],
                       title=ov.get("title") or "",
                       series=ov.get("series"), episode=ov.get("episode"))
    except Exception as exc:  # noqa: BLE001 — carrying metadata is best-effort
        logging.getLogger("voice_say").warning(
            "resume: could not carry overlay %s -> %s: %s", draft_ts, new_ts, exc)


def _supersede_draft(draft_ts: str) -> None:
    """Soft-delete a continued draft so Drafts shows only the continuation,
    whose audio is a strict superset of it. Routed through overlays.write()
    (not a raw _db.upsert_overlay) so the same validation runs AND the
    on_overlay_written hook fires the overlay SSE that hides the draft in the
    client immediately. Lazy import avoids the overlays→engine import cycle.
    Best-effort: a failure leaves the draft visible but undoes nothing."""
    try:
        from . import overlays
        overlays.write(draft_ts, deleted=True)
    except Exception as exc:  # noqa: BLE001 — superseding is best-effort
        logging.getLogger("voice_say").warning(
            "resume: could not supersede draft %s: %s", draft_ts, exc)


# Voices the servers listed, for entries without a `voices` list:
# backend id -> (monotonic time asked, voices). A server that does not list
# voices (404) is not asked again; one that timed out or failed, after
# _VOICES_RETRY_S. A refused connection (server not up yet) costs nothing, so
# it is asked again on the next request.
_listed_voices: dict[str, tuple[float, tuple[str, ...]]] = {}
_unlisted: set[str] = set()
_VOICES_RETRY_S = 60.0


def voices_of(b: Backend) -> tuple[str, ...]:
    return b.voices or _listed_voices.get(b.id, (0.0, ()))[1]


async def refresh_voices(client: httpx.AsyncClient, only: str | None = None) -> None:
    """Ask the servers that list their own voices, unless asked recently."""
    now = time.monotonic()
    todo = [b for b in BACKENDS.values()
            if b.lists_voices and b.id not in _unlisted and only in (None, b.id)
            and not _listed_voices.get(b.id, (0.0, ()))[1]
            and now - _listed_voices.get(b.id, (-_VOICES_RETRY_S, ()))[0] >= _VOICES_RETRY_S]
    if todo:
        await asyncio.gather(*(_ask_voices(b, client) for b in todo))


async def _ask_voices(b: Backend, client: httpx.AsyncClient) -> None:
    found: tuple[str, ...] = ()
    try:
        r = await client.get(f"{b.base_url}/v1/audio/voices", params={"model": b.model},
                             timeout=3.0)
        if r.status_code in (404, 405):
            _unlisted.add(b.id)
        elif r.status_code == 200:
            body = r.json()
            items = body.get("data", []) if isinstance(body, dict) else body
            found = tuple(str(v["id"]) for v in items if isinstance(v, dict) and v.get("id"))
    except httpx.ConnectError:
        return
    except (httpx.HTTPError, ValueError):
        pass
    _listed_voices[b.id] = (time.monotonic(), found)


def list_backends() -> list[dict[str, Any]]:
    return [
        {
            "id": b.id, "label": b.label, "port": b.port, "url": b.base_url,
            "model": b.model,
            "default_voice": b.default_voice,
            "voices": list(voices_of(b)),
            "supports_speed": b.supports_speed,
            "supports_emotion_tags": b.supports_emotion_tags,
            "accent": b.accent,
            "output_format": b.output_format,
            "service": b.service,
        }
        for b in BACKENDS.values()
    ]


def list_voices(backend_id: str) -> list[str]:
    b = BACKENDS.get(backend_id)
    return list(voices_of(b)) if b else []


def _insert_unique(entry: dict[str, Any], ts_dt: datetime) -> None:
    """Insert the render row, bumping the microsecond-precision ts on a PK
    collision. Two renders sharing a ts would conflate their progress/overlay
    rows (also keyed by ts), so the id must be unique. Collisions are
    astronomically rare in practice (µs clock) but possible under a frozen
    clock or sub-µs concurrency; a handful of bumps always resolves it."""
    for _ in range(8):
        try:
            _db.insert_render(entry)
            return
        except sqlite3.IntegrityError:
            ts_dt = ts_dt + timedelta(microseconds=1)
            entry["ts"] = ts_dt.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    raise RuntimeError("could not allocate a unique render ts after 8 attempts")


def _resolve_voice(voice: str | None, backend: Backend) -> str:
    """Pick the voice for a render — backend-aware.

    Precedence: an explicit per-call voice always wins (pass-through — the
    declared `backend.voices` is a curated subset, not the full set a backend
    accepts, so we never reject an explicit voice). With no explicit voice,
    the configured global default (``config.DEFAULT_VOICE``) is used ONLY when
    the chosen backend actually declares it; otherwise the backend falls back
    to its OWN ``default_voice``.

    So a voice that exists on one backend is never sent to another backend
    that has no such voice (the backend would fail the request). Mirrors the
    macOS app's ComposeView voice-defaulting (one resolution rule, both
    surfaces)."""
    if voice:
        return voice
    gdv = config.DEFAULT_VOICE
    if gdv and gdv in voices_of(backend):
        return gdv
    return backend.default_voice or gdv or "default"


def _validate(text: str, backend_id: str, voice: str | None,
              tags: list[str] | None) -> tuple[str, str, Backend, list[str]]:
    """Run all front-door validation in one place: text shape, backend
    existence, tag normalization + closed-vocab check, emotion-tag
    stripping for backends that don't support them."""
    text = (text or "").strip()
    if not text:
        raise RenderError("request", "empty text")
    if len(text) > config.MAX_RENDER_CHARS:
        raise RenderError("request", f"text too long ({len(text)} > {config.MAX_RENDER_CHARS})")
    if backend_id not in BACKENDS:
        raise RenderError("request", f"unknown backend {backend_id!r}")
    backend = BACKENDS[backend_id]

    norm_tags = [n for t in (tags or []) if (n := normalize_tag(t))]
    bad_tags = unknown_tags(norm_tags)
    if bad_tags:
        raise RenderError(
            "request",
            f"tag(s) not in allowed_tags: {bad_tags}; "
            f"allowed={sorted(allowed_tag_set())}")

    if not backend.supports_emotion_tags:
        text = _strip_emotion_tags(text)
        if not text:
            raise RenderError("request", "empty text after stripping emotion tags")

    return text, _resolve_voice(voice, backend), backend, norm_tags


def apply_pronunciation(text: str, table: dict[str, str] | None = None) -> str:
    """Rewrite words the voice mispronounces, from config `[pronounce]`
    (written → spoken, e.g. a first name). Whole words only, case-sensitive,
    so "Siobhan's" follows "Siobhan" and "Siobhana" is left alone. Used on the text
    handed to the backend only: the archived transcript keeps the written form."""
    table = config.PRONOUNCE if table is None else table
    for written, spoken in table.items():
        text = re.sub(rf"(?<!\w){re.escape(written)}(?!\w)", spoken, text)
    return text


async def _tts_post(text: str, backend: Backend, voice: str, speed: float,
                    client: httpx.AsyncClient | None,
                    response_format: str | None = None,
                    chunk_index: int | None = None,
                    mock: bool = False) -> bytes:
    # Model-bypass mock: replay a pre-existing fixture WAV on a timer, no network.
    if mock:
        return await _mock_synth(chunk_index or 0)
    text = apply_pronunciation(text)
    # response_format defaults to the backend's native container; the
    # longform path overrides it to "wav" so chunks come back as PCM for
    # gapless concatenation (mp3 chunk concat leaves seam clicks).
    payload: dict[str, Any] = {
        "model": backend.model,
        "input": text,
        "response_format": response_format or backend.output_format,
    }
    # "default" is a sentinel — omit the voice field so the backend picks.
    if voice and voice != "default":
        payload["voice"] = voice
    if backend.supports_speed and speed != 1.0:
        payload["speed"] = speed

    timeout = httpx.Timeout(backend.timeout_s)
    own = client is None
    cli = client or httpx.AsyncClient(timeout=timeout)
    try:
        for attempt in range(TTS_RETRIES + 1):
            last = attempt == TTS_RETRIES
            try:
                r = await cli.post(backend.speech_url, json=payload, timeout=timeout)
            except httpx.HTTPError as exc:
                if last or not isinstance(exc, _TRANSIENT_ERRORS):
                    raise RenderError("tts", f"network: {exc}") from exc
                why = f"network: {exc!r}"
            else:
                if r.status_code in _TRANSIENT_STATUS and not last:
                    why = f"HTTP {r.status_code}"
                else:
                    if r.status_code != 200:
                        snippet = r.text[:300] if r.text else ""
                        raise RenderError("tts", f"HTTP {r.status_code}: {snippet}")
                    if not r.content:
                        raise RenderError("tts", "empty audio body")
                    return r.content
            logging.getLogger("voice_say").warning(
                "tts %s (chunk %s): %s; retry %d/%d in %.0fs", backend.id,
                chunk_index, why, attempt + 1, TTS_RETRIES, TTS_RETRY_DELAY_S)
            await asyncio.sleep(TTS_RETRY_DELAY_S)
        raise AssertionError("unreachable")  # the last attempt returns or raises
    finally:
        if own:
            await cli.aclose()
