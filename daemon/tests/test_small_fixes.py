"""Small daemon fixes: stale temp files are swept at startup, the local
config is written atomically (and a broken one is refused, not
overwritten), and cancelling an episode that is already
saving answers 409 instead of a false ok."""
from __future__ import annotations

import asyncio
import os
import shutil
import subprocess
import threading
import time
from pathlib import Path

import pytest
from aiohttp.test_utils import TestClient, TestServer

from voice_say import _sinks, config, engine
from voice_say.http_server import STATE_KEY, build_app


def test_sweep_removes_only_old_vs_files(tmp_path):
    old, fresh, other = tmp_path / "vs-lf-0001-a.wav", tmp_path / "vs-pad-b.wav", tmp_path / "keep.wav"
    for p in (old, fresh, other):
        p.write_bytes(b"x")
    past = time.time() - 2 * _sinks.STALE_TEMP_S
    os.utime(old, (past, past))
    os.utime(other, (past, past))
    assert _sinks.sweep_stale_temps(root=tmp_path) == 1
    assert not old.exists() and fresh.exists() and other.exists()


def test_local_config_write_is_atomic(tmp_path, monkeypatch):
    path = tmp_path / "config.local.toml"
    monkeypatch.setenv("VOICE_SAY_CONFIG", str(path))
    config.write_local({"default_voice": "a"})
    import tomli_w

    def boom(*_a, **_k):
        raise OSError("disk full")
    monkeypatch.setattr(tomli_w, "dump", boom)
    with pytest.raises(OSError):
        config.write_local({"default_voice": "b"})
    assert 'default_voice = "a"' in path.read_text()          # old file intact


def test_broken_local_config_is_an_error_not_overwritten(tmp_path, monkeypatch):
    path = tmp_path / "config.local.toml"
    path.write_text('data_root = "/x"\ncors_origins = \n')            # a hand-edit typo
    monkeypatch.setenv("VOICE_SAY_CONFIG", str(path))
    with pytest.raises(config.ConfigError, match="cannot parse"):
        config.write_local({"default_voice": "b"})
    assert path.read_text().startswith('data_root = "/x"')              # left as it was


@pytest.mark.parametrize("raw", ["*", ["http://a"], "http://a, http://b"])
def test_cors_origin_refuses_wildcards_and_lists(raw):
    with pytest.raises(config.ConfigError):
        config._resolve_cors_origin(raw)
    assert config._resolve_cors_origin(" http://localhost:5173 ") == "http://localhost:5173"


@pytest.mark.skipif(not Path(_sinks.FFMPEG).exists() and shutil.which("ffmpeg") is None,
                    reason="needs ffmpeg")
@pytest.mark.parametrize("rate", [22050, 24000, 48000])
def test_resume_lead_keeps_the_backends_sample_rate(tmp_path, rate):
    mp3 = tmp_path / "draft.mp3"
    subprocess.run([_sinks.FFMPEG, "-loglevel", "error", "-f", "lavfi", "-i",
                    f"sine=frequency=220:sample_rate={rate}:duration=0.5", str(mp3)], check=True)
    wav = _sinks.decode_mp3_to_wav(mp3)
    try:
        assert _sinks._probe_sample_rate(wav) == rate
    finally:
        wav.unlink(missing_ok=True)


def test_reload_refreshes_allowed_tags_and_max_chunks(tmp_path, monkeypatch):
    path = tmp_path / "config.local.toml"
    monkeypatch.setenv("VOICE_SAY_CONFIG", str(path))
    monkeypatch.delenv("VOICE_SAY_LONGFORM_MAX_CHUNKS", raising=False)
    monkeypatch.setattr(config, "ALLOWED_TAGS", config.ALLOWED_TAGS)
    monkeypatch.setattr(config, "LONGFORM_MAX_CHUNKS", config.LONGFORM_MAX_CHUNKS)
    path.write_text('allowed_tags = ["news"]\nlongform_max_chunks = 7\n')
    config.reload()
    try:
        assert config.ALLOWED_TAGS == ["news"] and config.LONGFORM_MAX_CHUNKS == 7
    finally:
        monkeypatch.undo()
        config.reload()


async def test_cancel_while_saving_is_409(isolated_paths, monkeypatch, tmp_path):
    fake = engine.Backend(
        id="t", label="T", port=1, default_voice="v", voices=("v",),
        supports_speed=False, supports_emotion_tags=True, accent="#888888",
        timeout_s=60.0, output_format="wav")
    monkeypatch.setattr(engine, "BACKENDS", {"t": fake})
    started = threading.Event()

    async def tts(*_a, **_k):
        return b"RIFF" + b"\0" * 64

    def slow_concat(wavs, stem):
        started.set()
        time.sleep(0.5)
        out = tmp_path / f"{stem}.mp3"
        out.write_bytes(b"ID3")
        return out

    monkeypatch.setattr(engine, "_tts_post", tts)
    monkeypatch.setattr(engine._sinks, "concat_wavs_to_mp3", slow_concat)
    monkeypatch.setattr(engine._sinks, "trim_chunk_silence_inplace", lambda p, **k: p)
    monkeypatch.setattr(engine._sinks, "probe_duration_s", lambda p, fmt="mp3": 1.0)
    async with TestClient(TestServer(build_app())) as cli:
        render = asyncio.create_task(cli.post(
            "/render_longform", json={"text": "x" * 1100 + "\n\n" + "y" * 1100,
                                      "backend": "t", "mode": "stream"}))
        while not started.is_set():
            await asyncio.sleep(0.005)
        (episode_id,) = list(cli.server.app[STATE_KEY].episodes._episodes)
        r = await cli.post(f"/episode/{episode_id}/cancel")
        assert r.status == 409
        assert (await render).status == 200                     # the row landed


def test_normalize_tag_matches_the_apps_sanitizer():
    from voice_say.engine import normalize_tag
    assert normalize_tag("News!!") == "news"
    assert normalize_tag("  Daily Notes_v6 ") == "daily-notes-v6"
    assert normalize_tag("--a  -- b--") == "a-b"
    assert normalize_tag("!!!") == ""


def test_env_reads_the_new_name_then_the_old_one(monkeypatch):
    """VOICE_SAY_<X> wins; SAY_MCP_<X> (SAY_MOCK_<X> for the mock knobs) is
    still read when the new name is unset (renamed 2026-10-26, ADR-0010)."""
    for name in ("VOICE_SAY_PORT", "SAY_MCP_PORT", "VOICE_SAY_MOCK_RTF", "SAY_MOCK_RTF"):
        monkeypatch.delenv(name, raising=False)
    assert config.env("VOICE_SAY_PORT") is None
    monkeypatch.setenv("SAY_MCP_PORT", "9001")
    assert config.env("VOICE_SAY_PORT") == "9001"
    monkeypatch.setenv("VOICE_SAY_PORT", "9002")
    assert config.env("VOICE_SAY_PORT") == "9002"
    monkeypatch.setenv("SAY_MOCK_RTF", "0.5")
    assert config.env("VOICE_SAY_MOCK_RTF") == "0.5"


def test_a_relative_data_root_is_made_absolute(monkeypatch, tmp_path):
    """The daemon hands archive paths to clients in other directories, so a
    relative data_root counts from where it was written, never the daemon's cwd."""
    local = tmp_path / "conf" / "config.local.toml"
    local.parent.mkdir()
    local.write_text('data_root = "./data"\n')
    monkeypatch.setenv("VOICE_SAY_CONFIG", str(local))
    for name in ("VOICE_SAY_DATA_ROOT", "SAY_MCP_DATA_ROOT"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(config, "_FILE", config._load_files())
    monkeypatch.chdir(tmp_path)
    assert config._path("data_root", "VOICE_SAY_DATA_ROOT", None) == (local.parent / "data").resolve()
    monkeypatch.setenv("VOICE_SAY_DATA_ROOT", "rel")
    assert config._path("data_root", "VOICE_SAY_DATA_ROOT", None) == (tmp_path / "rel").resolve()
    monkeypatch.setenv("VOICE_SAY_DATA_ROOT", "/abs/root")
    assert config._path("data_root", "VOICE_SAY_DATA_ROOT", None) == Path("/abs/root")
