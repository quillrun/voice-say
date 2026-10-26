"""Tests for streaming-episode control: cancel + save-and-stop (finalize).

These exercise the registry-driven control path added on top of
engine.render_longform(mode="stream"). The TTS is stubbed with a *controllable*
fake (blocking / gated) so the test can deterministically request cancel or
finalize WHILE the render is mid-flight — a concurrent POST /episode/<id>/...
in production, modelled here as a direct registry call from the test task.

Sinks (concat / probe / db insert) are stubbed so no ffmpeg / real voice.db is
touched, mirroring test_render_longform_stream.py.
"""
from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from voice_say import engine


@pytest.fixture(autouse=True)
def _chunking_catalog(monkeypatch):
    """Pin a synthetic single-entry catalog. A catalog entry with a large
    longform_chunk_max would collapse the multi-chunk fixtures here to one
    chunk; the synthetic backend keeps the global LONGFORM_CHUNK_MAX so the
    chunking paths stay exercised."""
    fake = engine.Backend(
        id="test-stream", label="TestStream", port=1,
        default_voice="af_alloy", voices=("af_alloy",),
        supports_speed=False, supports_emotion_tags=False,
        accent="#888888", timeout_s=60.0, output_format="wav",
    )
    monkeypatch.setattr(engine, "BACKENDS", {"test-stream": fake})

from voice_say._episode_registry import EpisodeRegistry


# Three padded paragraphs → chunk_text yields 3 chunks.
_PARA = "x" * 1100
THREE_CHUNK_TEXT = f"{_PARA}\n\n{_PARA}\n\n{_PARA}"
# One paragraph under the chunk cap → chunk_text yields exactly 1 chunk.
ONE_CHUNK_TEXT = _PARA

# A SENTENCE-based multi-chunk fixture that survives engine._validate's
# whitespace-collapse (the padded "x"*N text collapses to a single degenerate
# chunk; sentence text with periods sentence-splits into real chunks). Used by
# the resume tests, where the validated chunk list must be a genuine >1 chunk
# split so an offset can land on a real chunk seam.
_SENT = "The quick brown fox jumps over the lazy dog. "
_SENT_PARA = _SENT * 30   # ~1350 chars > LONGFORM_CHUNK_MAX → sentence-splits
MULTI_SENT_TEXT = f"{_SENT_PARA}\n\n{_SENT_PARA}"


def _validated_chunks(text: str):
    """The chunk list the engine actually renders for `text` — i.e. AFTER
    _validate (which collapses whitespace). resume_longform re-chunks the
    STORED full text via chunk_text directly (no re-validate), so a draft's
    resume_full_text must be the validated/joined episode text. This returns
    (validated_full_text, chunks) so tests can seed a faithful draft row."""
    t, _v, _b, _tg = engine._validate(text, next(iter(engine.BACKENDS)), None, None)
    chunks, seps = engine._chunk_longform(t)
    # Reconstruct with the real join separators (the engine's episode_full_text):
    # a sentence-split paragraph is rejoined by spaces, not fabricated \n\n.
    full = "".join(s + c for c, s in zip(chunks, seps))
    return full, chunks


def _offset_after(chunks, n: int) -> int:
    """Cumulative resume_char_offset after rendering the first `n` chunks. Exact
    for n==1 (the only usage): seps[0] is '' so the offset is len(chunks[0]),
    matching the engine's `len(seps[idx]) + len(chunk)` accumulation."""
    acc = 0
    for i, c in enumerate(chunks[:n]):
        acc += len(c) + (2 if i else 0)
    return acc


@pytest.fixture
def stub_sinks(monkeypatch, tmp_path):
    """Stub the audio sinks + db so _finalize_longform runs with no I/O deps.

    Returns {'inserts': [...]} — the canonical rows that would have been
    written (empty after a cancel, length 1 after a finalize)."""
    inserts: list[dict] = []

    def fake_concat(wav_paths, out_stem):
        out = tmp_path / f"{out_stem}.mp3"
        out.write_bytes(b"ID3concat-mp3")
        return out

    def fake_probe(path, fmt="mp3"):
        try:
            return float(len(Path(path).read_bytes())) / 10.0
        except OSError:
            return 1.0

    def fake_insert(entry):
        inserts.append(dict(entry))

    monkeypatch.setattr(engine._sinks, "concat_wavs_to_mp3", fake_concat)
    monkeypatch.setattr(engine._sinks, "probe_duration_s", fake_probe)
    monkeypatch.setattr(engine._db, "insert_render", fake_insert)
    return {"inserts": inserts}


def test_registry_unknown_id_is_false():
    reg = EpisodeRegistry()
    assert reg.request_cancel("nope") is False
    assert reg.request_finalize("nope") is False
    ctl = reg.register("abc")
    assert reg.request_cancel("abc") is True
    assert ctl.cancelled is True
    assert reg.request_finalize("abc") is True
    assert ctl.finalize_requested is True
    reg.unregister("abc")
    assert reg.get("abc") is None


def test_begin_resume_is_exclusive_per_draft():
    """Only one resume per draft ts may be in flight: a second begin_resume of
    the same ts is rejected (the route 409s it) until end_resume releases it.
    Guards POST /episode/resume against a double-fired request rendering the
    remainder twice and writing duplicate superset rows."""
    reg = EpisodeRegistry()
    assert reg.begin_resume("ts-1") is True
    assert reg.begin_resume("ts-1") is False     # second claim on same draft blocked
    assert reg.begin_resume("ts-2") is True       # a different draft is independent
    reg.end_resume("ts-1")
    assert reg.begin_resume("ts-1") is True        # released → claimable again
    reg.end_resume("ts-1")
    reg.end_resume("ts-2")
    reg.end_resume("never-claimed")                # idempotent: no error


async def test_cancel_aborts_with_no_row(stub_sinks, monkeypatch):
    """A cancel mid-render raises RenderCancelled, emits a terminal
    episode_cancelled, writes NO row, and unregisters the episode."""
    events: list[dict] = []
    started = asyncio.Event()
    captured: dict[str, str] = {}

    def emit(ev):
        events.append(ev)
        if ev["type"] == "episode_start":
            captured["id"] = ev["episode_id"]
            started.set()

    async def blocking_tts(text, backend, voice, speed, client,
                           response_format=None, chunk_index=None, mock=False, **_kw):
        # Never returns on its own — only a task .cancel() unblocks it.
        await asyncio.Event().wait()
        return b"unreachable"

    monkeypatch.setattr(engine, "_tts_post", blocking_tts)

    reg = EpisodeRegistry()
    backend_id = next(iter(engine.BACKENDS))
    task = asyncio.ensure_future(engine.render_longform(
        THREE_CHUNK_TEXT, backend_id=backend_id, mode="stream",
        on_episode_event=emit, episode_registry=reg))

    await asyncio.wait_for(started.wait(), timeout=2)
    await asyncio.sleep(0)  # let the loop reach `await chunk_task`
    assert reg.request_cancel(captured["id"]) is True

    with pytest.raises(engine.RenderCancelled):
        await asyncio.wait_for(task, timeout=2)

    types = [e["type"] for e in events]
    assert types[0] == "episode_start"
    assert types[-1] == "episode_cancelled"
    assert "episode_complete" not in types
    # No canonical row was written.
    assert stub_sinks["inserts"] == []
    # Registry cleaned up in the finally.
    assert reg.get(captured["id"]) is None


async def test_finalize_keeps_partial_as_draft(stub_sinks, monkeypatch):
    """A finalize mid-render keeps the rendered-so-far chunk(s): ONE row,
    tagged 'draft', with a normal episode_complete carrying save_and_stop=True.

    Determinism: chunk 1 blocks on a gate; the test requests finalize WHILE
    chunk 1 is in flight (before it completes), so the very next loop-top
    (idx=1) breaks. chunk 2 must never render."""
    events: list[dict] = []
    started = asyncio.Event()
    blocked = asyncio.Event()
    captured: dict[str, str] = {}
    gate1 = asyncio.Event()
    calls = {"n": 0}

    def emit(ev):
        events.append(ev)
        if ev["type"] == "episode_start":
            captured["id"] = ev["episode_id"]
            started.set()

    async def gated_tts(text, backend, voice, speed, client,
                        response_format=None, chunk_index=None, mock=False, **_kw):
        calls["n"] += 1
        if calls["n"] == 1:
            blocked.set()
            await gate1.wait()            # hold chunk 1 in flight
            return b"RIFFwav-chunk1"
        await asyncio.Event().wait()      # chunk 2+ must NEVER run
        return b"unreachable"

    monkeypatch.setattr(engine, "_tts_post", gated_tts)

    reg = EpisodeRegistry()
    backend_id = next(iter(engine.BACKENDS))
    box: dict[str, dict] = {}

    async def run():
        box["entry"] = await engine.render_longform(
            THREE_CHUNK_TEXT, backend_id=backend_id, mode="stream",
            on_episode_event=emit, episode_registry=reg)

    task = asyncio.ensure_future(run())

    await asyncio.wait_for(blocked.wait(), timeout=2)    # chunk 1 in flight
    assert reg.request_finalize(captured["id"]) is True  # finalize before it lands
    gate1.set()                                          # let chunk 1 finish

    await asyncio.wait_for(task, timeout=3)
    entry = box["entry"]

    types = [e["type"] for e in events]
    assert types[-1] == "episode_complete"
    assert events[-1].get("save_and_stop") is True
    # Exactly ONE canonical row, tagged "draft"; only chunk 1 rendered.
    assert len(stub_sinks["inserts"]) == 1
    assert "draft" in stub_sinks["inserts"][0].get("tags", [])
    assert "draft" in (entry.get("tags") or [])
    assert calls["n"] == 1  # finalize stopped the render before chunk 2
    # Registry cleaned up.
    assert reg.get(captured["id"]) is None


async def test_finalize_single_chunk_keeps_as_draft(stub_sinks, monkeypatch):
    """Regression (save-to-drafts bug): a finalize during a SINGLE-chunk render
    must still keep the audio as a draft. The top-of-loop finalize gate only
    catches a finalize requested before a NEXT chunk (and only with a prior
    chunk already rendered), so a one-chunk render — or a finalize during the
    LAST chunk — used to finish normally and never get tagged 'draft'. The
    post-chunk re-check fixes it; this test fails without that re-check."""
    events: list[dict] = []
    started = asyncio.Event()
    blocked = asyncio.Event()
    captured: dict[str, str] = {}
    gate1 = asyncio.Event()
    calls = {"n": 0}

    def emit(ev):
        events.append(ev)
        if ev["type"] == "episode_start":
            captured["id"] = ev["episode_id"]
            started.set()

    async def gated_tts(text, backend, voice, speed, client,
                        response_format=None, chunk_index=None, mock=False, **_kw):
        calls["n"] += 1
        blocked.set()
        await gate1.wait()            # hold the only chunk in flight
        return b"RIFFwav-chunk1"

    monkeypatch.setattr(engine, "_tts_post", gated_tts)

    reg = EpisodeRegistry()
    backend_id = next(iter(engine.BACKENDS))
    box: dict[str, dict] = {}

    async def run():
        box["entry"] = await engine.render_longform(
            ONE_CHUNK_TEXT, backend_id=backend_id, mode="stream",
            on_episode_event=emit, episode_registry=reg)

    task = asyncio.ensure_future(run())

    await asyncio.wait_for(blocked.wait(), timeout=2)    # the only chunk in flight
    assert reg.request_finalize(captured["id"]) is True  # finalize before it lands
    gate1.set()                                          # let the chunk finish

    await asyncio.wait_for(task, timeout=3)
    entry = box["entry"]

    types = [e["type"] for e in events]
    assert types[-1] == "episode_complete"
    assert events[-1].get("save_and_stop") is True
    # ONE canonical row, tagged "draft" — the single chunk kept as a draft.
    assert len(stub_sinks["inserts"]) == 1
    assert "draft" in stub_sinks["inserts"][0].get("tags", [])
    assert "draft" in (entry.get("tags") or [])
    assert calls["n"] == 1
    assert reg.get(captured["id"]) is None


async def test_finalize_persists_resume_boundary_single_chunk(stub_sinks, monkeypatch):
    """A single-chunk draft persists resume_full_text == the joined full text
    and resume_char_offset == len(chunk1) (the clean chunk-boundary offset).

    Without the persisted boundary a later POST /episode/resume cannot know how
    far the draft got. Reuses the gated_tts pattern from the single-chunk test."""
    started = asyncio.Event()
    blocked = asyncio.Event()
    captured: dict[str, str] = {}
    gate1 = asyncio.Event()
    calls = {"n": 0}

    def emit(ev):
        if ev["type"] == "episode_start":
            captured["id"] = ev["episode_id"]
            captured["full_text"] = ev["text"]
            started.set()

    async def gated_tts(text, backend, voice, speed, client, response_format=None, chunk_index=None, mock=False, **_kw):
        calls["n"] += 1
        blocked.set()
        await gate1.wait()
        return b"RIFFwav-chunk1"

    monkeypatch.setattr(engine, "_tts_post", gated_tts)

    reg = EpisodeRegistry()
    backend_id = next(iter(engine.BACKENDS))

    async def run():
        return await engine.render_longform(
            ONE_CHUNK_TEXT, backend_id=backend_id, mode="stream",
            on_episode_event=emit, episode_registry=reg)

    task = asyncio.ensure_future(run())
    await asyncio.wait_for(blocked.wait(), timeout=2)
    assert reg.request_finalize(captured["id"]) is True
    gate1.set()
    await asyncio.wait_for(task, timeout=3)

    row = stub_sinks["inserts"][0]
    # episode_full_text for a single chunk is just that chunk (no join seam).
    assert row.get("resume_full_text") == ONE_CHUNK_TEXT
    assert row.get("resume_char_offset") == len(ONE_CHUNK_TEXT)
    # The persisted full text is exactly what the reader was shown.
    assert row["resume_full_text"] == captured["full_text"]


async def test_finalize_persists_resume_boundary_multi_chunk(stub_sinks, monkeypatch):
    """Finalize a real multi-chunk render WHILE chunk 1 is in flight persists
    resume_char_offset == len(chunk1) (the first clean seam) and the full
    joined (validated) text. Mirrors test_finalize_keeps_partial_as_draft's
    gate idiom: chunk 1 blocks; finalize is requested before it lands, so the
    idx=1 top-of-loop gate breaks and chunk 2 never renders.

    Uses the SENTENCE-based fixture (the padded "x" text collapses to one
    degenerate chunk under _validate; sentence text splits into real chunks)."""
    full_validated, chunks = _validated_chunks(MULTI_SENT_TEXT)
    assert len(chunks) >= 2   # guard: the fixture really is multi-chunk

    blocked = asyncio.Event()
    captured: dict[str, str] = {}
    gate1 = asyncio.Event()
    calls = {"n": 0}

    def emit(ev):
        if ev["type"] == "episode_start":
            captured["id"] = ev["episode_id"]
            captured["full_text"] = ev["text"]

    async def gated_tts(text, backend, voice, speed, client, response_format=None, chunk_index=None, mock=False, **_kw):
        calls["n"] += 1
        if calls["n"] == 1:
            blocked.set()
            await gate1.wait()        # hold chunk 1 in flight
            return b"RIFFwav-chunk1"
        await asyncio.Event().wait()  # chunk 2+ must NEVER run
        return b"unreachable"

    monkeypatch.setattr(engine, "_tts_post", gated_tts)

    reg = EpisodeRegistry()
    backend_id = next(iter(engine.BACKENDS))

    async def run():
        return await engine.render_longform(
            MULTI_SENT_TEXT, backend_id=backend_id, mode="stream",
            on_episode_event=emit, episode_registry=reg)

    task = asyncio.ensure_future(run())
    await asyncio.wait_for(blocked.wait(), timeout=2)    # chunk 1 in flight
    assert reg.request_finalize(captured["id"]) is True  # finalize before it lands
    gate1.set()                                          # let chunk 1 finish
    await asyncio.wait_for(task, timeout=3)

    row = stub_sinks["inserts"][0]
    # Only chunk 1 rendered → offset is the end of chunk 1 (no preceding seam).
    assert row.get("resume_char_offset") == len(chunks[0])
    assert row.get("resume_full_text") == full_validated
    assert row["resume_full_text"] == captured["full_text"]
    assert "draft" in row.get("tags", [])
    assert calls["n"] == 1


def _seed_draft_row(monkeypatch, *, full_text, offset, backend_id,
                    archive_path, tags=("draft",)):
    """Monkeypatch engine._db.get_render to return a synthetic draft row and
    engine.overlays.write to a no-op (supersede), so resume_longform can run
    without a real db. Returns a list capturing supersede calls."""
    superseded: list[dict] = []
    row = {
        "ts": "2026-06-01T00:00:00.000000Z",
        "kind": "render",
        "backend": backend_id,
        "voice": "af_alloy",
        "speed": 1.0,
        "format": "mp3",
        "chars": len(full_text),
        "words": 1,
        "duration_s": 5.0,
        "bytes": 1000,
        "archive_name": archive_path.name,
        "archive_path": str(archive_path),
        "text": full_text,
        "tags": list(tags),
        "resume_full_text": full_text,
        "resume_char_offset": offset,
    }
    monkeypatch.setattr(engine._db, "get_render", lambda ts: dict(row))

    import voice_say.overlays as overlays
    monkeypatch.setattr(
        overlays, "write",
        lambda ts, **kw: superseded.append({"ts": ts, **kw}) or {"ts": ts, **kw})
    return row, superseded


async def test_resume_round_trip_completes_one_row(stub_sinks, monkeypatch, tmp_path):
    """Seed a finalized-early draft (rendered chunk 1 of N), resume, and assert:
    exactly ONE new insert; it is NOT tagged draft (ran to completion); the
    concat received len(remaining)+1 WAVs (the decoded draft + the remainder);
    the draft was superseded.

    `resume_full_text` is the VALIDATED joined text (resume_longform re-chunks it
    directly via chunk_text, no re-validate), so we seed/compute from that."""
    full, chunks = _validated_chunks(MULTI_SENT_TEXT)
    assert len(chunks) >= 2
    offset = _offset_after(chunks, 1)       # rendered chunk 1 only
    backend_id = next(iter(engine.BACKENDS))

    draft_mp3 = tmp_path / "draft.mp3"
    draft_mp3.write_bytes(b"ID3draft-mp3")
    row, superseded = _seed_draft_row(
        monkeypatch, full_text=full, offset=offset,
        backend_id=backend_id, archive_path=draft_mp3)

    # Stub the mp3→wav decode to a real temp wav so the prepend path is exercised
    # and the file exists for the concat-count assertion + finally cleanup.
    lead_wav = tmp_path / "lead.wav"
    lead_wav.write_bytes(b"RIFFlead-wav")
    monkeypatch.setattr(engine._sinks, "decode_mp3_to_wav", lambda src: lead_wav)

    # Capture the WAV count handed to concat.
    concat_calls: dict[str, int] = {}
    orig_concat = stub_sinks  # noqa: F841 — stub_sinks already patched concat

    def counting_concat(wav_paths, out_stem):
        concat_calls["n"] = len(wav_paths)
        out = tmp_path / f"{out_stem}.mp3"
        out.write_bytes(b"ID3resumed-mp3")
        return out

    monkeypatch.setattr(engine._sinks, "concat_wavs_to_mp3", counting_concat)

    async def fast_tts(text, backend, voice, speed, client, response_format=None, chunk_index=None, mock=False, **_kw):
        return b"RIFFwav-resumed-chunk"

    monkeypatch.setattr(engine, "_tts_post", fast_tts)

    events: list[dict] = []
    entry = await engine.resume_longform(
        row["ts"], on_episode_event=events.append, episode_registry=EpisodeRegistry())

    # Exactly ONE new row, run to completion → not a draft.
    assert len(stub_sinks["inserts"]) == 1
    assert "draft" not in (entry.get("tags") or [])
    # Remaining chunks = all - skipped(1) = 2; concat got those + the lead wav.
    remaining = len(chunks) - 1
    assert concat_calls["n"] == remaining + 1
    # episode_complete is a NORMAL completion (not save_and_stop).
    assert events[-1]["type"] == "episode_complete"
    assert events[-1].get("save_and_stop") is False
    # The draft was superseded (soft-deleted) exactly once.
    assert len(superseded) == 1
    assert superseded[0]["ts"] == row["ts"]
    assert superseded[0].get("deleted") is True


async def test_resume_non_draft_row_raises(stub_sinks, monkeypatch, tmp_path):
    """A row with NULL resume columns (a normal render) is not resumable."""
    backend_id = next(iter(engine.BACKENDS))
    row = {
        "ts": "2026-06-01T00:00:00.000000Z", "backend": backend_id,
        "voice": "af_alloy", "speed": 1.0, "kind": "render", "tags": [],
        "archive_path": str(tmp_path / "x.mp3"), "archive_name": "x.mp3",
        "text": "hi", "resume_full_text": None, "resume_char_offset": None,
    }
    monkeypatch.setattr(engine._db, "get_render", lambda ts: dict(row))
    with pytest.raises(engine.RenderError) as ei:
        await engine.resume_longform(row["ts"], episode_registry=EpisodeRegistry())
    assert ei.value.stage == "request"
    assert stub_sinks["inserts"] == []


async def test_resume_already_complete_raises(stub_sinks, monkeypatch, tmp_path):
    """offset >= len(full) means no chunk remains → 'already complete'."""
    full = ONE_CHUNK_TEXT
    backend_id = next(iter(engine.BACKENDS))
    draft_mp3 = tmp_path / "draft.mp3"
    draft_mp3.write_bytes(b"ID3draft-mp3")
    row, _ = _seed_draft_row(
        monkeypatch, full_text=full, offset=len(full),  # whole text already rendered
        backend_id=backend_id, archive_path=draft_mp3)
    monkeypatch.setattr(engine._sinks, "decode_mp3_to_wav",
                        lambda src: tmp_path / "never.wav")
    with pytest.raises(engine.RenderError) as ei:
        await engine.resume_longform(row["ts"], episode_registry=EpisodeRegistry())
    assert "already complete" in ei.value.message
    assert stub_sinks["inserts"] == []


async def test_resume_missing_audio_raises(stub_sinks, monkeypatch, tmp_path):
    """The draft mp3 must exist on disk to become the leading concat segment."""
    full = THREE_CHUNK_TEXT
    offset = len(engine.chunk_text(full)[0])
    backend_id = next(iter(engine.BACKENDS))
    row, _ = _seed_draft_row(
        monkeypatch, full_text=full, offset=offset, backend_id=backend_id,
        archive_path=tmp_path / "gone.mp3")   # does NOT exist
    with pytest.raises(engine.RenderError) as ei:
        await engine.resume_longform(row["ts"], episode_registry=EpisodeRegistry())
    assert ei.value.stage == "archive"
    assert stub_sinks["inserts"] == []


async def test_resume_then_finalize_again_repersists_offset(stub_sinks, monkeypatch, tmp_path):
    """A resumed render can be stopped-and-kept AGAIN: it carries a fresh
    resume boundary (offset advanced past the draft) and re-acquires 'draft'.
    Recursive drafts work because resume goes through the same finalize tail.

    Needs a >=3-chunk remainder so we can render one remaining chunk then
    finalize before the next. resume_longform re-chunks the stored full text
    directly, so seed it with the validated joined text."""
    full, chunks = _validated_chunks(MULTI_SENT_TEXT)
    assert len(chunks) >= 3
    offset = _offset_after(chunks, 1)             # draft rendered chunk 1
    backend_id = next(iter(engine.BACKENDS))

    draft_mp3 = tmp_path / "draft.mp3"
    draft_mp3.write_bytes(b"ID3draft-mp3")
    row, _ = _seed_draft_row(
        monkeypatch, full_text=full, offset=offset,
        backend_id=backend_id, archive_path=draft_mp3)
    lead_wav = tmp_path / "lead.wav"
    lead_wav.write_bytes(b"RIFFlead")
    monkeypatch.setattr(engine._sinks, "decode_mp3_to_wav", lambda src: lead_wav)

    captured: dict[str, str] = {}
    blocked = asyncio.Event()
    gate2 = asyncio.Event()
    calls = {"n": 0}

    def emit(ev):
        if ev["type"] == "episode_start":
            captured["id"] = ev["episode_id"]

    async def gated_tts(text, backend, voice, speed, client, response_format=None, chunk_index=None, mock=False, **_kw):
        calls["n"] += 1
        if calls["n"] == 1:                       # first remaining chunk (chunk 2)
            blocked.set()
            await gate2.wait()                    # hold it in flight so we can
            return b"RIFFwav-resumed-1"           #   finalize before it lands
        await asyncio.Event().wait()              # the next must NEVER run
        return b"unreachable"

    monkeypatch.setattr(engine, "_tts_post", gated_tts)

    reg = EpisodeRegistry()

    async def run():
        return await engine.resume_longform(
            row["ts"], on_episode_event=emit, episode_registry=reg)

    task = asyncio.ensure_future(run())
    await asyncio.wait_for(blocked.wait(), timeout=2)    # first remaining in flight
    assert reg.request_finalize(captured["id"]) is True  # finalize before it lands
    gate2.set()                                          # let it finish; re-check breaks
    entry = await asyncio.wait_for(task, timeout=3)

    # Stopped again → tagged draft again, and a fresh offset past the original.
    assert "draft" in (entry.get("tags") or [])
    assert calls["n"] == 1                        # only the first remaining ran
    row2 = stub_sinks["inserts"][-1]
    assert row2.get("resume_char_offset") is not None
    assert row2["resume_char_offset"] > offset
    assert row2.get("resume_full_text") == full


def test_request_force_finalize_sets_flags_not_cancel():
    """request_force_finalize sets finalize AND force (so the loop keeps what it
    has) but NOT cancel (which would discard everything). Unknown id → False."""
    reg = EpisodeRegistry()
    assert reg.request_force_finalize("nope") is False
    ctl = reg.register("abc")
    assert ctl.force_finalize_requested is False
    assert reg.request_force_finalize("abc") is True
    assert ctl.finalize_requested is True        # force implies save-and-stop
    assert ctl.force_finalize_requested is True
    assert ctl.cancelled is False                # force is NOT a cancel


async def test_request_force_finalize_cancels_in_flight_task():
    """The in-flight chunk task is cancelled so the render unblocks NOW instead
    of after a multi-second synth returns — the whole point of 'force'."""
    reg = EpisodeRegistry()
    ctl = reg.register("abc")

    async def long_synth():
        await asyncio.Event().wait()

    task = asyncio.ensure_future(long_synth())
    ctl.current_chunk_task = task
    await asyncio.sleep(0)                        # let the task start awaiting
    assert reg.request_force_finalize("abc") is True
    await asyncio.sleep(0)                        # let the cancellation propagate
    assert task.cancelled()


async def test_force_finalize_drops_in_flight_keeps_completed(stub_sinks, monkeypatch):
    """Force save-and-stop WHILE chunk 2 is in flight (chunk 1 already done):
    keep chunk 1 as a 'draft' row, DROP chunk 2 (its synth is cancelled, not
    awaited), chunk 3 never starts. Unlike plain finalize this does not wait for
    the in-flight chunk to finish.

    Sentence fixture (the padded 'x' text collapses to one chunk under
    _validate; sentence text splits into real chunks)."""
    full_validated, chunks = _validated_chunks(MULTI_SENT_TEXT)
    assert len(chunks) >= 2

    events: list[dict] = []
    captured: dict[str, str] = {}
    blocked2 = asyncio.Event()
    calls = {"n": 0}

    def emit(ev):
        events.append(ev)
        if ev["type"] == "episode_start":
            captured["id"] = ev["episode_id"]

    async def gated_tts(text, backend, voice, speed, client, response_format=None, chunk_index=None, mock=False, **_kw):
        calls["n"] += 1
        if calls["n"] == 1:
            return b"RIFFwav-chunk1"          # chunk 1 lands immediately
        blocked2.set()                         # chunk 2 in flight…
        await asyncio.Event().wait()           # …until request_force_finalize cancels it
        return b"unreachable"

    monkeypatch.setattr(engine, "_tts_post", gated_tts)

    reg = EpisodeRegistry()
    backend_id = next(iter(engine.BACKENDS))
    box: dict[str, dict] = {}

    async def run():
        box["entry"] = await engine.render_longform(
            MULTI_SENT_TEXT, backend_id=backend_id, mode="stream",
            on_episode_event=emit, episode_registry=reg)

    task = asyncio.ensure_future(run())
    await asyncio.wait_for(blocked2.wait(), timeout=2)   # chunk 1 done, chunk 2 in flight
    assert reg.request_force_finalize(captured["id"]) is True
    await asyncio.wait_for(task, timeout=3)
    entry = box["entry"]

    types = [e["type"] for e in events]
    assert types[-1] == "episode_complete"
    assert events[-1].get("save_and_stop") is True
    # Exactly ONE row, tagged draft; the in-flight chunk 2 was dropped.
    assert len(stub_sinks["inserts"]) == 1
    assert "draft" in stub_sinks["inserts"][0].get("tags", [])
    assert "draft" in (entry.get("tags") or [])
    assert calls["n"] == 2                       # chunk 2 STARTED then cancelled; chunk 3 never ran
    # Only chunk 1 kept → the resume boundary is the end of chunk 1, so a later
    # resume re-renders the dropped chunk 2 onward.
    assert stub_sinks["inserts"][0].get("resume_char_offset") == len(chunks[0])
    assert reg.get(captured["id"]) is None


async def test_force_finalize_with_nothing_done_cancels(stub_sinks, monkeypatch):
    """Force save-and-stop WHILE the first chunk is still in flight (nothing
    completed) has nothing to keep → it falls back to a cancel: NO row, a
    terminal episode_cancelled. (The UI only offers force-stop once a chunk is
    done, so this is the defensive daemon path.)"""
    events: list[dict] = []
    captured: dict[str, str] = {}
    blocked = asyncio.Event()

    def emit(ev):
        events.append(ev)
        if ev["type"] == "episode_start":
            captured["id"] = ev["episode_id"]

    async def blocking_tts(text, backend, voice, speed, client, response_format=None, chunk_index=None, mock=False, **_kw):
        blocked.set()
        await asyncio.Event().wait()
        return b"unreachable"

    monkeypatch.setattr(engine, "_tts_post", blocking_tts)

    reg = EpisodeRegistry()
    backend_id = next(iter(engine.BACKENDS))
    task = asyncio.ensure_future(engine.render_longform(
        ONE_CHUNK_TEXT, backend_id=backend_id, mode="stream",
        on_episode_event=emit, episode_registry=reg))

    await asyncio.wait_for(blocked.wait(), timeout=2)
    assert reg.request_force_finalize(captured["id"]) is True

    with pytest.raises(engine.RenderCancelled):
        await asyncio.wait_for(task, timeout=3)

    types = [e["type"] for e in events]
    assert types[-1] == "episode_cancelled"
    assert "episode_complete" not in types
    assert stub_sinks["inserts"] == []           # nothing to keep → no row
    assert reg.get(captured["id"]) is None


async def test_resume_force_finalize_before_a_new_chunk_cancels(stub_sinks, monkeypatch, tmp_path):
    """On a resume the draft's lead audio is already queued for the concat, but
    it is not new work: a force-stop before the first remaining chunk lands
    keeps nothing new, so it cancels (the draft row stays as it was) instead of
    saving a copy of the draft over it."""
    full, chunks = _validated_chunks(MULTI_SENT_TEXT)
    offset = _offset_after(chunks, 1)
    backend_id = next(iter(engine.BACKENDS))
    draft_mp3 = tmp_path / "draft.mp3"
    draft_mp3.write_bytes(b"ID3draft-mp3")
    row, _ = _seed_draft_row(
        monkeypatch, full_text=full, offset=offset,
        backend_id=backend_id, archive_path=draft_mp3)
    lead_wav = tmp_path / "lead.wav"
    lead_wav.write_bytes(b"RIFFlead")
    monkeypatch.setattr(engine._sinks, "decode_mp3_to_wav", lambda src: lead_wav)

    captured: dict[str, str] = {}
    blocked = asyncio.Event()

    def emit(ev):
        if ev["type"] == "episode_start":
            captured["id"] = ev["episode_id"]

    async def blocking_tts(text, backend, voice, speed, client, response_format=None, chunk_index=None, mock=False, **_kw):
        blocked.set()
        await asyncio.Event().wait()
        return b"unreachable"

    monkeypatch.setattr(engine, "_tts_post", blocking_tts)
    reg = EpisodeRegistry()
    task = asyncio.ensure_future(engine.resume_longform(
        row["ts"], on_episode_event=emit, episode_registry=reg))
    await asyncio.wait_for(blocked.wait(), timeout=2)
    assert reg.request_force_finalize(captured["id"]) is True
    with pytest.raises(engine.RenderCancelled):
        await asyncio.wait_for(task, timeout=3)
    assert stub_sinks["inserts"] == []


async def test_resume_emits_prefix_audio_s(stub_sinks, monkeypatch, tmp_path):
    """A resume's episode_start carries prefix_audio_s = the decoded draft's
    audio duration. The client seeds its render-head + playhead into full-text
    space with it, so the live progress bar starts at the prefix fraction
    instead of under-filling from 0."""
    full, chunks = _validated_chunks(MULTI_SENT_TEXT)
    offset = _offset_after(chunks, 1)
    backend_id = next(iter(engine.BACKENDS))

    draft_mp3 = tmp_path / "draft.mp3"
    draft_mp3.write_bytes(b"ID3draft-mp3")
    row, _ = _seed_draft_row(monkeypatch, full_text=full, offset=offset,
                             backend_id=backend_id, archive_path=draft_mp3)

    lead_wav = tmp_path / "lead.wav"
    lead_wav.write_bytes(b"RIFFlead-wav-padding-to-a-known-length")  # stub probe = bytes/10
    # The stub_sinks fake_probe returns len(bytes)/10.0 — the SAME path the
    # prefix probe takes, so we can predict the emitted offset exactly. Capture
    # it BEFORE the resume: the engine's finally unlinks the prepend wav.
    expected = float(len(lead_wav.read_bytes())) / 10.0
    monkeypatch.setattr(engine._sinks, "decode_mp3_to_wav", lambda src: lead_wav)

    async def fast_tts(text, backend, voice, speed, client, response_format=None, chunk_index=None, mock=False, **_kw):
        return b"RIFFwav-resumed-chunk"

    monkeypatch.setattr(engine, "_tts_post", fast_tts)

    starts: list[dict] = []

    def emit(ev):
        if ev["type"] == "episode_start":
            starts.append(ev)

    await engine.resume_longform(
        row["ts"], on_episode_event=emit, episode_registry=EpisodeRegistry())

    assert len(starts) == 1
    assert starts[0]["prefix_audio_s"] == pytest.approx(expected)
    assert starts[0]["prefix_audio_s"] > 0


async def test_fresh_stream_emits_zero_prefix_audio_s(stub_sinks, monkeypatch):
    """A fresh (non-resume) stream render emits prefix_audio_s == 0.0 — no draft
    prefix, so the client's render-head starts at 0 exactly as before. Guards
    the byte-for-byte no-regression contract for the common path."""
    starts: list[dict] = []

    def emit(ev):
        if ev["type"] == "episode_start":
            starts.append(ev)

    async def fast_tts(text, backend, voice, speed, client, response_format=None, chunk_index=None, mock=False, **_kw):
        return b"RIFFwav"

    monkeypatch.setattr(engine, "_tts_post", fast_tts)

    await engine.render_longform(
        ONE_CHUNK_TEXT, backend_id=next(iter(engine.BACKENDS)), mode="stream",
        on_episode_event=emit, episode_registry=EpisodeRegistry())

    assert len(starts) == 1
    assert starts[0]["prefix_audio_s"] == 0.0
