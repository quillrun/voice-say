"""`voice-say render` (cli/voice-say → cli/voice-say-render) against a mock daemon (never the live one): --title, --series and
--episode ride on the render request; a bad --episode is refused before any
request; a failed render's kept draft is named on stderr."""
from __future__ import annotations

import asyncio
import json
import os
import shutil
from pathlib import Path

import pytest
from aiohttp import web

VOICE_SAY = Path(__file__).resolve().parents[2] / "cli" / "voice-say"
pytestmark = pytest.mark.skipif(shutil.which("mpv") is None, reason="voice-say render needs mpv")


@pytest.fixture
async def daemon(tmp_path):
    state: dict = {"calls": [], "status": 200}
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"ID3")

    async def render(req: web.Request) -> web.Response:
        body = await req.json()
        state["calls"].append((req.path, body))
        if state["status"] != 200:
            return web.json_response({"error": "tts", "message": "backend died",
                                      "saved_ts": "T-draft", "partial": True},
                                     status=state["status"])
        ov = {k: body[k] for k in ("title", "series", "episode") if k in body}
        return web.json_response({"ts": "T1", "archive_path": state.get("archive", str(audio)),
                                  "backend": "kokoro",
                                  "voice": "af_heart", "kind": "say", "duration_s": 1.25,
                                  **({"overlay": ov} if ov else {})})

    state["tags"] = ["briefing", "notes"]
    state["threshold"] = 280

    async def tags(req: web.Request) -> web.Response:
        return web.json_response({"tags": state["tags"]})

    async def config(req: web.Request) -> web.Response:
        return web.json_response({
            "say_threshold_chars": state["threshold"], "default_backend": "fake",
            "backends": [{"id": "fake", "url": state.get("backend_url") or state["url"],
                          "model": "m", "default_voice": "v1"}]})

    async def speech(req: web.Request) -> web.StreamResponse:
        # The fake backend `--fast` streams from (same app, so its url is the daemon's).
        state["speech"] = await req.json()
        resp = web.StreamResponse(headers={"Content-Type": "audio/pcm"})
        await resp.prepare(req)
        for _ in range(2):
            await resp.write(b"\x01\x00" * 2400)
        await resp.write_eof()
        return resp

    async def audio_file(req: web.Request) -> web.Response:
        state["fetched"] = req.match_info["ts"]
        return web.Response(body=b"RIFFremote")

    app = web.Application(client_max_size=64 * 1024 ** 2)
    app.router.add_get("/audio/{ts}", audio_file)
    app.router.add_post("/v1/audio/speech", speech)
    app.router.add_post("/render", render)
    app.router.add_post("/render_longform", render)
    app.router.add_get("/tags", tags)
    app.router.add_get("/config", config)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    state["url"] = f"http://127.0.0.1:{site._server.sockets[0].getsockname()[1]}"
    yield state
    await runner.cleanup()


async def _render(daemon, tmp_path, *args, cwd=None,
                  out=True, play=False, **extra_env) -> tuple[int, str, str]:
    # The caller's own daemon URL would outrank the one under test.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("VOICE_SAY_RENDER_")}
    env.update({"VOICE_SAY_DAEMON_URL": daemon["url"], **extra_env})
    if play:
        # Playing runs `voice-ctl stop`, which with no player falls back to an
        # optional media-remote command and would pause the machine's own audio.
        env["HOME"] = str(tmp_path)
        env["VOICE_CTL_MEDIA_REMOTE"] = "voice-ctl-test-no-media-remote"
    proc = await asyncio.create_subprocess_exec(
        str(VOICE_SAY), "render", *([] if play else ["--no-play"]),
        *([f"--out={tmp_path / 'out.mp3'}"] if out else []),
        *args,
        env=env, cwd=cwd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await proc.communicate()
    return proc.returncode, out.decode(), err.decode()


async def test_text_longer_than_the_argument_limit_renders(daemon, tmp_path):
    # 190k non-ASCII characters are ~1.1 MB of escaped JSON: over macOS's 1 MB ARG_MAX.
    text = tmp_path / "long.txt"
    text.write_text("ă" * 190_000)
    rc, _, err = await _render(daemon, tmp_path, "--title=Long", f"--file={text}")
    assert rc == 0, err
    assert daemon["calls"][0][1]["text"].rstrip("\n") == "ă" * 190_000


async def test_value_flags_take_the_next_word_too(daemon, tmp_path):
    text = tmp_path / "t.txt"
    text.write_text("hello from a file")
    rc, _, err = await _render(daemon, tmp_path, "--file", str(text), "--out",
                               str(tmp_path / "copy.mp3"), "--title", "Two words", out=False)
    assert rc == 0, err
    assert daemon["calls"][0][1]["text"].strip() == "hello from a file"
    assert daemon["calls"][0][1]["title"] == "Two words"
    assert (tmp_path / "copy.mp3").exists()
    rc, _, err = await _render(daemon, tmp_path, "hello", "--title")
    assert rc == 4 and "needs a value" in err


async def test_default_out_takes_the_archive_extension(daemon, tmp_path):
    wav = tmp_path / "b.wav"
    wav.write_bytes(b"RIFF")
    daemon["archive"] = str(wav)
    rc, out, err = await _render(daemon, tmp_path, "--json", "hello", out=False,
                                 TMPDIR=str(tmp_path))
    assert rc == 0, err
    assert json.loads(out)["out"].endswith(".wav")


async def test_a_daemon_on_another_machine_serves_the_audio(daemon, tmp_path):
    daemon["archive"] = "/nowhere/on/this/machine/a.wav"
    rc, _, err = await _render(daemon, tmp_path, "hello")
    assert rc == 0, err
    assert daemon["fetched"] == "T1"
    assert (tmp_path / "out.wav").read_bytes() == b"RIFFremote"


async def test_a_module_in_the_working_directory_is_not_imported(daemon, tmp_path):
    # An agent runs `voice-say render` from inside whatever repo it works in.
    proj = tmp_path / "proj"
    proj.mkdir()
    (proj / "json.py").write_text('raise SystemExit("planted json.py ran")\n')
    rc, out, err = await _render(daemon, tmp_path, "--json", "--title=T", "hello", cwd=proj)
    assert rc == 0, err
    assert "planted" not in err
    assert json.loads(out)["title"] == "T"


async def test_title_series_episode_ride_on_the_render(daemon, tmp_path):
    rc, out, err = await _render(daemon, tmp_path, "--title=Ep 3", "--series=Daily Notes",
                              "--episode=3", "hello there")
    assert rc == 0, err
    path, body = daemon["calls"][0]
    assert path == "/render"
    assert (body["title"], body["series"], body["episode"]) == ("Ep 3", "Daily Notes", 3)
    assert "titled: Ep 3" in out


async def test_bad_episode_is_refused_before_rendering(daemon, tmp_path):
    rc, _, err = await _render(daemon, tmp_path, "--episode=two", "hello")
    assert rc == 4 and "whole number" in err
    assert daemon["calls"] == []


async def test_failed_render_names_the_kept_draft(daemon, tmp_path):
    daemon["status"] = 502
    rc, _, err = await _render(daemon, tmp_path, "hello")
    assert rc == 3
    assert "kept: draft T-draft" in err


async def test_title_from_markdown_heading(daemon, tmp_path):
    md = tmp_path / "ep.md"
    md.write_text("# Attention from Scratch\n\nBody.\n")
    rc, _, err = await _render(daemon, tmp_path, f"--title-from={md}", "hello")
    assert rc == 0, err
    assert json.loads(json.dumps(daemon["calls"][0][1]))["title"] == "Attention from Scratch"


async def test_out_takes_the_archive_extension_with_a_warning(daemon, tmp_path):
    """The backend decides the format: an --out named for another one is saved
    under the archive's extension, and the rename is said on stderr."""
    wav = tmp_path / "b.wav"
    wav.write_bytes(b"RIFF")
    daemon["archive"] = str(wav)
    rc, out, err = await _render(daemon, tmp_path, "--json", "hello")
    assert rc == 0, err
    assert json.loads(out)["out"] == str(tmp_path / "out.wav")
    assert (tmp_path / "out.wav").read_bytes() == b"RIFF"
    assert not (tmp_path / "out.mp3").exists()
    assert "WARN: the audio is .wav" in err
    rc, out, err = await _render(daemon, tmp_path, "--json", f"--out={tmp_path / 'plain'}",
                                 "hello", out=False)
    assert rc == 0, err
    assert json.loads(out)["out"] == str(tmp_path / "plain.wav")


async def test_flag_format_is_gone(daemon, tmp_path):
    rc, _, err = await _render(daemon, tmp_path, "--format=mp3", "hello")
    assert rc == 4 and "unknown flag" in err
    assert daemon["calls"] == []


LONG = "Words words words. " * 20   # 380 chars: over the 280 say threshold


async def test_text_over_the_say_threshold_needs_a_title(daemon, tmp_path):
    rc, _, err = await _render(daemon, tmp_path, LONG)
    assert rc == 4 and "needs a title" in err and "280" in err
    assert daemon["calls"] == []
    rc, _, err = await _render(daemon, tmp_path, "--title=Long one", LONG)
    assert rc == 0, err
    assert daemon["calls"][0][1]["title"] == "Long one"


async def test_threshold_comes_from_the_daemon(daemon, tmp_path):
    daemon["threshold"] = 1000
    rc, _, err = await _render(daemon, tmp_path, LONG)
    assert rc == 0, err


async def test_short_text_needs_no_title(daemon, tmp_path):
    rc, _, err = await _render(daemon, tmp_path, "hello")
    assert rc == 0, err


async def test_unknown_tag_is_refused_before_rendering(daemon, tmp_path):
    rc, _, err = await _render(daemon, tmp_path, "--tag=brief", "hello")
    assert rc == 4 and "unknown tag(s) brief" in err and "briefing" in err and "--new-tag" in err
    assert daemon["calls"] == []


async def test_known_tag_and_new_tag_render(daemon, tmp_path):
    rc, _, err = await _render(daemon, tmp_path, "--tag=notes", "--new-tag=fresh", "hello")
    assert rc == 0, err
    assert daemon["calls"][0][1]["tags"] == ["notes", "fresh"]



async def test_json_is_the_only_stdout(daemon, tmp_path):
    rc, out, err = await _render(daemon, tmp_path, "--json", "--title=Ep 3", "hello")
    assert rc == 0, err
    body = json.loads(out)              # one object, nothing else on stdout
    assert body == {"id": "T1", "path": body["path"], "out": str(tmp_path / "out.mp3"),
                    "title": "Ep 3", "duration_s": 1.25, "backend": "kokoro",
                    "voice": "af_heart", "kind": "say", "playing": False}
    assert body["path"].endswith("a.mp3")
    assert "rendered:" in err and "titled: Ep 3" in err


async def test_json_with_fast_is_refused(daemon, tmp_path):
    rc, out, err = await _render(daemon, tmp_path, "--json", "--fast", "hello")
    assert rc == 4 and out == "" and "--json needs a library row" in err
    assert daemon["calls"] == []


async def test_fast_streams_from_the_default_backend(daemon, tmp_path):
    """--fast skips the daemon render: it asks /config for the backend and streams
    PCM from that backend's /v1/audio/speech into a wav."""
    rc, _, err = await _render(daemon, tmp_path, "--fast", "hello")
    assert rc == 0, err
    assert daemon["calls"] == []
    assert daemon["speech"] == {"model": "m", "input": "hello", "voice": "v1",
                                "stream": True, "response_format": "pcm"}
    import wave
    with wave.open(str(tmp_path / "out.wav")) as w:
        assert (w.getframerate(), w.getnframes()) == (24000, 4800)


async def test_fast_backend_and_voice_are_chosen(daemon, tmp_path):
    rc, _, err = await _render(daemon, tmp_path, "--fast", "--voice=v2", "hello",
                               VOICE_SAY_RENDER_FAST_BACKEND="fake")
    assert rc == 0, err
    assert daemon["speech"]["voice"] == "v2"
    rc, _, err = await _render(daemon, tmp_path, "--fast", "hello",
                               VOICE_SAY_RENDER_FAST_BACKEND="nope")
    assert rc == 4 and "unknown backend 'nope'" in err


async def test_no_play_and_help_need_no_mpv(daemon, tmp_path):
    bare = "/usr/bin:/bin"
    assert shutil.which("mpv", path=bare) is None
    rc, _, err = await _render(daemon, tmp_path, "hello", PATH=bare)
    assert rc == 0, err
    rc, out, err = await _render(daemon, tmp_path, "--help", PATH=bare)
    assert rc == 0 and "voice-say render" in out, err


VOICE_CTL = VOICE_SAY.parent / "voice-ctl"


@pytest.fixture
def run_dir():
    """A short per-test TMPDIR holding a live unix socket at voice-mpv.sock
    (socket paths are capped near 104 bytes, too short for tmp_path)."""
    import socket
    import tempfile
    d = tempfile.mkdtemp(prefix="vs")
    s = socket.socket(socket.AF_UNIX)
    s.bind(os.path.join(d, "voice-mpv.sock"))
    yield d
    s.close()
    shutil.rmtree(d, ignore_errors=True)


async def _ctl(*args, tmpdir, path=None) -> tuple[int, str, str]:
    env = {k: v for k, v in os.environ.items() if k != "VOICESAY_APP_SOCKET"}
    env["TMPDIR"] = tmpdir
    # Keeps any media-remote (the optional no-player fallback) out of reach.
    env["HOME"] = tmpdir
    env["VOICE_CTL_MEDIA_REMOTE"] = "voice-ctl-test-no-media-remote"
    if path:
        env["PATH"] = path
    proc = await asyncio.create_subprocess_exec(
        str(VOICE_CTL), *args, env=env,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await proc.communicate()
    return proc.returncode, out.decode(), err.decode()


async def test_voice_ctl_finds_the_player_in_the_per_user_temp_dir(run_dir, tmp_path):
    rc, out, _ = await _ctl("status", tmpdir=run_dir)
    assert rc == 0 and out.strip() == "playing"
    rc, out, _ = await _ctl("status", tmpdir=str(tmp_path))
    assert rc == 0 and out.strip() == "idle"


def _stub_socat(tmp_path) -> tuple[str, Path]:
    """A socat that logs the IPC payload instead of sending it."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    log = tmp_path / "ipc.log"
    (bin_dir / "socat").write_text(f"#!/bin/sh\ncat >> '{log}'\n")
    (bin_dir / "socat").chmod(0o755)
    return f"{bin_dir}:{os.environ['PATH']}", log


async def test_seek_forward_with_a_plus_reaches_the_player(daemon, run_dir, tmp_path):
    path, log = _stub_socat(tmp_path)
    rc, out, err = await _render(daemon, tmp_path, "--seek=+15", TMPDIR=run_dir, PATH=path)
    assert rc == 0, err
    rc, _, err = await _ctl("seek", "+2.5", tmpdir=run_dir, path=path)
    assert rc == 0, err
    assert [json.loads(line) for line in log.read_text().splitlines()] == [
        {"command": ["seek", 15, "relative"]}, {"command": ["seek", 2.5, "relative"]}]


async def test_malformed_seek_is_refused(daemon, tmp_path):
    for bad in ("5x", "+", "1e3", "--5"):
        rc, _, err = await _render(daemon, tmp_path, f"--seek={bad}")
        assert rc == 4 and "must be a number" in err, (bad, err)


async def test_missing_file_is_exit_2(daemon, tmp_path):
    rc, _, err = await _render(daemon, tmp_path, f"--file={tmp_path / 'nope.txt'}")
    assert rc == 2 and "not a readable file" in err
    assert daemon["calls"] == []


async def test_title_from_without_a_heading_is_no_title(daemon, tmp_path):
    md = tmp_path / "plain.md"
    md.write_text("No heading here.\n")
    for src in (md, tmp_path / "missing.md"):
        rc, _, err = await _render(daemon, tmp_path, f"--title-from={src}", LONG)
        assert rc == 4 and "needs a title" in err, err
    assert daemon["calls"] == []


async def test_fast_with_the_backend_down_fails_in_the_foreground(daemon, tmp_path):
    """Playing, --fast backgrounds itself; a dead backend must still be exit 6
    in the caller, not a silent background failure."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    (bin_dir / "mpv").write_text("#!/bin/sh\nexec cat >/dev/null\n")
    (bin_dir / "mpv").chmod(0o755)
    daemon["backend_url"] = "http://127.0.0.1:9"
    rc, _, err = await _render(daemon, tmp_path, "--fast", "hello", play=True,
                               PATH=f"{bin_dir}:{os.environ['PATH']}", TMPDIR=str(tmp_path))
    assert rc == 6 and "unreachable" in err and "background" not in err, err


async def test_fast_playing_backgrounds_after_the_backend_answers(daemon, tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    got = tmp_path / "mpv-stdin"
    (bin_dir / "mpv").write_text(f"#!/bin/sh\nexec cat > '{got}'\n")
    (bin_dir / "mpv").chmod(0o755)
    rc, _, err = await _render(daemon, tmp_path, "--fast", "hello", play=True,
                               PATH=f"{bin_dir}:{os.environ['PATH']}", TMPDIR=str(tmp_path))
    assert rc == 0 and "streaming --fast in background" in err, err
    for _ in range(50):                      # the detached child pumps the stream into mpv
        if got.exists() and got.stat().st_size == 9600:
            break
        await asyncio.sleep(0.1)
    assert got.stat().st_size == 9600
