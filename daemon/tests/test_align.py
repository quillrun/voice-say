"""Read-along alignment (align.py + the engine wiring).

The model never runs here: `align.points` is tested on hand-made word lists,
and the engine paths get a fake aligner in place of `align.align`.
"""
from __future__ import annotations

import asyncio
from pathlib import Path

import pytest

from voice_say import _db, align, config, engine

TEXT = "The fishing boats rocked against their ropes."


def _offset(text: str, word: str) -> int:
    return text.index(word)


def test_points_puts_each_heard_word_at_its_start():
    words = [[0.0, 0.2, " The"], [0.2, 0.6, " fishing"], [0.6, 0.9, " boats"],
             [0.9, 1.3, " rocked"], [1.3, 1.8, " against"], [1.8, 2.0, " their"],
             [2.0, 2.4, " ropes."]]
    pts = align.points(TEXT, words)
    assert pts[0] == [0.0, 0]
    assert [1.3, _offset(TEXT, "against")] in pts
    assert len(pts) == 7


def test_points_shift_into_the_episode_timeline():
    words = [[0.0, 0.2, "The"], [0.2, 0.6, "fishing"], [0.6, 0.9, "boats"],
             [0.9, 1.3, "rocked"]]
    pts = align.points(TEXT, words, base_s=100.0, base_char=5000)
    assert pts[0] == [100.0, 5000]
    assert pts[1] == [100.2, 5000 + _offset(TEXT, "fishing")]


def test_points_skip_misheard_words_and_backward_timestamps():
    # "rocked" misheard as "rocket"; "against" carries a timestamp that steps back.
    words = [[0.0, 0.2, "The"], [0.2, 0.6, "fishing"], [0.6, 0.9, "boats"],
             [0.9, 1.3, "rocket"], [0.5, 1.8, "against"], [1.8, 2.0, "their"],
             [2.0, 2.4, "ropes"]]
    pts = align.points(TEXT, words)
    offsets = [c for _t, c in pts]
    assert _offset(TEXT, "rocked") not in offsets
    assert _offset(TEXT, "against") not in offsets
    assert all(a[0] < b[0] and a[1] < b[1] for a, b in zip(pts, pts[1:]))


def test_points_none_when_the_audio_is_not_this_text():
    words = [[0.0, 0.5, "completely"], [0.5, 1.0, "different"], [1.0, 1.5, "words"]]
    assert align.points(TEXT, words) is None


def test_available_follows_the_config(monkeypatch):
    monkeypatch.setattr(config, "ALIGN_ENABLED", False)
    assert align.available() is False


# ----------------------------------------------------------------- engine --

@pytest.fixture
def backend(monkeypatch):
    fake = engine.Backend(
        id="test-align", label="TestAlign", port=1,
        default_voice="af_alloy", voices=("af_alloy",),
        supports_speed=False, supports_emotion_tags=True,
        accent="#888888", timeout_s=60.0, output_format="wav",
    )
    monkeypatch.setattr(engine, "BACKENDS", {"test-align": fake})
    return fake


class _FakeAligner:
    """Points at every word start, one word per 0.4 s from the chunk start."""

    def __init__(self, fail: bool = False) -> None:
        self.calls: list[tuple[str, float, int]] = []
        self.fail = fail

    async def __call__(self, wav: Path, text: str, *, base_s: float = 0.0,
                       base_char: int = 0):
        self.calls.append((text, base_s, base_char))
        if self.fail:
            return None
        words = [[i * 0.4, i * 0.4 + 0.3, w] for i, w in enumerate(text.split())]
        return align.points(text, words, base_s=base_s, base_char=base_char)


def test_single_render_is_aligned_after_it_lands(isolated_paths, backend, monkeypatch):
    fake = _FakeAligner()
    announced: list[dict] = []
    monkeypatch.setattr(engine, "aligner", fake)
    monkeypatch.setattr(engine, "on_history_appended", announced.append)

    async def fake_tts_post(text, backend, voice, speed, client, **_kw):
        return b"RIFFwav" + text.encode()

    monkeypatch.setattr(engine, "_tts_post", fake_tts_post)
    monkeypatch.setattr(engine._sinks, "probe_duration_s", lambda p, fmt="mp3": 20.0)

    async def run():
        entry = await engine.render(TEXT, backend_id="test-align")
        await asyncio.gather(*engine._align_jobs)
        return entry

    entry = asyncio.run(run())
    row = _db.get_render(entry["ts"])
    seam = row["seam_map"]
    assert seam[0] == [0.0, 0] and seam[-1] == [20.0, len(TEXT)]
    assert len(seam) == len(TEXT.split()) + 1          # [0,0] is also the first word
    # Announced twice: the new row, then the row with its word points.
    assert [e["ts"] for e in announced] == [entry["ts"], entry["ts"]]
    assert announced[-1]["seam_map"] == seam


def test_failed_alignment_leaves_the_row_alone(isolated_paths, backend, monkeypatch):
    monkeypatch.setattr(engine, "aligner", _FakeAligner(fail=True))

    async def fake_tts_post(text, backend, voice, speed, client, **_kw):
        return b"RIFFwav" + text.encode()

    monkeypatch.setattr(engine, "_tts_post", fake_tts_post)
    monkeypatch.setattr(engine._sinks, "probe_duration_s", lambda p, fmt="mp3": 20.0)

    async def run():
        entry = await engine.render(TEXT, backend_id="test-align")
        await asyncio.gather(*engine._align_jobs)
        return entry

    entry = asyncio.run(run())
    assert _db.get_render(entry["ts"])["seam_map"] is None


def test_short_render_is_not_aligned(isolated_paths, backend, monkeypatch):
    fake = _FakeAligner()
    monkeypatch.setattr(engine, "aligner", fake)

    async def fake_tts_post(text, backend, voice, speed, client, **_kw):
        return b"RIFFwav" + text.encode()

    monkeypatch.setattr(engine, "_tts_post", fake_tts_post)
    monkeypatch.setattr(engine._sinks, "probe_duration_s", lambda p, fmt="mp3": 3.0)
    asyncio.run(engine.render(TEXT, backend_id="test-align"))
    assert fake.calls == [] and not engine._align_jobs


_PARA = ("The fishing boats rocked against their ropes while gulls argued "
         "over scraps on the quay. ") * 12          # ~1,060 chars: one per chunk
THREE_CHUNKS = f"{_PARA.strip()}\n\n{_PARA.strip()}\n\n{_PARA.strip()}"


def test_stream_render_is_aligned_once_finished(backend, monkeypatch, tmp_path):
    """No alignment while the chunks render (it would share the GPU with the
    TTS model): the row lands with its chunk seams, then the file is aligned."""
    fake = _FakeAligner()
    monkeypatch.setattr(engine, "aligner", fake)
    scheduled: list[str] = []

    async def fake_tts_post(text, backend, voice, speed, client, **_kw):
        return b"RIFFwav" + text.encode()[:8]

    def fake_concat(wav_paths, out_stem):
        out = tmp_path / f"{out_stem}.mp3"
        out.write_bytes(b"ID3")
        return out

    monkeypatch.setattr(engine, "_tts_post", fake_tts_post)
    monkeypatch.setattr(engine._sinks, "concat_wavs_to_mp3", fake_concat)
    monkeypatch.setattr(engine._sinks, "probe_duration_s", lambda p, fmt="mp3": 60.0)
    monkeypatch.setattr(engine._sinks, "trim_chunk_silence_inplace", lambda p, trailing=True: None)
    monkeypatch.setattr(engine._db, "insert_render", lambda e: None)
    monkeypatch.setattr(engine, "_align_later", lambda e: scheduled.append(e["ts"]))

    entry = asyncio.run(engine.render_longform(
        THREE_CHUNKS, backend_id="test-align", mode="stream"))
    assert fake.calls == []
    assert len(entry["seam_map"]) == 4                  # [0,0] + the three chunk seams
    assert scheduled == [entry["ts"]]


def test_alignment_waits_for_renders_to_finish(isolated_paths, backend, monkeypatch):
    fake = _FakeAligner()
    monkeypatch.setattr(engine, "aligner", fake)

    async def fake_tts_post(text, backend, voice, speed, client, **_kw):
        return b"RIFFwav" + text.encode()

    monkeypatch.setattr(engine, "_tts_post", fake_tts_post)
    monkeypatch.setattr(engine._sinks, "probe_duration_s", lambda p, fmt="mp3": 20.0)
    real_idle = engine._GATE.idle
    monkeypatch.setattr(engine._GATE, "idle", lambda: real_idle(poll_s=0.01))

    async def run():
        entry = await engine.render(TEXT, backend_id="test-align")
        await asyncio.gather(*engine._align_jobs)       # the row's own alignment
        fake.calls.clear()
        async with engine._GATE.episode():              # a render in progress
            job = asyncio.ensure_future(engine.align_entry(entry["ts"]))
            await asyncio.sleep(0.05)
            assert fake.calls == [] and not job.done()
        assert await job == len(TEXT.split())
        assert len(fake.calls) == 1

    asyncio.run(run())
