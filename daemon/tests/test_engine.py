"""Engine tests — exercise the render pipeline against a mock TTS server.

We stand up a tiny aiohttp app that emits a fixed MP3-like blob and verify
the two artefacts land with the right contents: the audio file under
ARCHIVE_ROOT and a row in the SQLite store. Errors at any stage must roll
back cleanly.

Run:
  cd system/services/voice-say
  .venv/bin/pip install -e ".[dev]"
  .venv/bin/pytest -v
"""
from __future__ import annotations

import asyncio
from pathlib import Path

import httpx
import pytest
from aiohttp import web

import voice_say.engine as engine
import voice_say._db as _db
from voice_say import _sinks


# A fake MP3 — just enough bytes to pass the "not empty" check.
FAKE_MP3 = b"\xff\xfb\x90\x00" + b"\x00" * 1024


@pytest.fixture
async def mock_tts():
    """A real aiohttp server that pretends to be a TTS backend on a random
    port. Returns the URL prefix the test should hit."""
    app = web.Application()

    async def handler(request: web.Request) -> web.Response:
        body = await request.json()
        if not body.get("input"):
            return web.json_response({"error": "empty"}, status=400)
        return web.Response(body=FAKE_MP3, content_type="audio/mpeg")

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
    """Register a SYNTHETIC mp3 backend ("test") pointed at the mock TTS.
    Deliberately not templated from the shipped catalog — the render-pipeline
    tests exercise engine plumbing (archive, db, kinds, tags), and a change to
    the shipped catalog must not churn them."""
    fake = engine.Backend(
        id="test", label="Test", port=int(mock_tts.split(":")[-1]),
        default_voice="af_alloy", voices=("af_alloy", "af_bella"),
        supports_speed=True,
        supports_emotion_tags=False,
        accent="#888888",
        timeout_s=60.0,
    )
    monkeypatch.setitem(engine.BACKENDS, "test", fake)
    return fake


async def test_render_happy_path(isolated_paths, mock_backend):
    entry = await engine.render("hello world from voice-say.", backend_id="test", tags=["a11y"])

    # Entry shape
    assert entry["backend"] == "test"
    assert entry["chars"] == len("hello world from voice-say.")
    assert entry["bytes"] == len(FAKE_MP3)
    assert entry["tags"] == ["a11y"]
    assert entry["text"] == "hello world from voice-say."
    assert entry["kind"] == "say"  # short text

    # Audio on disk
    audio = Path(entry["archive_path"])
    assert audio.is_file()
    assert audio.read_bytes() == FAKE_MP3

    # SQLite store
    rows = engine.read_history()
    assert len(rows) == 1
    assert rows[0]["archive_name"] == entry["archive_name"]
    assert _db.get_render(entry["ts"])["text"] == "hello world from voice-say."


async def test_render_short_text_is_kind_say(isolated_paths, mock_backend):
    """Short text (<= SAY_THRESHOLD_CHARS) is classified as a 'say'."""
    entry = await engine.render("done.", backend_id="test")
    assert entry["kind"] == "say"


async def test_render_long_text_is_kind_render(isolated_paths, mock_backend):
    """Text longer than SAY_THRESHOLD_CHARS is classified as a 'render'."""
    long_text = "a " * 200  # 400 chars >> threshold
    assert len(long_text) > engine.config.SAY_THRESHOLD_CHARS
    entry = await engine.render(long_text, backend_id="test")
    assert entry["kind"] == "render"


def test_kind_boundary_at_threshold():
    """classify_kind is inclusive at the threshold: exactly
    SAY_THRESHOLD_CHARS is a 'say', one more is a 'render'."""
    n = engine.config.SAY_THRESHOLD_CHARS
    assert engine.classify_kind("x" * n) == "say"
    assert engine.classify_kind("x" * (n + 1)) == "render"


async def test_render_stores_full_text_in_db(isolated_paths, mock_backend):
    """The full transcript lands in the SQLite store, untruncated."""
    long_text = "x" * 350  # > 300 chars
    entry = await engine.render(long_text, backend_id="test")
    assert _db.get_render(entry["ts"])["text"] == long_text


async def test_search_finds_rendered_text(isolated_paths, mock_backend):
    """FTS5 search over the store surfaces a just-rendered transcript."""
    entry = await engine.render("a tale of zephyrine and the sea.", backend_id="test")
    hits = _db.search("zephyrine")
    assert any(r["ts"] == entry["ts"] for r in hits)


async def test_render_empty_text_raises(isolated_paths, mock_backend):
    with pytest.raises(engine.RenderError) as ei:
        await engine.render("   ", backend_id="test")
    assert ei.value.stage == "request"


async def test_render_unknown_backend_raises(isolated_paths):
    with pytest.raises(engine.RenderError) as ei:
        await engine.render("some text", backend_id="nonexistent")
    assert ei.value.stage == "request"


async def test_read_history_round_trip(isolated_paths, mock_backend):
    await engine.render("first one.", backend_id="test")
    await asyncio.sleep(0.01)  # ensure distinct timestamps in archive name
    await engine.render("second one.", backend_id="test")
    rows = engine.read_history()
    assert len(rows) == 2
    # Newest first — second render comes back first
    assert "second" in rows[0]["text"]
    assert "first" in rows[1]["text"]


def test_list_backends_shape():
    """The committed catalog is Kokoro on mlx-audio's server, written as the
    short form: url + model, voices left to the server."""
    backends = engine.list_backends()
    assert [b["id"] for b in backends] == ["kokoro"]
    (k,) = backends
    assert (k["url"], k["port"], k["output_format"]) == ("http://127.0.0.1:8000", 8000, "wav")
    assert k["model"] == "mlx-community/Kokoro-82M-bf16"
    assert k["default_voice"] == "af_heart" and k["supports_speed"] is True
    assert engine.BACKENDS["kokoro"].lists_voices


def test_catalog_entry_forms():
    """`url` (a trailing /v1 dropped, port from the scheme when absent) or the
    older host + port; neither is a startup error naming the entry."""
    url, host, port = engine._where("x", {"url": "https://tts.example.com/v1/"})
    assert (url, host, port) == ("https://tts.example.com", "tts.example.com", 443)
    assert engine._where("x", {"host": "10.0.0.2", "port": 8891}) == ("", "10.0.0.2", 8891)
    with pytest.raises(ValueError, match="'x' needs a url"):
        engine._where("x", {"model": "m"})
    with pytest.raises(ValueError, match="not http"):
        engine._where("x", {"url": "127.0.0.1:8000"})


def test_list_voices_unknown_backend_returns_empty():
    assert engine.list_voices("nonexistent") == []


def _mk_backend(bid, default_voice, voices):
    return engine.Backend(
        id=bid, label=bid, port=1, default_voice=default_voice,
        voices=tuple(voices), supports_speed=False,
        supports_emotion_tags=False, accent="#000000",
    )


def test_resolve_voice_is_backend_aware(monkeypatch):
    """Regression: the global default voice must only be applied to backends
    that declare it. A voice that exists on only one backend must NOT be
    forced onto another backend, which would fail the request. That backend
    then falls back to its own default_voice."""
    monkeypatch.setattr(engine.config, "DEFAULT_VOICE", "af_cloned")
    clone = _mk_backend("clone", "af_cloned", ["af_cloned", "af_cloned_calm"])
    preset = _mk_backend("preset", "af_alloy", ["af_alloy", "af_bella"])
    fixed = _mk_backend("fixed", "default", ["Aiden", "Ryan"])

    # Explicit voice always wins (curated `voices` is a subset — never reject it)
    assert engine._resolve_voice("af_heart", preset) == "af_heart"
    # No voice: global default applied only where the backend declares it…
    assert engine._resolve_voice(None, clone) == "af_cloned"
    # …else the backend's OWN default (this is the bug that 502'd)
    assert engine._resolve_voice(None, preset) == "af_alloy"
    assert engine._resolve_voice(None, fixed) == "default"

    # Cleared global default → each backend uses its own default
    monkeypatch.setattr(engine.config, "DEFAULT_VOICE", "")
    assert engine._resolve_voice(None, clone) == "af_cloned"
    assert engine._resolve_voice(None, preset) == "af_alloy"


async def test_render_rejects_oversized_text(isolated_paths, mock_backend):
    huge = "x" * (engine.config.MAX_RENDER_CHARS + 1)
    with pytest.raises(engine.RenderError) as ei:
        await engine.render(huge, backend_id="test")
    assert ei.value.stage == "request"
    assert "too long" in ei.value.message


async def test_stem_collision_resists_same_second(isolated_paths, mock_backend):
    """Two renders within the same UTC second must produce distinct archive
    filenames. Pre-fix they collided on `voice-<slug>-<HHMMSS>.mp3` and the
    second render silently overwrote the first."""
    from datetime import datetime as real_datetime, timezone
    frozen = real_datetime(2026, 1, 1, 12, 0, 0, tzinfo=timezone.utc)

    class _FakeDt:
        @staticmethod
        def now(tz=None):
            return frozen
        @staticmethod
        def strftime(*a, **kw):  # pragma: no cover
            return frozen.strftime(*a, **kw)

    import voice_say.engine as eng
    real = eng.datetime
    eng.datetime = _FakeDt  # type: ignore[assignment]
    try:
        e1 = await eng.render("hello first.", backend_id="test")
        e2 = await eng.render("hello second.", backend_id="test")
    finally:
        eng.datetime = real  # type: ignore[assignment]
    assert e1["archive_name"] != e2["archive_name"]
    assert Path(e1["archive_path"]).is_file()
    assert Path(e2["archive_path"]).is_file()


def test_strip_emotion_tags_removes_brackets_and_collapses_whitespace():
    """Tags go and the gaps they leave collapse: engines that truncate on
    multi-space runs (4 s of audio for 468 chars) get one space."""
    out = engine._strip_emotion_tags("Hey [chuckle] there  friend [whisper] hi")
    assert out == "Hey there friend hi"


def test_strip_emotion_tags_keeps_paragraphs_and_non_tag_brackets():
    s = "Para one [1] see arr[0] and [this](/ðɪs/).\n\n  [laughs softly] Para two."
    assert engine._strip_emotion_tags(s) == (
        "Para one [1] see arr[0] and [this](/ðɪs/).\n\nPara two.")


def test_chunker_emits_no_empty_chunk_for_a_max_length_first_paragraph():
    for n in (1199, 1200):
        chunks, seps = engine._chunk_longform("a" * n + "\n\nSecond paragraph.")
        assert all(chunks) and len(chunks) == 2 and seps == ["", "\n\n"]


def test_strip_emotion_tags_idempotent():
    s = "plain text no brackets\n\nsecond paragraph"
    assert engine._strip_emotion_tags(s) == s
    # double-apply yields same result
    assert engine._strip_emotion_tags(engine._strip_emotion_tags(s)) == s


async def test_render_strips_emotion_tags_on_non_fish(isolated_paths, mock_backend):
    """The synthetic test backend has supports_emotion_tags=False — engine
    should strip [bracket] tags before POST. The text in the entry reflects
    the stripped text (what was actually rendered)."""
    raw = "Hello [excited] there [chuckle] friend"
    entry = await engine.render(raw, backend_id="test")
    assert "[" not in entry["text"]
    assert "Hello there friend" in entry["text"]


async def test_render_preserves_emotion_tags_when_backend_supports_them(isolated_paths, mock_tts, monkeypatch):
    """A backend with supports_emotion_tags=True must NOT have its inline
    [bracket] tags stripped — the engine passes them through."""
    fake = engine.Backend(
        id="emote", label="Emote", port=int(mock_tts.split(":")[-1]),
        default_voice="af_alloy", voices=("af_alloy",),
        supports_speed=False, supports_emotion_tags=True,
        accent="#888888", timeout_s=60.0,
    )
    monkeypatch.setitem(engine.BACKENDS, "emote", fake)
    entry = await engine.render("Hi [chuckle] friend", backend_id="emote")
    assert "[chuckle]" in entry["text"]


async def test_render_wav_backend_uses_wav_extension(isolated_paths, mock_tts, monkeypatch):
    """A backend with output_format="wav" must archive
    with a .wav extension and record format="wav" in the store, with no
    transcode — the pipeline carries WAV through verbatim."""
    fake = engine.Backend(
        id="test-wav", label="TestWav", port=int(mock_tts.split(":")[-1]),
        default_voice="af_alloy", voices=("af_alloy",),
        supports_speed=False, supports_emotion_tags=True,
        accent="#888888", timeout_s=60.0,
        output_format="wav",
    )
    monkeypatch.setitem(engine.BACKENDS, "test-wav", fake)
    entry = await engine.render("native wav render.", backend_id="test-wav")

    assert entry["format"] == "wav"
    assert entry["archive_name"].endswith(".wav")
    assert Path(entry["archive_path"]).suffix == ".wav"
    assert Path(entry["archive_path"]).is_file()
    assert _db.get_render(entry["ts"])["format"] == "wav"


def test_probe_duration_returns_zero_on_unprobeable_file(tmp_path):
    """mutagen can't read an arbitrary blob — fall back to 0.0 so the
    render entry still has a valid float (VoiceSay's progress backfill
    path can still set the real value later)."""
    f = tmp_path / "fake.mp3"
    f.write_bytes(b"not a real mp3")
    assert _sinks.probe_duration_s(f) == 0.0


async def test_render_entry_includes_duration_s_field(isolated_paths, mock_backend):
    """Even when probe fails (FAKE_MP3 isn't a real mp3), duration_s
    must be a float in the entry — never missing, never None."""
    entry = await engine.render("hi.", backend_id="test")
    assert "duration_s" in entry
    assert isinstance(entry["duration_s"], float)


async def test_per_backend_timeout_applied(isolated_paths, mock_backend, monkeypatch):
    """The httpx call uses the backend's timeout_s, not a global default."""
    captured = {}

    real_post = httpx.AsyncClient.post

    async def spy_post(self, url, *a, **kw):
        captured["timeout"] = kw.get("timeout")
        return await real_post(self, url, *a, **kw)

    monkeypatch.setattr(httpx.AsyncClient, "post", spy_post)
    await engine.render("hi.", backend_id="test")
    assert captured["timeout"] is not None
    # the synthetic test backend declares 60s
    assert captured["timeout"].read == 60.0
