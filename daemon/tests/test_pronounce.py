"""`[pronounce]` map: the backend hears the spoken form, the archive keeps the
written one; whole words only, case-sensitive, possessives follow."""
from __future__ import annotations

import pytest
from aiohttp import web

from voice_say import _db, config, engine


def test_apply_pronunciation_whole_words_only():
    table = {"Siobhan": "Shiv-awn", "Q4_K_M": "Q four K M"}
    assert engine.apply_pronunciation("Siobhan said hi.", table) == "Shiv-awn said hi."
    assert engine.apply_pronunciation("Siobhan's note", table) == "Shiv-awn's note"
    assert engine.apply_pronunciation("(Siobhan)", table) == "(Shiv-awn)"
    assert engine.apply_pronunciation("Siobhana and siobhan stay", table) == "Siobhana and siobhan stay"
    assert engine.apply_pronunciation("the Q4_K_M quant", table) == "the Q four K M quant"
    assert engine.apply_pronunciation("nothing here", {}) == "nothing here"


def test_config_reads_table_and_drops_blanks(monkeypatch):
    monkeypatch.setattr(config, "_FILE", {"pronounce": {"Siobhan": "Shiv-awn", "": "x", "Y": " "}})
    assert config._resolve_pronounce() == {"Siobhan": "Shiv-awn"}
    monkeypatch.setattr(config, "_FILE", {"pronounce": "Siobhan=Shiv-awn"})
    assert config._resolve_pronounce() == {}


@pytest.fixture
async def hearing_backend(monkeypatch):
    """A mock TTS that records the `input` it was sent."""
    heard: list[str] = []

    async def handler(request: web.Request) -> web.Response:
        body = await request.json()
        heard.append(body["input"])
        return web.Response(body=b"\xff\xfb\x90\x00" + b"\x00" * 1024, content_type="audio/mpeg")

    app = web.Application()
    app.router.add_post("/v1/audio/speech", handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    port = site._server.sockets[0].getsockname()[1]
    fake = engine.Backend(id="hear", label="Hear", port=port, default_voice="v", voices=("v",),
                          supports_speed=False, supports_emotion_tags=True, accent="#000000",
                          timeout_s=30.0)
    monkeypatch.setitem(engine.BACKENDS, "hear", fake)
    yield heard
    await runner.cleanup()


async def test_render_speaks_the_map_and_stores_the_written_form(isolated_paths, hearing_backend,
                                                                  monkeypatch):
    monkeypatch.setattr(config, "PRONOUNCE", {"Siobhan": "Shiv-awn"})
    entry = await engine.render("Siobhan's build is green.", backend_id="hear", voice="v")
    assert hearing_backend == ["Shiv-awn's build is green."]
    assert entry["text"] == "Siobhan's build is green."
    assert _db.get_render(entry["ts"])["text"] == "Siobhan's build is green."
