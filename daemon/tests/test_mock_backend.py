"""Tests for the model-bypass mock (engine.render_longform(mock=True)).

When a render carries mock=true the engine SKIPS the model and replays
PRE-EXISTING chunk WAVs on a timer — no model, no network — but drives the
REAL streaming pipeline. Asserts:

  - a mock render produces exactly len(fixtures) chunks of the real text;
  - stream mode emits 1 episode_start + N chunk_ready (cumulative_audio_s
    strictly increasing) + 1 episode_complete;
  - it lands exactly ONE canonical row, auto-tagged "mock";
  - sequential mode emits NO episode_* events and still lands one tagged row;
  - a normal (mock=False) render is unaffected — the model path is taken and
    the row is NOT tagged "mock".

Stubs the sinks + db so no ffmpeg or real voice.db is touched, and the fixture
bytes so the test does not depend on the local (gitignored) fixture files.
"""
from __future__ import annotations

import asyncio
import io
import wave
from pathlib import Path

import pytest

from voice_say import engine, config


def _run(coro):
    return asyncio.run(coro)


def _wav_bytes(seconds: float, rate: int = 8000) -> bytes:
    """A minimal real PCM WAV of a known duration, so _mock_fixture_durations
    (which parses the WAV header) returns exactly `seconds`."""
    frames = int(round(seconds * rate))
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(b"\x00\x00" * frames)
    return buf.getvalue()


def _backend_id() -> str:
    return next(iter(engine.BACKENDS))


N_FIXTURES = 7


@pytest.fixture
def mock_pipeline(monkeypatch, tmp_path):
    # Fake pre-existing fixtures → chunk count = N_FIXTURES. Zero timer: floor
    # (MOCK_CHUNK_MS) AND audio-scaled pause (MOCK_RTF) both off so tests are
    # instant even when fixtures are real, seconds-long WAVs.
    monkeypatch.setattr(config, "MOCK_CHUNK_MS", 0)
    monkeypatch.setattr(config, "MOCK_RTF", 0.0)
    monkeypatch.setattr(config, "MOCK_CHUNK_MULT", 1)   # one chunk per fixture
    monkeypatch.setattr(
        engine, "_MOCK_FIXTURES",
        [f"RIFFmock-chunk-{i}".encode() for i in range(N_FIXTURES)])

    created: list[Path] = []
    inserts: list[dict] = []
    real_mkstemp = engine.tempfile.mkstemp

    def tracking_mkstemp(*a, **k):
        fd, name = real_mkstemp(*a, **k)
        p = Path(name)
        if "stream" in p.name or "vs-lf" in p.name:
            created.append(p)
        return fd, name

    def fake_concat(wavs, out_stem):
        out = tmp_path / f"{out_stem}.mp3"
        out.write_bytes(b"ID3mock-concat")
        return out

    # Distinct positive per-chunk durations so cumulative_audio_s strictly
    # increases; the trailing default covers the final concat probe.
    _durations = iter([0.5, 0.7, 0.9, 1.1, 1.3, 1.5, 1.7, 1.9, 2.1, 2.3])

    def fake_probe(path, fmt="mp3"):
        return next(_durations, 3.0)

    monkeypatch.setattr(engine.tempfile, "mkstemp", tracking_mkstemp)
    monkeypatch.setattr(engine._sinks, "concat_wavs_to_mp3", fake_concat)
    monkeypatch.setattr(engine._sinks, "probe_duration_s", fake_probe)
    monkeypatch.setattr(
        engine._sinks, "trim_chunk_silence_inplace", lambda *_, **__: None)
    monkeypatch.setattr(
        engine._db, "insert_render", lambda e: inserts.append(dict(e)))
    return {"created": created, "inserts": inserts}


def test_mock_stream_one_chunk_per_fixture_and_tags(mock_pipeline):
    """Short input still yields one chunk per fixture; full SSE contract; one row."""
    events: list[dict] = []

    entry = _run(engine.render_longform(
        "just a few words here",          # short → still N_FIXTURES chunks
        backend_id=_backend_id(),
        mode="stream",
        on_episode_event=events.append,
        mock=True,
    ))

    starts = [e for e in events if e["type"] == "episode_start"]
    chunks = [e for e in events if e["type"] == "chunk_ready"]
    completes = [e for e in events if e["type"] == "episode_complete"]

    assert len(starts) == 1
    assert starts[0]["total_chunks"] == N_FIXTURES
    assert len(chunks) == N_FIXTURES
    assert [c["seq"] for c in chunks] == list(range(1, N_FIXTURES + 1))

    cum = [c["cumulative_audio_s"] for c in chunks]
    assert cum == sorted(cum) and len(set(cum)) == len(cum), cum

    assert len(completes) == 1
    assert len(mock_pipeline["inserts"]) == 1
    assert "mock" in (mock_pipeline["inserts"][0].get("tags") or [])
    assert "mock" in (entry.get("tags") or [])

    leaked = [p for p in mock_pipeline["created"] if p.exists()]
    assert leaked == [], f"mock leaked transient wavs: {leaked}"


def test_mock_sequential_no_events_one_tagged_row(mock_pipeline):
    """Default (sequential) mode: no episode_* events, one row tagged mock."""
    events: list[dict] = []

    _run(engine.render_longform(
        "another short mock render please",
        backend_id=_backend_id(),
        on_episode_event=events.append,   # supplied but ignored in sequential
        mock=True,
    ))

    assert events == []
    assert len(mock_pipeline["inserts"]) == 1
    assert "mock" in (mock_pipeline["inserts"][0].get("tags") or [])


def test_non_mock_render_unaffected(mock_pipeline, monkeypatch):
    """Without mock=True the model path is taken and the row is NOT tagged mock."""
    calls: list[tuple] = []

    async def fake_tts_post(text, backend, voice, speed, client,
                            response_format=None, chunk_index=None, mock=False, **_kw):
        calls.append((chunk_index, mock))
        return b"RIFFreal" + text.encode("utf-8")[:8]

    monkeypatch.setattr(engine, "_tts_post", fake_tts_post)
    events: list[dict] = []

    _run(engine.render_longform(
        "a normal render, no mock flag set at all",
        backend_id=_backend_id(),
        mode="stream",
        on_episode_event=events.append,
    ))

    assert calls, "model synth path was never called"
    assert all(m is False for (_, m) in calls)
    assert len(mock_pipeline["inserts"]) == 1
    assert "mock" not in (mock_pipeline["inserts"][0].get("tags") or [])


def test_mock_predicted_total_tracks_fixture_durations(mock_pipeline, monkeypatch):
    """episode_start.predicted_total_s for a mock render reflects the REAL fixture
    durations, not chars/CHARS_PER_SECOND. Regression: the text estimate is tiny
    next to the seconds-long fixtures, so the render-head fraction / time readout
    / waveform frontier saturated to 100% on the first chunk."""
    durs = [0.5, 1.0, 1.5]
    monkeypatch.setattr(engine, "_MOCK_FIXTURES", [_wav_bytes(d) for d in durs])
    events: list[dict] = []
    _run(engine.render_longform(
        "a few words", backend_id=_backend_id(), mode="stream",
        on_episode_event=events.append, mock=True))
    start = next(e for e in events if e["type"] == "episode_start")
    assert start["total_chunks"] == len(durs)
    assert start["predicted_total_s"] == pytest.approx(sum(durs), abs=0.05)
    # And decisively larger than the text-derived estimate it replaced.
    assert start["predicted_total_s"] > len("a few words") / engine.CHARS_PER_SECOND


def test_mock_draft_resumes_model_free(mock_pipeline, monkeypatch, tmp_path):
    """resume_longform of a mock-tagged draft STAYS mock — it replays fixtures and
    never touches the real model. Regression: `mock` was derived from the draft
    tags but never threaded into _render_longform_stream, so resume hit the
    (absent) model."""
    monkeypatch.setattr(
        engine, "_MOCK_FIXTURES", [_wav_bytes(0.5) for _ in range(N_FIXTURES)])
    full = "one two three four five six seven eight nine ten eleven twelve"
    plan = engine._mock_chunk_plan(full, N_FIXTURES)
    # Draft kept only the first chunk → offset is its char length (no leading sep).
    offset = len(plan[0])
    draft_mp3 = tmp_path / "draft.mp3"
    draft_mp3.write_bytes(b"ID3draft")
    (tmp_path / "lead.wav").write_bytes(b"RIFFlead")
    row = {
        "backend": _backend_id(), "voice": None, "speed": 1.0,
        "kind": "render", "tags": ["mock"],
        "resume_full_text": "\n\n".join(plan), "resume_char_offset": offset,
        "archive_path": str(draft_mp3),
    }
    monkeypatch.setattr(engine._db, "get_render", lambda ts: dict(row))
    monkeypatch.setattr(engine._sinks, "decode_mp3_to_wav",
                        lambda p: tmp_path / "lead.wav")
    import voice_say.overlays as overlays
    monkeypatch.setattr(overlays, "write", lambda *a, **k: None)

    seen_mock: list[bool] = []
    real_tts = engine._tts_post

    async def spy_tts(text, backend, voice, speed, client,
                      response_format=None, chunk_index=None, mock=False, **_kw):
        seen_mock.append(mock)
        return await real_tts(text, backend, voice, speed, client,
                              response_format=response_format,
                              chunk_index=chunk_index, mock=mock)

    monkeypatch.setattr(engine, "_tts_post", spy_tts)
    events: list[dict] = []
    _run(engine.resume_longform("draft-ts", on_episode_event=events.append))

    assert seen_mock, "no chunk synth happened on resume"
    assert all(m is True for m in seen_mock), f"resume hit the model: {seen_mock}"
    completes = [e for e in events if e["type"] == "episode_complete"]
    assert len(completes) == 1
