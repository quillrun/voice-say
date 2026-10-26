"""Slow audio work (ffmpeg concat, seam pad, trim) runs off the event loop:
while a longform render sits in a blocking concat, /health still answers."""
from __future__ import annotations

import asyncio
import threading
import time

from aiohttp.test_utils import TestClient, TestServer

from voice_say import engine
from voice_say.http_server import build_app


async def test_health_answers_during_a_slow_concat(isolated_paths, monkeypatch, tmp_path):
    fake = engine.Backend(
        id="test-lf", label="T", port=1, default_voice="v", voices=("v",),
        supports_speed=False, supports_emotion_tags=True, accent="#888888",
        timeout_s=60.0, output_format="wav")
    monkeypatch.setattr(engine, "BACKENDS", {"test-lf": fake})
    started = threading.Event()
    t_start: list[float] = []

    async def fake_tts(*_a, **_k):
        return b"RIFF" + b"\0" * 64

    def slow_concat(wavs, stem):                     # blocks its thread for 1 s
        t_start.append(time.perf_counter())
        started.set()
        time.sleep(1.0)
        out = tmp_path / f"{stem}.mp3"
        out.write_bytes(b"ID3x")
        return out

    monkeypatch.setattr(engine, "_tts_post", fake_tts)
    monkeypatch.setattr(engine._sinks, "concat_wavs_to_mp3", slow_concat)
    monkeypatch.setattr(engine._sinks, "trim_chunk_silence_inplace", lambda p, **k: p)
    monkeypatch.setattr(engine._sinks, "probe_duration_s", lambda p, fmt="mp3": 1.0)

    async with TestClient(TestServer(build_app())) as cli:
        render = asyncio.create_task(cli.post(
            "/render_longform", json={"text": "x" * 1100 + "\n\n" + "x" * 1100,
                                      "backend": "test-lf", "mode": "stream"}))
        # Polled, not awaited via the loop: on a blocked loop nothing would
        # run until the concat returned, which is exactly what's measured.
        while not started.is_set():
            await asyncio.sleep(0.005)
        r = await cli.get("/health")
        took = time.perf_counter() - t_start[0]
        assert r.status == 200
        assert took < 0.3, f"/health answered {took:.2f}s after the concat began"
        assert (await render).status == 200
