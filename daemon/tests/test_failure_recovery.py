"""A failed longform render keeps its finished chunks: a transient backend
error is retried, a mid-episode failure saves a resumable draft (resume then
renders only the rest), and when even that save fails the chunk wavs are kept
on disk. Real sinks (ffmpeg) and a throwaway db; only the TTS POST is faked."""
from __future__ import annotations

import dataclasses
import io
import math
import shutil
import wave
from pathlib import Path

import httpx
import pytest

from voice_say import _db, _routes_render, _sinks, engine

pytestmark = pytest.mark.skipif(shutil.which("ffmpeg") is None,
                                reason="ffmpeg not installed")

_PARA = "x" * 1100                    # one chunk each at chunk_max 1200
FIVE = "\n\n".join([_PARA] * 5)


def _wav(seconds: float = 0.3) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(24000)
        n = int(24000 * seconds)
        w.writeframes(b"".join(
            int(6000 * math.sin(2 * math.pi * 220 * i / 24000)).to_bytes(2, "little", signed=True)
            for i in range(n)))
    return buf.getvalue()


@pytest.fixture(autouse=True)
def _backend(monkeypatch):
    fake = engine.Backend(
        id="test-fr", label="T", port=1, default_voice="v", voices=("v",),
        supports_speed=False, supports_emotion_tags=True, accent="#888888",
        timeout_s=60.0, output_format="wav")
    monkeypatch.setattr(engine, "BACKENDS", {"test-fr": fake})
    monkeypatch.setattr(engine, "TTS_RETRY_DELAY_S", 0.0)
    return fake


@pytest.fixture
def tts(monkeypatch):
    """Fake TTS: records each chunk; raises on the call numbers in `fail_on`."""
    state = {"calls": [], "fail_on": set()}

    async def fake(text, backend, voice, speed, client, response_format=None,
                   chunk_index=None, mock=False, **_kw):
        state["calls"].append(text)
        if len(state["calls"]) in state["fail_on"]:
            raise engine.RenderError("tts", "backend died")
        return _wav()

    monkeypatch.setattr(engine, "_tts_post", fake)
    return state


async def test_stream_failure_keeps_draft_and_resume_renders_only_the_rest(isolated_paths, tts):
    events: list[dict] = []
    tts["fail_on"] = {3}
    with pytest.raises(engine.RenderError) as ei:
        await engine.render_longform(FIVE, backend_id="test-fr", mode="stream",
                                     on_episode_event=events.append)
    draft = _db.get_render(ei.value.saved_ts)
    assert draft is not None and "draft" in draft["tags"]
    assert draft["resume_char_offset"] == 2 * len(_PARA) + 2
    assert 0.5 < draft["duration_s"] < 1.6               # 2 x 0.3 s + one seam pad
    err = events[-1]
    assert err["type"] == "episode_error" and err["saved_ts"] == draft["ts"]
    assert err["partial"] is True

    tts["calls"].clear()
    tts["fail_on"] = set()
    entry = await engine.resume_longform(draft["ts"])
    assert len(tts["calls"]) == 3                       # chunks 3-5 only
    assert entry["text"] == FIVE
    assert (_db.read_overlay(draft["ts"]) or {}).get("deleted")   # superseded


async def test_sequential_failure_keeps_draft(isolated_paths, tts):
    tts["fail_on"] = {2}
    with pytest.raises(engine.RenderError) as ei:
        await engine.render_longform(FIVE, backend_id="test-fr")
    draft = _db.get_render(ei.value.saved_ts)
    assert "draft" in draft["tags"]
    assert draft["resume_char_offset"] == len(_PARA)
    assert draft["resume_full_text"] == FIVE


async def test_failure_before_any_chunk_saves_nothing(isolated_paths, tts):
    tts["fail_on"] = {1}
    with pytest.raises(engine.RenderError) as ei:
        await engine.render_longform(FIVE, backend_id="test-fr", mode="stream")
    assert getattr(ei.value, "saved_ts", None) is None
    assert _db.read_history(10) == []


async def test_concat_failure_keeps_the_chunk_wavs(isolated_paths, tts, monkeypatch):
    def broken(*_a, **_k):
        raise _sinks.ConcatError("ffmpeg exploded")
    monkeypatch.setattr(_sinks, "concat_wavs_to_mp3", broken)
    with pytest.raises(engine.RenderError):
        await engine.render_longform(FIVE, backend_id="test-fr", mode="stream")
    kept = list((isolated_paths["archive"] / ".failed").glob("*/*.wav"))
    assert len(kept) == 5
    assert _db.read_history(10) == []


async def test_resume_with_a_different_chunk_size_neither_skips_nor_repeats(
        isolated_paths, tts, _backend, monkeypatch):
    tts["fail_on"] = {3}
    with pytest.raises(engine.RenderError) as ei:
        await engine.render_longform(FIVE, backend_id="test-fr", mode="stream")
    monkeypatch.setitem(engine.BACKENDS, "test-fr",              # pairs now
                        dataclasses.replace(_backend, longform_chunk_max=2300))
    tts["calls"].clear()
    tts["fail_on"] = set()
    entry = await engine.resume_longform(ei.value.saved_ts)
    assert [len(c) for c in tts["calls"]] == [2 * len(_PARA) + 2, len(_PARA)]
    assert entry["text"] == FIVE


async def test_superseded_draft_is_not_resumed_twice(isolated_paths, tts):
    tts["fail_on"] = {3}
    with pytest.raises(engine.RenderError) as ei:
        await engine.render_longform(FIVE, backend_id="test-fr", mode="stream")
    draft_ts = ei.value.saved_ts
    tts["fail_on"] = set()
    await engine.resume_longform(draft_ts)
    with pytest.raises(engine.RenderError, match="superseded"):
        await engine.resume_longform(draft_ts)


def _client(responses: list) -> tuple[httpx.AsyncClient, list]:
    seen: list = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        r = responses[min(len(seen), len(responses)) - 1]
        if isinstance(r, Exception):
            raise r
        return r

    return httpx.AsyncClient(transport=httpx.MockTransport(handler)), seen


async def test_transient_502_and_dropped_connection_are_retried(_backend):
    cli, seen = _client([httpx.Response(502),
                         httpx.RemoteProtocolError("Server disconnected"),
                         httpx.Response(200, content=b"RIFFok")])
    assert await engine._tts_post("hi", _backend, "v", 1.0, cli) == b"RIFFok"
    assert len(seen) == 3


async def test_read_timeout_and_500_are_not_retried(_backend):
    cli, seen = _client([httpx.ReadTimeout("slow")])
    with pytest.raises(engine.RenderError):
        await engine._tts_post("hi", _backend, "v", 1.0, cli)
    assert len(seen) == 1
    cli, seen = _client([httpx.Response(500, text="no output wav")])
    with pytest.raises(engine.RenderError, match="500"):
        await engine._tts_post("hi", _backend, "v", 1.0, cli)
    assert len(seen) == 1


async def test_route_names_the_saved_draft():
    async def failing():
        err = engine.RenderError("tts", "backend died")
        err.saved_ts, err.partial = "2026-10-04T20:00:00.000000Z", True
        raise err
    resp = await _routes_render._run_render("render_longform", failing())
    assert resp.status == 502
    import json
    body = json.loads(resp.text)
    assert body["saved_ts"] == "2026-10-04T20:00:00.000000Z" and body["partial"] is True


def test_chunker_never_emits_an_empty_chunk():
    chunks, _ = engine._chunk_longform("y" * 1500 + ". Short tail.", 1200)
    assert all(chunks) and chunks[0] == "y" * 1500 + "."


async def test_resume_carries_the_drafts_series_title_and_star(isolated_paths, tts):
    from voice_say import overlays
    tts["fail_on"] = {3}
    with pytest.raises(engine.RenderError) as ei:
        await engine.render_longform(FIVE, backend_id="test-fr", mode="stream")
    draft_ts = ei.value.saved_ts
    overlays.write(draft_ts, starred=True, title="Ep three", series="Notes", episode=3)
    tts["calls"].clear()
    tts["fail_on"] = {2}                    # the continuation fails again, after one new chunk
    with pytest.raises(engine.RenderError) as ei2:
        await engine.resume_longform(draft_ts)
    second = ei2.value.saved_ts
    tts["fail_on"] = set()
    entry = await engine.resume_longform(second)
    for ts in (second, entry["ts"]):
        ov = _db.read_overlay(ts) or {}
        assert (ov.get("series"), ov.get("episode"), ov.get("title"), ov.get("starred")) \
            == ("Notes", 3, "Ep three", True)


async def test_resume_finds_a_draft_moved_to_the_cold_tier(isolated_paths, tts):
    tts["fail_on"] = {3}
    with pytest.raises(engine.RenderError) as ei:
        await engine.render_longform(FIVE, backend_id="test-fr", mode="stream")
    draft = _db.get_render(ei.value.saved_ts)
    hot = Path(draft["archive_path"])
    cold = isolated_paths["archive"] / ".cold" / hot.relative_to(isolated_paths["archive"])
    cold.parent.mkdir(parents=True)
    hot.rename(cold)
    tts["calls"].clear()
    tts["fail_on"] = set()
    entry = await engine.resume_longform(draft["ts"])
    assert entry["text"] == FIVE and len(tts["calls"]) == 3


@pytest.mark.parametrize("mode", ["stream", "sequential"])
async def test_shutdown_mid_episode_keeps_the_finished_chunks(isolated_paths, monkeypatch, mode):
    import asyncio
    calls = 0
    third = asyncio.Event()

    async def fake(text, *_a, **_kw):
        nonlocal calls
        calls += 1
        if calls == 3:
            third.set()
            await asyncio.sleep(3600)              # the daemon stops during chunk 3
        return _wav()

    monkeypatch.setattr(engine, "_tts_post", fake)
    task = asyncio.ensure_future(engine.render_longform(FIVE, backend_id="test-fr", mode=mode))
    await third.wait()
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task
    kept = list((isolated_paths["archive"] / ".failed").glob("*/*.wav"))
    assert len(kept) == 2
