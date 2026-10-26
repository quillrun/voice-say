"""Tests for engine.render_longform mode="stream" (progressive broadcast).

Self-contained: stubs the TTS POST + the audio sinks + the db insert so no
backend, ffmpeg, or real voice.db is touched. Asserts:

  - sequential mode (default) is UNCHANGED: it emits NO episode_* events
    and lands exactly ONE row.
  - stream mode emits 1 episode_start + N chunk_ready (cumulative_audio_s
    strictly increasing, render-head semantics) + 1 episode_complete, in
    that order, with the canonical {render} event firing BEFORE
    episode_complete.
  - stream mode lands exactly ONE canonical row (Trap 3).
  - stream mode removes every transient per-chunk wav it created (Trap:
    no leaked transient files), even though chunk_ready announced them.
"""
from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from voice_say import engine


@pytest.fixture(autouse=True)
def _chunking_catalog(monkeypatch):
    """Pin a synthetic single-entry catalog. The shipped tts-local entries set
    longform_chunk_max=12500 (whole-module POSTs), which would collapse the
    multi-chunk fixtures here to one chunk; the synthetic backend keeps the
    global LONGFORM_CHUNK_MAX so the chunking paths stay exercised."""
    fake = engine.Backend(
        id="test-stream", label="TestStream", port=1,
        default_voice="af_alloy", voices=("af_alloy",),
        # True: a no-emotion backend collapses all whitespace (paragraph
        # breaks included) before chunking, which would fold the multi-chunk
        # fixtures into one paragraph.
        supports_speed=False, supports_emotion_tags=True,
        accent="#888888", timeout_s=60.0, output_format="wav",
    )
    monkeypatch.setattr(engine, "BACKENDS", {"test-stream": fake})



# Three paragraphs separated by blank lines so chunk_text yields >1 chunk
# (each paragraph is short, so they pack — pad to force 3 chunks).
_PARA = "x" * 1100  # < LONGFORM_CHUNK_MAX (1200) but two won't fit together
THREE_CHUNK_TEXT = f"{_PARA}\n\n{_PARA}\n\n{_PARA}"


class _Recorder:
    """Captures every event handed to on_episode_event / on_history_appended."""

    def __init__(self) -> None:
        self.episode_events: list[dict] = []
        self.history_events: list[dict] = []

    def on_episode(self, event: dict) -> None:
        self.episode_events.append(event)

    def on_history(self, entry: dict) -> None:
        # Mirror State.record_history's {type:"render"} shape so ordering
        # against episode_complete is observable in one stream.
        self.episode_events.append({"type": "render", "ts": entry.get("ts")})
        self.history_events.append(dict(entry))


@pytest.fixture
def stub_pipeline(monkeypatch, tmp_path):
    """Stub TTS + sinks + db so render_longform runs with no I/O deps.

    Returns a dict of bookkeeping: the list of insert_render calls and the
    set of transient wav paths the engine created (so the test can assert
    they were cleaned up after the run).
    """
    created_wavs: list[Path] = []
    inserts: list[dict] = []

    async def fake_tts_post(text, backend, voice, speed, client,
                            response_format=None, chunk_index=None, mock=False, **_kw):
        # Each chunk -> a tiny distinct wav payload. Length varies with the
        # chunk text length so durations differ chunk-to-chunk.
        return b"RIFFwav" + text.encode("utf-8")[:8]

    real_mkstemp = engine.tempfile.mkstemp

    def tracking_mkstemp(*args, **kwargs):
        fd, name = real_mkstemp(*args, **kwargs)
        p = Path(name)
        if "stream" in p.name or "vs-lf" in p.name:
            created_wavs.append(p)
        return fd, name

    def fake_concat(wav_paths, out_stem):
        # The canonical artefact. Must exist + be non-empty for the engine's
        # read_bytes() to succeed. Independent of the transient chunks.
        out = tmp_path / f"{out_stem}.mp3"
        out.write_bytes(b"ID3concat-mp3")
        return out

    def fake_probe(path, fmt="mp3"):
        # Deterministic, size-derived duration so per-chunk durations differ
        # and the cumulative sum strictly increases.
        try:
            return float(len(Path(path).read_bytes())) / 10.0
        except OSError:
            return 1.0

    def fake_insert(entry):
        inserts.append(dict(entry))

    monkeypatch.setattr(engine, "_tts_post", fake_tts_post)
    monkeypatch.setattr(engine.tempfile, "mkstemp", tracking_mkstemp)
    monkeypatch.setattr(engine._sinks, "concat_wavs_to_mp3", fake_concat)
    monkeypatch.setattr(engine._sinks, "probe_duration_s", fake_probe)
    monkeypatch.setattr(engine._db, "insert_render", fake_insert)

    return {"created_wavs": created_wavs, "inserts": inserts}


def _run(coro):
    return asyncio.run(coro)


def test_sequential_mode_unchanged(stub_pipeline):
    """Default mode emits NO episode_* events and lands exactly one row."""
    rec = _Recorder()
    backend_id = next(iter(engine.BACKENDS))

    entry = _run(engine.render_longform(
        THREE_CHUNK_TEXT,
        backend_id=backend_id,
        on_episode_event=rec.on_episode,  # supplied but must be ignored
    ))

    # No streaming broadcasts in sequential mode.
    assert rec.episode_events == []
    # Exactly one canonical row.
    assert len(stub_pipeline["inserts"]) == 1
    assert entry["ts"] == stub_pipeline["inserts"][0]["ts"]
    # All transient chunk wavs cleaned up.
    leaked = [p for p in stub_pipeline["created_wavs"] if p.exists()]
    assert leaked == [], f"sequential leaked transient wavs: {leaked}"


def test_stream_mode_event_sequence(stub_pipeline):
    """Stream mode: 1 episode_start + N chunk_ready + 1 episode_complete."""
    rec = _Recorder()
    backend_id = next(iter(engine.BACKENDS))

    # Wire the history hook so the canonical {render} event is captured in
    # the SAME stream as the episode_* events (ordering assertion).
    engine.on_history_appended = rec.on_history
    try:
        entry = _run(engine.render_longform(
            THREE_CHUNK_TEXT,
            backend_id=backend_id,
            mode="stream",
            on_episode_event=rec.on_episode,
        ))
    finally:
        engine.on_history_appended = None

    types = [e["type"] for e in rec.episode_events]
    starts = [e for e in rec.episode_events if e["type"] == "episode_start"]
    chunks = [e for e in rec.episode_events if e["type"] == "chunk_ready"]
    completes = [e for e in rec.episode_events if e["type"] == "episode_complete"]

    # Counts.
    assert len(starts) == 1, types
    assert len(completes) == 1, types
    assert len(chunks) >= 2, f"expected multiple chunks, got {types}"
    total = starts[0]["total_chunks"]
    assert len(chunks) == total

    # Ordering: episode_start first, episode_complete last, render BEFORE
    # episode_complete (canonical row must be live before the swap marker).
    assert types[0] == "episode_start"
    assert types[-1] == "episode_complete"
    assert "render" in types
    assert types.index("render") < types.index("episode_complete")
    # All chunk_ready events fall between start and the render/complete tail.
    first_chunk = types.index("chunk_ready")
    last_chunk = len(types) - 1 - types[::-1].index("chunk_ready")
    assert first_chunk > 0
    assert last_chunk < types.index("render")

    # episode_id is a single fresh token shared across the whole episode.
    episode_id = starts[0]["episode_id"]
    assert isinstance(episode_id, str) and episode_id
    assert all(e["episode_id"] == episode_id for e in chunks)
    assert completes[0]["episode_id"] == episode_id

    # chunk_ready: 1-based seq, monotonic; cumulative strictly increasing.
    seqs = [e["seq"] for e in chunks]
    assert seqs == list(range(1, total + 1))
    cumulative = [e["cumulative_audio_s"] for e in chunks]
    assert all(b > a for a, b in zip(cumulative, cumulative[1:])), cumulative
    # Each chunk announces a real, playable transient path.
    for e in chunks:
        assert e["chunk_path"].endswith(".wav")
        assert e["chunk_duration_s"] > 0

    # episode_start predicted total uses the chars/CHARS_PER_SECOND heuristic.
    chars = starts[0]["chars"]
    assert starts[0]["predicted_total_s"] == pytest.approx(
        chars / engine.CHARS_PER_SECOND)

    # episode_complete carries the canonical row's String ts + archive.
    assert completes[0]["ts"] == entry["ts"]
    assert isinstance(completes[0]["ts"], str)
    assert completes[0]["archive_path"] == entry["archive_path"]
    assert completes[0]["duration_s"] == entry["duration_s"]


def test_stream_mode_persists_seam_map(stub_pipeline):
    """The canonical row carries a per-chunk seam_map for the read-along: monotonic
    [audio_s, char_off] points anchored at [0,0] and scaled so the last lands at
    the true probed duration + final rendered_chars."""
    backend_id = next(iter(engine.BACKENDS))
    rec = _Recorder()
    entry = _run(engine.render_longform(
        THREE_CHUNK_TEXT, backend_id=backend_id, mode="stream",
        on_episode_event=rec.on_episode,
    ))
    chunks = [e for e in rec.episode_events if e["type"] == "chunk_ready"]
    sm = entry["seam_map"]
    assert isinstance(sm, list) and len(sm) == len(chunks) + 1, sm  # +1 = (0,0) anchor
    assert sm[0] == [0.0, 0]
    assert all(sm[i][0] <= sm[i + 1][0] and sm[i][1] <= sm[i + 1][1]
               for i in range(len(sm) - 1)), sm
    assert sm[-1][0] == pytest.approx(entry["duration_s"], abs=0.01)
    assert sm[-1][1] == chunks[-1]["rendered_chars"]


# Three short paragraphs (as above) but wrapped in the whitespace chunk_text
# normalizes away: interior blank-line RUNS (3-4 newlines) + leading/trailing
# per-paragraph spaces. So "\n\n".join(chunk_text(...)) is strictly SHORTER than
# this raw input — the exact divergence the read-along drift rode on. (The
# THREE_CHUNK_TEXT fixture has text == join, so it never exercised the bug.)
DRIFT_TEXT = f"  {_PARA}\n\n\n\n{_PARA}  \n\n\n{_PARA}\n"


def test_stream_mode_seam_map_reaches_end_of_stored_text(stub_pipeline):
    """Regression (read-along drift): the final seam offset must land exactly on
    the end of the stored `text` so the last paragraph highlights fully, and
    every offset must be a valid index into it.

    seam_map char offsets live in episode_full_text space — the daemon's chunked,
    whitespace-normalized join. The row must store THAT text, not the raw/validated
    input (whose interior blank-line runs and per-paragraph whitespace the chunker
    collapses): otherwise the client indexes those offsets into a different-length
    string, the highlight drifts early, and the final seam misses len(text). The
    assertion is backend-agnostic (holds whether or not the backend strips emotion
    tags) because it pins the seam space to the stored text directly.
    """
    backend_id = next(iter(engine.BACKENDS))
    rec = _Recorder()
    entry = _run(engine.render_longform(
        DRIFT_TEXT, backend_id=backend_id, mode="stream",
        on_episode_event=rec.on_episode,
    ))

    sm = entry["seam_map"]
    # The final seam reaches the very end of the stored text (the bug left it
    # short of — or overshooting — len(text), so the last paragraph never fully
    # highlighted).
    assert sm and sm[-1][1] == len(entry["text"]), (sm[-1], len(entry["text"]))
    # Every seam offset is a valid index into the stored text — none overshoot.
    assert all(0 <= c <= len(entry["text"]) for _a, c in sm), sm
    # Sanity: this fixture really did carry whitespace the daemon normalized, so
    # the stored seam-space text differs from the raw input (else the guard above
    # would hold trivially and protect nothing).
    assert entry["text"] != DRIFT_TEXT


def test_build_seam_map_unprobeable_duration_keeps_offsets():
    """Guard: an unprobeable concat (duration_s == 0) must NOT collapse every
    seam point to 0 (which would snap the client read-head to the final char).
    The char offsets are preserved and the audio falls back to the unscaled
    per-chunk timeline rather than all-zero."""
    chunk_seams = [(1.0, 10), (2.5, 25)]
    sm = engine._build_seam_map(chunk_seams, prefix_audio_s=0.0,
                                seam_start_chars=0, duration_s=0.0)
    assert sm is not None
    # Char offsets intact (NOT all zero), anchored at 0, monotonic.
    assert [c for _a, c in sm] == [0, 10, 25]
    # Audio falls back to the raw per-chunk times — the bug made these all 0.0.
    assert [a for a, _c in sm] == [0.0, 1.0, 2.5]


def test_chunk_longform_no_fabricated_break_in_split_paragraph():
    """_chunk_longform: an over-long paragraph is sentence-split across chunks, but
    the join separators reconstruct it as ONE paragraph (space between sentence
    pieces) — a real paragraph boundary stays \\n\\n. The old uniform "\\n\\n".join
    fabricated a paragraph break at every sentence-split."""
    para = "Aaa aaa aaa. Bbb bbb bbb. Ccc ccc ccc. Ddd ddd ddd."  # one paragraph, 4 sentences
    text = para + "\n\nShort tail."
    chunks, seps = engine._chunk_longform(text, 30)   # MAX=30 forces the split
    assert len(chunks) == len(seps) >= 3
    assert seps[0] == ""
    assert " " in seps[1:]        # at least one sentence-split (intra-paragraph) join
    assert "\n\n" in seps[1:]     # the real paragraph boundary survives
    # Reconstruction == the normalized transcript: the long paragraph is intact
    # (single spaces), with exactly one \n\n before "Short tail.".
    full = "".join(s + c for c, s in zip(chunks, seps))
    assert full == para + "\n\nShort tail."
    assert para not in ("",) and "\n\n" not in para           # sanity
    # The old uniform join WOULD have inserted extra (fabricated) breaks.
    assert "\n\n".join(chunks).count("\n\n") > full.count("\n\n")
    # chunk_text (the wrapper) returns the same chunk list, unchanged.
    assert engine.chunk_text(text, 30) == chunks


# A single paragraph longer than the default backend's chunk_max (1200), built from
# many sentences — it sentence-splits across chunks. The stored read-along transcript
# must reconstruct as ONE paragraph (no fabricated \n\n), not chunk-joined by \n\n.
_OVERSIZED_PARA = " ".join(f"Sentence number {i} carries a few plain words." for i in range(50))


def test_stream_mode_oversized_paragraph_no_fabricated_breaks(stub_pipeline):
    backend_id = next(iter(engine.BACKENDS))
    rec = _Recorder()
    entry = _run(engine.render_longform(
        _OVERSIZED_PARA, backend_id=backend_id, mode="stream",
        on_episode_event=rec.on_episode,
    ))
    chunks = [e for e in rec.episode_events if e["type"] == "chunk_ready"]
    assert len(chunks) >= 2, "fixture must sentence-split across multiple chunks"
    # The stored transcript is one paragraph — NO fabricated paragraph breaks (the
    # old "\n\n".join would have inserted one between every chunk).
    assert "\n\n" not in entry["text"]
    # Seam invariant still holds: the final seam reaches the end of the stored text.
    assert entry["seam_map"][-1][1] == len(entry["text"])
    assert all(0 <= c <= len(entry["text"]) for _a, c in entry["seam_map"])


def test_stream_mode_one_row_and_cleanup(stub_pipeline):
    """Stream mode lands exactly ONE row and leaves NO transient files."""
    rec = _Recorder()
    backend_id = next(iter(engine.BACKENDS))

    _run(engine.render_longform(
        THREE_CHUNK_TEXT,
        backend_id=backend_id,
        mode="stream",
        on_episode_event=rec.on_episode,
    ))

    # Exactly one canonical row (Trap 3).
    assert len(stub_pipeline["inserts"]) == 1

    # The chunk_ready events DID announce transient paths during the run...
    announced = [e["chunk_path"] for e in rec.episode_events
                 if e["type"] == "chunk_ready"]
    assert announced, "no chunks announced"
    # ...but every transient wav is gone after the run (try/finally cleanup).
    leaked = [p for p in stub_pipeline["created_wavs"] if p.exists()]
    assert leaked == [], f"stream leaked transient wavs: {leaked}"
    for path in announced:
        assert not Path(path).exists(), f"announced chunk not cleaned: {path}"


def test_unknown_mode_rejected(stub_pipeline):
    """An unknown mode raises a RenderError('request', ...)."""
    backend_id = next(iter(engine.BACKENDS))
    with pytest.raises(engine.RenderError) as ei:
        _run(engine.render_longform(
            THREE_CHUNK_TEXT, backend_id=backend_id, mode="bogus"))
    assert ei.value.stage == "request"


def test_stream_mode_emits_episode_error_on_failure(stub_pipeline, monkeypatch):
    """A mid-render failure emits a terminal episode_error (so a streaming
    client stops waiting) IN PLACE OF episode_complete, keeps the chunk that
    did land as a draft row, still re-raises, and cleans up the transient wavs."""
    rec = _Recorder()
    backend_id = next(iter(engine.BACKENDS))

    # Fail on the 2nd chunk so the first chunk_ready (and its transient wav)
    # has already happened — proves cleanup runs on the failure path too.
    calls = {"n": 0}

    async def failing_tts(text, backend, voice, speed, client,
                          response_format=None, chunk_index=None, mock=False, **_kw):
        calls["n"] += 1
        if calls["n"] == 2:
            raise engine.RenderError("tts", "backend exploded mid-stream")
        return b"RIFFwav" + text.encode("utf-8")[:8]

    monkeypatch.setattr(engine, "_tts_post", failing_tts)

    with pytest.raises(engine.RenderError) as ei:
        _run(engine.render_longform(
            THREE_CHUNK_TEXT, backend_id=backend_id, mode="stream",
            on_episode_event=rec.on_episode))
    assert ei.value.stage == "tts"

    types = [e["type"] for e in rec.episode_events]
    starts = [e for e in rec.episode_events if e["type"] == "episode_start"]

    # episode_start fired; a terminal episode_error is the LAST event.
    assert types[0] == "episode_start"
    assert types[-1] == "episode_error"
    # On the failure path there is NO episode_complete.
    assert "episode_complete" not in types

    err = [e for e in rec.episode_events if e["type"] == "episode_error"][0]
    assert err["episode_id"] == starts[0]["episode_id"]
    assert err["stage"] == "tts"
    assert "exploded" in err["message"]

    # The chunk that landed before the failure is kept as ONE resumable draft
    # row (not discarded), and the episode_error names it.
    assert len(stub_pipeline["inserts"]) == 1
    draft = stub_pipeline["inserts"][0]
    assert "draft" in draft["tags"]
    assert draft["resume_char_offset"] == len(_PARA)
    assert err["saved_ts"] == draft["ts"] and err["partial"] is True
    assert ei.value.saved_ts == draft["ts"]
    # Transient wav(s) from the chunk that DID land are cleaned up.
    leaked = [p for p in stub_pipeline["created_wavs"] if p.exists()]
    assert leaked == [], f"failure path leaked transient wavs: {leaked}"
