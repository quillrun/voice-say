"""Render concurrency gate (engine._RenderGate / _concurrency_key).

Different backend keys run concurrently (the multi-box fan-out), same-key
requests serialize (the 16 GB OOM guard), episodes run one at a time, and an
episode takes the backend per chunk, so a short render waits one chunk at most.
A request whose client left while it queued never reaches the backend.
"""
import asyncio

import pytest

from voice_say import engine
from voice_say.engine import Backend, _concurrency_key


def _backend(host: str, bid: str = "x") -> Backend:
    return Backend(id=bid, label=bid, port=1, default_voice="d", voices=(),
                   supports_speed=False, supports_emotion_tags=False,
                   accent="#000", host=host)


async def _worker(gate, key, state, hold=0.05):
    async with gate.tts(key):
        state["cur"] += 1
        state["max"] = max(state["max"], state["cur"])
        await asyncio.sleep(hold)
        state["cur"] -= 1


# --- _concurrency_key (pure, no I/O) ---------------------------------------

def test_concurrency_key_collapses_local_and_keys_remote():
    for host in ("127.0.0.1", "localhost", "::1", "0.0.0.0", "LOCALHOST"):
        assert _concurrency_key(_backend(host)) == "__local__"
    assert _concurrency_key(None) == "__local__"
    assert _concurrency_key(_backend("studio.local", "remote-gpu")) == "remote-gpu"
    assert _concurrency_key(_backend("192.168.1.20", "remote-gpu")) == "remote-gpu"


# --- gate semantics --------------------------------------------------------

async def test_different_keys_overlap():
    """Two backend requests to DIFFERENT keys run at the same time."""
    gate = engine._RenderGate()
    state = {"cur": 0, "max": 0}
    await asyncio.gather(_worker(gate, "__local__", state),
                         _worker(gate, "remote-gpu", state))
    assert state["max"] == 2          # genuine overlap — the fan-out works


async def test_same_key_serializes():
    """Two backend requests to the SAME key never overlap (OOM guard)."""
    gate = engine._RenderGate()
    state = {"cur": 0, "max": 0}
    await asyncio.gather(_worker(gate, "__local__", state),
                         _worker(gate, "__local__", state))
    assert state["max"] == 1


async def test_episodes_run_one_at_a_time_across_keys():
    gate = engine._RenderGate()
    state = {"cur": 0, "max": 0}

    async def episode():
        async with gate.episode():
            state["cur"] += 1
            state["max"] = max(state["max"], state["cur"])
            await asyncio.sleep(0.03)
            state["cur"] -= 1

    await asyncio.gather(episode(), episode())
    assert state["max"] == 1


async def test_exception_releases_and_snapshot_tracks_the_queue():
    gate = engine._RenderGate()
    with pytest.raises(ValueError):
        async with gate.tts("__local__"):
            raise ValueError("boom")
    held, go = asyncio.Event(), asyncio.Event()

    async def holder():
        async with gate.episode():
            held.set()
            await go.wait()

    t1 = asyncio.create_task(holder())
    await held.wait()
    t2 = asyncio.create_task(holder())
    await asyncio.sleep(0.01)
    snap = gate.snapshot()
    assert snap["waiting"] == 1 and snap["episode_running_s"] is not None
    go.set()
    await asyncio.gather(t1, t2)
    assert gate.snapshot() == {"waiting": 0, "episode_running_s": None}


def _fake_backend():
    return Backend(id="t", label="t", port=1, default_voice="d", voices=("d",),
                   supports_speed=False, supports_emotion_tags=True,
                   accent="#000", output_format="wav")


@pytest.fixture
def engine_stubs(monkeypatch, tmp_path):
    """Fresh gate, one fake local backend, TTS that takes 50 ms per call and
    logs it, and sinks that touch nothing."""
    monkeypatch.setattr(engine, "_GATE", engine._RenderGate())
    monkeypatch.setattr(engine, "BACKENDS", {"t": _fake_backend()})
    calls: list[str] = []

    async def tts(text, *_a, **_k):
        calls.append(text[:5])
        await asyncio.sleep(0.05)
        return b"RIFF" + b"\0" * 32

    def concat(wavs, stem):
        out = tmp_path / f"{stem}.mp3"
        out.write_bytes(b"ID3")
        return out

    monkeypatch.setattr(engine, "_tts_post", tts)
    monkeypatch.setattr(engine._sinks, "concat_wavs_to_mp3", concat)
    monkeypatch.setattr(engine._sinks, "archive_write", lambda a, st, fmt: concat([], st))
    monkeypatch.setattr(engine._sinks, "probe_duration_s", lambda p, fmt="mp3": 1.0)
    monkeypatch.setattr(engine, "_insert_unique", lambda e, ts: None)
    return calls


async def test_short_render_runs_between_episode_chunks(engine_stubs):
    """A short render arriving during a 3-chunk episode waits for the chunk in
    flight only — it finishes before the episode does."""
    episode_text = "\n\n".join(c * 1100 for c in "abc")
    done: list[str] = []

    async def episode():
        await engine.render_longform(episode_text, backend_id="t")
        done.append("episode")

    async def short():
        await asyncio.sleep(0.02)                     # chunk "a" is in flight
        await engine.render("short", backend_id="t")
        done.append("short")

    await asyncio.gather(episode(), short())
    assert done == ["short", "episode"]
    assert engine_stubs == ["aaaaa", "short", "bbbbb", "ccccc"]


async def test_render_whose_client_left_while_queued_never_runs(engine_stubs):
    gate = engine._GATE
    held, go = asyncio.Event(), asyncio.Event()

    async def holder():
        async with gate.tts("__local__"):
            held.set()
            await go.wait()

    t = asyncio.create_task(holder())
    await held.wait()
    queued = asyncio.create_task(
        engine.render("orphan", backend_id="t", is_gone=lambda: True))
    await asyncio.sleep(0.01)
    go.set()
    with pytest.raises(engine.ClientGone):
        await queued
    await t
    assert engine_stubs == []


async def test_bad_input_fails_without_waiting_for_the_queue(engine_stubs):
    async with engine._GATE.episode():               # an episode is running
        with pytest.raises(engine.RenderError):
            await asyncio.wait_for(
                engine.render_longform("", backend_id="t"), timeout=0.5)


async def test_a_hung_up_client_reads_as_gone(isolated_paths):
    """The route's probe sees a disconnect: aiohttp drops request.transport
    once the client hangs up. Production runs with handler_cancellation off
    (web.run_app's default; TestServer turns it on), so the handler survives
    the hang-up and must notice it itself."""
    from aiohttp import web
    from voice_say._routes_render import _gone

    seen: list[bool] = []
    entered, release = asyncio.Event(), asyncio.Event()

    async def handler(request):
        probe = _gone(request)
        seen.append(probe())
        entered.set()
        await release.wait()
        seen.append(probe())
        return web.Response(text="ok")

    app = web.Application()
    app.router.add_get("/slow", handler)
    runner = web.AppRunner(app, handler_cancellation=False)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    try:
        reader, writer = await asyncio.open_connection("127.0.0.1", port)
        writer.write(b"GET /slow HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        await writer.drain()
        await entered.wait()
        writer.close()                         # the client hangs up
        await writer.wait_closed()
        await asyncio.sleep(0.05)
        release.set()
        await asyncio.sleep(0.05)
    finally:
        await runner.cleanup()
    assert seen == [False, True]


async def test_health_reports_the_queue(isolated_paths):
    from aiohttp.test_utils import TestClient, TestServer
    from voice_say.http_server import build_app
    async with TestClient(TestServer(build_app())) as cli:
        body = await (await cli.get("/health")).json()
    assert body["queue"] == {"waiting": 0, "episode_running_s": None}
