"""cli/voice-say against a mock daemon (never the live one): every subcommand
reaches the right route; `set --tag` refuses a tag not in the vocabulary with
the nearest existing ones and makes no overlay write; `--allow-new-tags`
coins it; `set --delete` writes the overlay first, then moves the file to the
Trash; a daemon that is down is exit 6."""
from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path

import pytest
from aiohttp import web

DAEMON_DIR = Path(__file__).resolve().parents[1]
VOICE_SAY = DAEMON_DIR.parent / "cli" / "voice-say"

ENTRIES = [
    {"ts": "2026-10-20T10:00:00Z", "kind": "render", "backend": "tts-local", "voice": "af_alloy",
     "chars": 5000, "duration_s": 300.0, "bytes": 1, "archive_name": "a.mp3",
     "archive_path": "/nowhere/a.mp3", "text": "Field note one. Body.", "tags": ["notes"],
     "overlay": {"title": "Ep 1", "series": "Daily Notes", "episode": 1, "starred": True}},
    {"ts": "2026-10-20T11:00:00Z", "kind": "say", "backend": "tts-local", "voice": "af_alloy",
     "chars": 20, "duration_s": 3.0, "bytes": 1, "archive_name": "b.wav",
     "archive_path": "/nowhere/b.wav", "text": "Short ping.", "tags": [],
     "overlay": {"deleted": True}},
]


@pytest.fixture
async def daemon(tmp_path):
    state: dict = {"calls": [], "tags": ["notes", "news", "briefing"], "entries": ENTRIES}

    async def history(req):
        state["calls"].append(("GET", req.path, dict(req.query)))
        return web.json_response({"entries": state["entries"], "total": len(state["entries"])})

    async def search(req):
        state["calls"].append(("GET", req.path, dict(req.query)))
        return web.json_response({"entries": [state["entries"][0]], "total": 1})

    async def tags(req):
        state["calls"].append(("GET", req.path, {}))
        return web.json_response({"tags": state["tags"]})

    async def voices(req):
        state["calls"].append(("GET", req.path, {}))
        if req.match_info["backend"] != "tts-local":
            return web.json_response({"error": "not_found"}, status=404)
        return web.json_response({"backend": "tts-local", "voices": ["af_alloy", "af_bella"]})

    async def health(req):
        state["calls"].append(("GET", req.path, dict(req.query)))
        body = {"status": "ok", "version": "t", "queue": {"waiting": 0, "episode_running_s": None}}
        if req.query.get("deep") == "1":
            body["backends"] = {"tts-local": "up"}
        return web.json_response(body)

    async def overlay(req):
        body = await req.json()
        state["calls"].append(("POST", req.path, body))
        return web.json_response({"ts": req.match_info["ts"], "starred": False, "deleted": False,
                                  "tags": [], "removed_tags": [], "last_modified": "now", **body})

    app = web.Application()
    app.router.add_get("/history", history)
    app.router.add_get("/search", search)
    app.router.add_get("/tags", tags)
    app.router.add_get("/voices/{backend}", voices)
    app.router.add_get("/health", health)
    app.router.add_post("/overlays/{ts}", overlay)

    async def restart(req):
        state["calls"].append(("POST", req.path, {}))
        if req.match_info["backend"] != "tts-local":
            return web.json_response({"error": "not_found", "message": "unknown"}, status=404)
        return web.json_response({"backend": "tts-local", "label": "local.voicesay.tts-local",
                                  "restarted": True, "up": True, "waited_s": 2.0})
    app.router.add_post("/backends/{backend}/restart", restart)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "127.0.0.1", 0)
    await site.start()
    state["url"] = f"http://127.0.0.1:{site._server.sockets[0].getsockname()[1]}"
    yield state
    await runner.cleanup()


async def _run(url: str, *args: str, env_extra: dict | None = None) -> tuple[int, str, str]:
    env = {**os.environ, "VOICE_SAY_DAEMON_URL": url, **(env_extra or {})}
    proc = await asyncio.create_subprocess_exec(
        sys.executable, "-m", "voice_say.cli", *args, env=env, cwd=str(DAEMON_DIR),
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await proc.communicate()
    return proc.returncode, out.decode(), err.decode()


async def test_shim_runs_the_module(daemon):
    proc = await asyncio.create_subprocess_exec(
        # the pre-2026-10-26 name still reaches the daemon
        str(VOICE_SAY), "tags",
        env={**{k: v for k, v in os.environ.items() if k != "VOICE_SAY_DAEMON_URL"},
             "SAY_MCP_DAEMON_URL": daemon["url"]},
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    out, err = await proc.communicate()
    assert proc.returncode == 0, err.decode()
    assert out.decode().split() == ["notes", "news", "briefing"]


async def test_history_hides_deleted_unless_all(daemon):
    rc, out, _ = await _run(daemon["url"], "history", "--limit", "5")
    assert rc == 0
    assert "Ep 1" in out and "[Daily Notes · 1]" in out and "★" in out
    assert "Short ping" not in out
    assert daemon["calls"][0] == ("GET", "/history", {"limit": "1000"})   # deleted rows are cut client-side
    rc, out, _ = await _run(daemon["url"], "history", "--all", "--json")
    assert rc == 0 and len(json.loads(out)["entries"]) == 2


async def test_history_series_and_search(daemon):
    rc, _, _ = await _run(daemon["url"], "history", "--series", "Daily Notes")
    assert rc == 0 and daemon["calls"][-1][2]["series"] == "Daily Notes"
    rc, out, _ = await _run(daemon["url"], "search", "field note", "--limit", "3")
    assert rc == 0 and "Ep 1" in out
    assert daemon["calls"][-1] == ("GET", "/search", {"q": "field note", "limit": "3"})


async def test_voices_and_unknown_backend(daemon):
    rc, out, _ = await _run(daemon["url"], "voices", "tts-local")
    assert rc == 0 and out.split() == ["af_alloy", "af_bella"]
    rc, _, err = await _run(daemon["url"], "voices", "nope")
    assert rc == 4 and "unknown backend" in err


async def test_restart_posts_to_the_daemon(daemon):
    rc, out, _ = await _run(daemon["url"], "restart", "tts-local")
    assert rc == 0 and out.strip() == "restarted tts-local (local.voicesay.tts-local): up after 2.0 s"
    assert daemon["calls"][-1] == ("POST", "/backends/tts-local/restart", {})
    rc, _, err = await _run(daemon["url"], "restart", "nope")
    assert rc == 4 and "unknown backend" in err


async def test_health_ok_and_deep(daemon):
    rc, out, _ = await _run(daemon["url"], "health")
    assert rc == 0 and out.startswith("ok  voice-say")
    rc, out, _ = await _run(daemon["url"], "health", "--deep")
    assert rc == 0 and "backend tts-local: up" in out


async def test_daemon_down_is_exit_6():
    rc, out, err = await _run("http://127.0.0.1:9", "history")
    assert rc == 6 and "unreachable" in err
    rc, out, _ = await _run("http://127.0.0.1:9", "health")
    assert rc == 6 and out.startswith("down")


async def test_set_title_star_series(daemon):
    rc, out, _ = await _run(daemon["url"], "set", "T1", "--title", "New name", "--star",
                            "--series", "Daily Notes", "--episode", "7")
    assert rc == 0, out
    assert daemon["calls"][-1] == ("POST", "/overlays/T1",
                                   {"title": "New name", "starred": True,
                                    "series": "Daily Notes", "episode": 7})
    assert "title: New name" in out and "starred" in out


async def test_set_unknown_tag_refused_with_nearest_and_no_write(daemon):
    rc, _, err = await _run(daemon["url"], "set", "T1", "--tag", "newz")
    assert rc == 4
    assert "unknown tag(s) newz" in err and "news" in err and "--allow-new-tags" in err
    assert all(m != "POST" for m, _, _ in daemon["calls"])


async def test_set_known_tag_normalized_and_new_tag_allowed(daemon):
    rc, _, _ = await _run(daemon["url"], "set", "T1", "--tag", "News!")
    assert rc == 0
    assert daemon["calls"][-1] == ("POST", "/overlays/T1", {"tags": ["News!"]})
    rc, _, _ = await _run(daemon["url"], "set", "T1", "--tag", "brand-new", "--allow-new-tags")
    assert rc == 0
    assert daemon["calls"][-1] == ("POST", "/overlays/T1", {"tags": ["brand-new"]})
    assert ("GET", "/tags", {}) not in daemon["calls"][-2:]


async def test_set_nothing_is_usage_error(daemon):
    rc, _, err = await _run(daemon["url"], "set", "T1")
    assert rc == 2 and "nothing to set" in err and daemon["calls"] == []


async def test_set_delete_writes_overlay_then_trashes_file(daemon, tmp_path):
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"ID3")
    daemon["entries"] = [{**ENTRIES[0], "archive_path": str(audio)}]
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    log = tmp_path / "trash.log"
    (fake_bin / "trash").write_text(f"#!/bin/sh\necho \"$@\" >> {log}\nmv \"$@\" {tmp_path}/gone\n")
    (fake_bin / "trash").chmod(0o755)
    rc, out, err = await _run(daemon["url"], "set", ENTRIES[0]["ts"], "--delete",
                              env_extra={"PATH": f"{fake_bin}:{os.environ['PATH']}"})
    assert rc == 0, err
    assert daemon["calls"][-1] == ("POST", f"/overlays/{ENTRIES[0]['ts']}", {"deleted": True})
    assert log.read_text().strip() == str(audio) and not audio.exists()
    assert "moved to Trash" in out


async def test_tags_check(daemon):
    rc, out, _ = await _run(daemon["url"], "tags", "--check", "notes", "News")
    assert rc == 0 and out.strip() == "ok: notes, news"
    rc, _, err = await _run(daemon["url"], "tags", "--check", "notes", "nope")
    assert rc == 4 and "nope" in err and "notes" in err


async def test_the_cli_imports_without_the_daemon_packages():
    """cli/voice-say falls back to a bare python3 when there is no venv: the
    module must not pull in the daemon's third-party packages."""
    blocked = ("httpx", "aiohttp", "mutagen", "tomli_w")
    code = ("import sys\n"
            f"for m in {blocked!r}: sys.modules[m] = None\n"
            f"sys.path.insert(0, {str(DAEMON_DIR)!r})\n"
            "import voice_say.cli\n"
            "voice_say.cli.build_parser()\n")
    proc = await asyncio.create_subprocess_exec(
        sys.executable, "-I", "-c", code,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    _, err = await proc.communicate()
    assert proc.returncode == 0, err.decode()


async def test_set_delete_json_keeps_stdout_one_document(daemon, tmp_path):
    audio = tmp_path / "a.mp3"
    audio.write_bytes(b"ID3")
    daemon["entries"] = [{**ENTRIES[0], "archive_path": str(audio)}]
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    (fake_bin / "trash").write_text(f"#!/bin/sh\nmv \"$@\" {tmp_path}/gone\n")
    (fake_bin / "trash").chmod(0o755)
    rc, out, err = await _run(daemon["url"], "set", ENTRIES[0]["ts"], "--delete", "--json",
                              env_extra={"PATH": f"{fake_bin}:{os.environ['PATH']}"})
    assert rc == 0, err
    assert json.loads(out)["deleted"] is True
    assert "moved to Trash" in err


async def test_set_delete_of_a_row_past_the_history_window_says_the_file_is_kept(daemon):
    daemon["entries"] = []
    rc, out, err = await _run(daemon["url"], "set", "T-old", "--delete")
    assert rc == 0, err
    assert ("GET", "/history", {"limit": "5000"}) in daemon["calls"]
    assert "file: kept" in out and "already gone" not in out


def test_publishable_check_outside_a_git_checkout_fails_instead_of_scanning_nothing(tmp_path):
    # A ZIP download has no git: the scans list files with git ls-files and
    # would pass on an empty list.
    import shutil
    import subprocess

    (tmp_path / "scripts").mkdir()
    shutil.copy(DAEMON_DIR.parent / "scripts" / "publishable-check.sh", tmp_path / "scripts")
    env = {**os.environ, "GIT_CEILING_DIRECTORIES": str(tmp_path.parent)}
    r = subprocess.run(["bash", str(tmp_path / "scripts" / "publishable-check.sh")],
                       cwd=tmp_path, env=env, capture_output=True, text=True, timeout=30)
    assert r.returncode == 1
    assert "needs a git checkout" in r.stderr
