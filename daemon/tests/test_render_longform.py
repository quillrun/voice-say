"""Longform render tests — the chunk + concat path.

Exercises `engine.render_longform`: multi-paragraph text → chunked → each
chunk rendered SERIALLY to WAV against a mock TTS → gapless concat into
ONE mp3 → exactly ONE archive file + ONE db row.

The mock TTS returns a small but VALID 24 kHz mono PCM WAV (backend
emit 24 kHz mono) so the real local ffmpeg concat→mp3 runs end to end —
mocking ffmpeg's PCM math would prove nothing. ffmpeg/ffprobe are at
/opt/homebrew/bin.

Run:
  cd system/services/voice-say
  .venv/bin/pytest -v tests/test_render_longform.py
"""
from __future__ import annotations

import asyncio
import io
import shutil
import struct
import wave
from pathlib import Path

import pytest
from aiohttp import web

import voice_say.engine as engine
import voice_say._db as _db
import voice_say._sinks as _sinks


# Each chunk's mock WAV is ~0.25 s of 24 kHz mono silence — long enough
# that ffprobe reads a non-trivial duration, small enough to stay cheap.
_SAMPLE_RATE = 24_000
_CHUNK_SECONDS = 0.25
_FRAMES = int(_SAMPLE_RATE * _CHUNK_SECONDS)


def _make_wav_bytes(frames: int = _FRAMES, rate: int = _SAMPLE_RATE) -> bytes:
    """A valid 16-bit 24 kHz mono PCM WAV of `frames` silent samples."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)  # 16-bit
        w.setframerate(rate)
        w.writeframes(struct.pack("<%dh" % frames, *([0] * frames)))
    return buf.getvalue()


FAKE_WAV = _make_wav_bytes()


# A 3-chunk longform input. Each paragraph is padded past the 1200-char
# ceiling-aware accumulation: three ~900-char paragraphs accumulate as
# (p1) | (p2) | (p3) — every pair would exceed 1200, so the chunker emits
# one chunk per paragraph → exactly 3 chunks.
def _para(label: str) -> str:
    body = (f"This is paragraph {label}. " * 40).strip()  # ~ 25*40 = ~1000 chars
    return body


MULTI_PARA_TEXT = "\n\n".join(_para(x) for x in ("alpha", "bravo", "charlie"))


@pytest.fixture
async def mock_tts():
    """A real aiohttp server pretending to be a TTS backend. Echoes a valid
    24 kHz mono WAV regardless of input. Returns the URL prefix."""
    app = web.Application()

    async def handler(request: web.Request) -> web.Response:
        body = await request.json()
        if not body.get("input"):
            return web.json_response({"error": "empty"}, status=400)
        # Longform requests must ask for wav so concat gets PCM (Trap 2).
        assert body.get("response_format") == "wav", \
            f"longform must request wav, got {body.get('response_format')!r}"
        return web.Response(body=FAKE_WAV, content_type="audio/wav")

    app.router.add_post("/v1/audio/speech", handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    yield f"http://127.0.0.1:{port}"
    await runner.cleanup()


@pytest.fixture
def mock_backend(monkeypatch, mock_tts):
    """Pin a synthetic single-entry catalog pointed at the mock TTS.
    Deliberately not the shipped tts-local entries: their whole-module
    longform_chunk_max (12500) would collapse the multi-paragraph fixtures
    here to one chunk, and these tests exercise the daemon-level chunk +
    concat path under the global LONGFORM_CHUNK_MAX."""
    fake = engine.Backend(
        id="test-lf", label="TestLF", port=int(mock_tts.split(":")[-1]),
        default_voice="af_alloy", voices=("af_alloy",),
        supports_speed=False,
        supports_emotion_tags=False,
        accent="#888888", timeout_s=60.0,
        output_format="mp3",
    )
    monkeypatch.setattr(engine, "BACKENDS", {"test-lf": fake})
    return fake


@pytest.fixture(autouse=True)
def _require_ffmpeg():
    """Skip the whole module if the real ffmpeg/ffprobe aren't installed —
    the concat path is exercised end to end against local binaries."""
    if not (shutil.which(_sinks.FFMPEG) or Path(_sinks.FFMPEG).exists()):
        pytest.skip("ffmpeg not available at /opt/homebrew/bin")
    if not (shutil.which(_sinks.FFPROBE) or Path(_sinks.FFPROBE).exists()):
        pytest.skip("ffprobe not available at /opt/homebrew/bin")


def test_chunker_splits_multi_para_into_three():
    """The multi-paragraph fixture must split into exactly 3 chunks
    (one per ~1000-char paragraph; any pair exceeds the 1200 ceiling)."""
    chunks = engine.chunk_text(MULTI_PARA_TEXT)
    assert len(chunks) == 3
    # Boundaries land on paragraphs — no chunk over the ceiling.
    assert all(len(c) <= engine.LONGFORM_CHUNK_MAX for c in chunks)


def test_chunker_giant_paragraph_sentence_splits():
    """A single paragraph past MAX is sentence-split, not truncated."""
    giant = ("Sentence number one is here. " * 100).strip()  # ~2900 chars
    assert len(giant) > engine.LONGFORM_CHUNK_MAX
    chunks = engine.chunk_text(giant)
    assert len(chunks) >= 2
    assert all(len(c) <= engine.LONGFORM_CHUNK_MAX for c in chunks)
    # Round-trips all the words (no silent loss at sentence seams).
    assert "".join(chunks).count("Sentence number one is here") == 100


async def test_render_longform_one_entry_one_row(isolated_paths, mock_backend):
    """>=3 chunks → ONE returned entry, ONE db row, ONE archive file."""
    chunks = engine.chunk_text(MULTI_PARA_TEXT)
    assert len(chunks) >= 3

    entry = await engine.render_longform(
        MULTI_PARA_TEXT, backend_id="test-lf", tags=["longform"])

    # Exactly one entry, one row.
    rows = engine.read_history()
    assert len(rows) == 1
    assert rows[0]["ts"] == entry["ts"]
    assert _db.get_render(entry["ts"]) is not None

    # One archive file, mp3, present on disk.
    audio = Path(entry["archive_path"])
    assert audio.is_file()
    assert audio.suffix == ".mp3"
    assert entry["format"] == "mp3"
    assert entry["tags"] == ["longform"]
    # Full transcript persisted untruncated.
    assert _db.get_render(entry["ts"])["text"] == entry["text"]


async def test_render_longform_duration_exceeds_single_chunk(isolated_paths, mock_backend):
    """The joined track must be longer than a single chunk — proof the
    chunks were concatenated, not just the first one written."""
    n_chunks = len(engine.chunk_text(MULTI_PARA_TEXT))
    assert n_chunks >= 3

    entry = await engine.render_longform(MULTI_PARA_TEXT, backend_id="test-lf")

    single = _CHUNK_SECONDS
    # Concatenated >= n_chunks * single (minus encoder slack). Assert it's
    # clearly past a single chunk's duration.
    assert entry["duration_s"] > single * 1.5
    # Sanity: roughly n_chunks chunks' worth (allow generous LAME slack).
    assert entry["duration_s"] > single * (n_chunks - 1)


async def test_render_longform_cleans_up_temp_wavs(isolated_paths, mock_backend, tmp_path, monkeypatch):
    """Per-chunk temp WAVs are deleted; only the final mp3 remains under
    the archive tree. Redirect tempfile at a watched dir to count leftovers."""
    watch = tmp_path / "tmp-wavs"
    watch.mkdir()
    monkeypatch.setattr(engine.tempfile, "tempdir", str(watch), raising=False)
    # mkstemp honours tempfile.tempdir when dir is not passed.
    monkeypatch.setenv("TMPDIR", str(watch))

    await engine.render_longform(MULTI_PARA_TEXT, backend_id="test-lf")

    assert (watch / "voice-say").is_dir()            # the chunks were written here
    leftover_wavs = list(watch.rglob("vs-lf-*.wav"))
    assert leftover_wavs == [], f"temp chunk WAVs not cleaned: {leftover_wavs}"


async def test_render_longform_serial_semaphore_is_private(isolated_paths, mock_backend):
    """Trap 1: chunks render strictly one-at-a-time. We instrument the
    mock to track concurrent in-flight requests; max concurrency must be 1
    even though BACKEND_CONCURRENCY is 2."""
    state = {"inflight": 0, "max": 0}

    # Re-point the test backend at a fresh server that records concurrency.
    app = web.Application()

    async def handler(request: web.Request) -> web.Response:
        import asyncio
        body = await request.json()
        state["inflight"] += 1
        state["max"] = max(state["max"], state["inflight"])
        await asyncio.sleep(0.02)  # widen the window for overlap detection
        state["inflight"] -= 1
        if not body.get("input"):
            return web.json_response({"error": "empty"}, status=400)
        return web.Response(body=FAKE_WAV, content_type="audio/wav")

    app.router.add_post("/v1/audio/speech", handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    try:
        real = engine.BACKENDS["test-lf"]
        fake = engine.Backend(
            id=real.id, label=real.label, port=port,
            default_voice=real.default_voice, voices=real.voices,
            supports_speed=real.supports_speed,
            supports_emotion_tags=real.supports_emotion_tags,
            accent=real.accent, timeout_s=real.timeout_s,
            output_format=real.output_format,
        )
        engine.BACKENDS["test-lf"] = fake
        assert len(engine.chunk_text(MULTI_PARA_TEXT)) >= 3
        await engine.render_longform(MULTI_PARA_TEXT, backend_id="test-lf")
    finally:
        engine.BACKENDS["test-lf"] = real
        await runner.cleanup()

    assert state["max"] == 1, f"longform ran chunks in parallel (max={state['max']})"


async def test_render_longform_empty_text_raises(isolated_paths, mock_backend):
    with pytest.raises(engine.RenderError) as ei:
        await engine.render_longform("   ", backend_id="test-lf")
    assert ei.value.stage == "request"


async def test_render_lock_serializes_concurrent_renders(isolated_paths, mock_backend):
    """Global single-flight (engine._render_lock): two render_longform calls
    fired CONCURRENTLY never overlap — one episode runs start→complete before
    the other's episode_start fires. Without the lock the two episodes' SSE
    events would interleave (both episode_start near-simultaneously). This is
    the daemon guarantee the macOS client's single `streamingEpisode` view
    (and the queue's 'one render at a time') depends on."""
    events: list[str] = []  # episode_id per SSE event, in fire order

    def rec(ev: dict) -> None:
        eid = ev.get("episode_id")
        if eid is not None and ev.get("type"):
            events.append(eid)

    await asyncio.gather(
        engine.render_longform(MULTI_PARA_TEXT, backend_id="test-lf",
                               mode="stream", on_episode_event=rec),
        engine.render_longform(MULTI_PARA_TEXT, backend_id="test-lf",
                               mode="stream", on_episode_event=rec),
    )

    assert events, "no episode events captured"
    assert len(set(events)) == 2, f"expected 2 distinct episodes, got {set(events)}"
    # Contiguous runs of the same episode_id: single-flight => exactly 2 runs
    # (episode A fully, then episode B fully). Interleaving => more than 2.
    runs = sum(1 for i, e in enumerate(events) if i == 0 or e != events[i - 1])
    assert runs == 2, f"episode events interleaved (runs={runs}): {events}"


async def test_sequential_failure_preserves_error_and_cleans_up(
        isolated_paths, mock_backend, tmp_path, monkeypatch):
    """A mid-render chunk failure must (1) re-raise the ORIGINAL render
    error — not a secondary error from the cleanup/logging path (an
    undefined-`log` NameError once did this: a bare `log.` in
    the failure path masked the real render error) and (2) delete the
    completed chunk WAVs, which are not artefacts."""
    watch = tmp_path / "tmp-wavs"
    watch.mkdir()
    monkeypatch.setattr(engine.tempfile, "tempdir", str(watch), raising=False)
    monkeypatch.setenv("TMPDIR", str(watch))

    calls = {"n": 0}

    async def tts_fails_on_second(chunk, backend, voice, speed, client, **kw):
        calls["n"] += 1
        if calls["n"] >= 2:
            raise engine.RenderError("tts", "chunk 2 exploded")
        return FAKE_WAV

    monkeypatch.setattr(engine, "_tts_post", tts_fails_on_second)

    with pytest.raises(engine.RenderError, match="chunk 2 exploded"):
        await engine.render_longform(MULTI_PARA_TEXT, backend_id="test-lf")

    assert calls["n"] == 2   # one chunk landed on disk before the failure
    leftover_wavs = list(watch.rglob("vs-lf-*.wav"))
    assert leftover_wavs == [], f"temp chunk WAVs not cleaned: {leftover_wavs}"
