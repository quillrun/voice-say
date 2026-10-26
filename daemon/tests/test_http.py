"""HTTP endpoint tests — uses aiohttp's test client to exercise the daemon
without binding a real port. Covers /config, /progress, /search, the
augmented /history shape, and the /episode/* control routes' error envelopes.
"""
from __future__ import annotations

import json

import pytest
from aiohttp import web
from aiohttp.test_utils import TestServer, TestClient

import voice_say.engine as engine
import voice_say._db as _db
from voice_say import config
from voice_say._validators import parse_json
from voice_say.http_server import build_app, STATE_KEY


@pytest.fixture
async def client(isolated_paths, catalog):
    app = build_app()
    server = TestServer(app)
    async with TestClient(server) as cli:
        yield cli


def _seed(client, ts: str) -> None:
    """A render row for `ts`: progress/overlay writes need one (else 404)."""
    client.server.app[STATE_KEY].record_history({"ts": ts, "backend": "tts-local"})


async def test_writes_to_an_unknown_ts_are_404(client):
    assert (await client.post("/overlays/nope", json={"starred": True})).status == 404
    assert (await client.post("/progress/nope", json={"played_s": 1.0})).status == 404
    assert (await client.get("/overlays/nope")).status == 404     # nothing was created


async def test_overlays_post_then_get_round_trip(client, isolated_paths):
    ts = "2026-05-25T07:00:00Z"
    _seed(client, ts)
    r = await client.post(f"/overlays/{ts}", json={
        "starred": True, "tags": ["completed"],
        "bookmarks": [{"id": "b1", "position": 0.25, "note": "key insight"}],
    })
    assert r.status == 200
    r2 = await client.get(f"/overlays/{ts}")
    body = await r2.json()
    assert body["starred"] is True
    assert body["tags"] == ["completed"]
    assert body["bookmarks"][0]["id"] == "b1"


@pytest.mark.parametrize("body", [
    {"deleted": "false"}, {"starred": 1}, {"tags": "abc"}, {"tags": [1]},
    {"bookmarks": 5}, {"title": 7},
])
async def test_overlays_post_wrong_types_are_400(client, isolated_paths, body):
    ts = "2026-05-25T07:00:00Z"
    _seed(client, ts)
    r = await client.post(f"/overlays/{ts}", json=body)
    assert r.status == 400
    assert (await client.get(f"/overlays/{ts}")).status == 404   # nothing written


@pytest.mark.parametrize("body", [{"text": 5}, {"text": "hi", "voice": ["a"]}])
async def test_render_wrong_types_are_400(client, body):
    r = await client.post("/render", json=body)
    assert r.status == 400


async def test_overlays_get_missing_returns_404(client):
    r = await client.get("/overlays/never")
    assert r.status == 404


async def test_overlays_title_round_trip_and_inherit(client, isolated_paths):
    ts = "2026-05-31T12:33:14Z"
    _seed(client, ts)
    r = await client.post(f"/overlays/{ts}", json={"title": "One Machine, Two Minds"})
    assert r.status == 200
    assert (await r.json())["title"] == "One Machine, Two Minds"
    # title persists across a partial update that doesn't pass it
    r2 = await client.post(f"/overlays/{ts}", json={"starred": True})
    assert (await r2.json())["title"] == "One Machine, Two Minds"
    # surfaced on the history row's overlay
    state = client.server.app[STATE_KEY]
    state.record_history({"ts": ts, "backend": "qwen3"})
    h = await client.get("/history?limit=5")
    entry = next(e for e in (await h.json())["entries"] if e["ts"] == ts)
    assert entry["overlay"]["title"] == "One Machine, Two Minds"


async def test_overlays_removed_tags_round_trip(client, isolated_paths):
    ts = "2026-05-29T09:00:00Z"
    _seed(client, ts)
    # Suppress a tag (e.g. a server/render-time tag the app "deleted").
    r = await client.post(f"/overlays/{ts}", json={"removed_tags": ["Daily Notes", "x"]})
    assert r.status == 200
    body = await r.json()
    # normalized like tags: "Daily Notes" → "daily-notes"
    assert body["removed_tags"] == ["daily-notes", "x"]
    # inherited across a partial update (latest-wins per field)
    r2 = await client.post(f"/overlays/{ts}", json={"starred": True})
    assert (await r2.json())["removed_tags"] == ["daily-notes", "x"]
    g = await client.get(f"/overlays/{ts}")
    assert (await g.json())["removed_tags"] == ["daily-notes", "x"]


async def test_history_includes_overlay(client, isolated_paths):
    state = client.server.app[STATE_KEY]
    state.record_history({"ts": "h-x", "backend": "kokoro"})
    await client.post("/overlays/h-x", json={"starred": True})
    r = await client.get("/history?limit=5")
    body = await r.json()
    entry = next(e for e in body["entries"] if e["ts"] == "h-x")
    assert entry["overlay"]["starred"] is True


async def test_deep_health_probes_backends(client, monkeypatch):
    """`/health?deep=1` runs a connectivity check against each backend."""
    import httpx as httpx_mod

    async def fake_get(self, url, **kw):
        # All real ports return ConnectError; we want our handler to
        # surface those as "down" without raising.
        raise httpx_mod.ConnectError("refused")

    monkeypatch.setattr(httpx_mod.AsyncClient, "get", fake_get)
    r = await client.get("/health?deep=1")
    assert r.status == 200
    body = await r.json()
    assert body["status"] == "ok"
    assert set(body["backends"].keys()) == {"tts-a", "tts-b"}
    assert all(v == "down" for v in body["backends"].values())


async def test_config_endpoint(client):
    r = await client.get("/config")
    assert r.status == 200
    body = await r.json()
    assert body["say_threshold_chars"] == engine.config.SAY_THRESHOLD_CHARS
    assert "version" in body
    assert isinstance(body["backends"], list)
    # Every backend carries its service descriptor for the app's on/off toggle.
    kinds = {b["id"]: (b.get("service") or {}).get("kind") for b in body["backends"]}
    assert kinds == {"tts-a": "launchd", "tts-b": "launchd"}
    # One model id on two ports; the url form and the host + port form agree.
    by_id = {b["id"]: b for b in body["backends"]}
    assert {b["model"] for b in by_id.values()} == {"tts-model"}
    assert (by_id["tts-a"]["url"], by_id["tts-a"]["port"]) == ("http://127.0.0.1:9101", 9101)
    assert (by_id["tts-b"]["url"], by_id["tts-b"]["port"]) == ("http://127.0.0.1:9102", 9102)


@pytest.fixture
def writable_config(tmp_path, monkeypatch):
    """Point config.write_local/reload at a throwaway config.local.toml and
    snapshot the runtime-mutable globals so a POST /config in one test never
    bleeds into another (config module state is process-global)."""
    import voice_say.config as cfg
    cfgfile = tmp_path / "config.local.toml"
    monkeypatch.setenv("VOICE_SAY_CONFIG", str(cfgfile))
    for name in ("DEFAULT_BACKEND", "DEFAULT_VOICE"):
        monkeypatch.delenv(f"VOICE_SAY_{name}", raising=False)
        monkeypatch.delenv(f"SAY_MCP_{name}", raising=False)
    orig = (cfg.DEFAULT_BACKEND, cfg.DEFAULT_VOICE, cfg._FILE)
    cfg.reload()
    yield cfgfile
    cfg.DEFAULT_BACKEND, cfg.DEFAULT_VOICE, cfg._FILE = orig


async def test_config_post_persists_and_reloads(client, writable_config):
    r = await client.post("/config", json={"default_backend": "tts-b"})
    assert r.status == 200
    body = await r.json()
    assert body["default_backend"] == "tts-b"
    # persisted to disk …
    assert "tts-b" in writable_config.read_text()
    # … and live for the next GET (no restart).
    g = await (await client.get("/config")).json()
    assert g["default_backend"] == "tts-b"


async def test_config_post_unknown_backend_400(client, writable_config):
    r = await client.post("/config", json={"default_backend": "nope"})
    assert r.status == 400
    assert not writable_config.exists()  # nothing written on a rejected request


async def test_config_post_unadvertised_voice_accepted(client, writable_config):
    # Voice is NOT validated against the advertised list — /render passes it
    # through, so a cloned voice not in the generic catalog is allowed.
    r = await client.post("/config", json={
        "default_backend": "tts-a", "default_voice": "my_clone"})
    assert r.status == 200
    body = await r.json()
    assert body["default_voice"] == "my_clone"


async def test_config_post_nonstring_voice_400(client, writable_config):
    r = await client.post("/config", json={
        "default_backend": "tts-a", "default_voice": 123})
    assert r.status == 400


async def test_config_post_clear_voice(client, writable_config):
    r = await client.post("/config", json={
        "default_backend": "tts-a", "default_voice": ""})
    assert r.status == 200
    body = await r.json()
    assert body["default_voice"] is None


async def test_config_post_no_writable_keys_400(client, writable_config):
    # A body with no recognized writable key → 400. (say_threshold_chars IS
    # writable now — see test_config_post_say_threshold — so use a bogus key.)
    r = await client.post("/config", json={"not_a_real_key": 99})
    assert r.status == 400


async def test_config_post_say_threshold(client, writable_config):
    # say_threshold_chars is runtime-mutable via POST /config: the write is
    # accepted (200) and the LIVE value is echoed back (reload() refreshed it).
    r = await client.post("/config", json={"say_threshold_chars": 99})
    assert r.status == 200
    body = await r.json()
    assert body["say_threshold_chars"] == 99


async def test_progress_get_missing_returns_404(client):
    r = await client.get("/progress/never-written")
    assert r.status == 404
    body = await r.json()
    assert body["error"] == "not_found"


async def test_progress_post_then_get_round_trip(client):
    ts = "2026-05-25T05:00:00Z"
    _seed(client, ts)
    r = await client.post(f"/progress/{ts}", json={
        "played_s": 12.5, "duration_s": 90.0, "started": True,
    })
    assert r.status == 200
    body = await r.json()
    assert body["played_s"] == 12.5
    assert body["play_count"] == 1

    r2 = await client.get(f"/progress/{ts}")
    assert r2.status == 200
    body2 = await r2.json()
    assert body2["played_s"] == 12.5
    assert body2["duration_s"] == 90.0


async def test_progress_post_missing_played_s_returns_400(client):
    _seed(client, "ts-x")
    r = await client.post("/progress/ts-x", json={"duration_s": 10.0})
    assert r.status == 400


async def test_progress_post_bad_value_returns_400(client):
    _seed(client, "ts-y")
    r = await client.post("/progress/ts-y", json={"played_s": -5.0})
    assert r.status == 400


async def test_history_served_from_cache_not_disk(client, isolated_paths, monkeypatch):
    """After startup, /history must not re-scan the db.
    Asserting via a spy on engine.read_history."""
    import voice_say.engine as eng
    real = eng.read_history
    call_count = {"n": 0}

    def spy(*a, **kw):
        call_count["n"] += 1
        return real(*a, **kw)

    monkeypatch.setattr(eng, "read_history", spy)

    # First call after startup: cache already hydrated; should serve from RAM.
    r = await client.get("/history?limit=5")
    assert r.status == 200
    assert call_count["n"] == 0, "history_handler hit disk instead of cache"


async def test_progress_post_lands_in_cache_immediately(client, isolated_paths):
    """POST /progress → GET /history reflects the new progress without disk read."""
    # Seed a render row directly into the db (matches engine.render's insert).
    _db.insert_render({
        "ts": "2026-05-25T10:00:00Z", "kind": "say", "backend": "kokoro",
        "voice": "af_alloy", "speed": 1.0, "format": "mp3",
        "chars": 5, "words": 1, "duration_s": 0.0, "bytes": 100,
        "archive_name": "x.mp3", "archive_path": "/tmp/x.mp3",
        "text": "hello", "tags": [],
    })
    # Rebuild the app state to pick up the seeded row.
    state = client.server.app[STATE_KEY]
    state.history.clear()
    state.progress.clear()
    state.load_from_disk()

    await client.post("/progress/2026-05-25T10:00:00Z", json={
        "played_s": 33.3, "duration_s": 99.0, "started": True,
    })
    r = await client.get("/history?limit=5")
    body = await r.json()
    assert body["entries"][0]["progress"]["played_s"] == 33.3


async def _consume_events(resp, n: int, timeout: float = 1.0) -> list[dict]:
    """Read N complete SSE events from the response, parse the data lines."""
    import asyncio, json as _json
    events: list[dict] = []
    buf = b""
    async def _reader():
        nonlocal buf
        while len(events) < n:
            chunk = await resp.content.read(1024)
            if not chunk:
                break
            buf += chunk
            while b"\n\n" in buf:
                raw, buf = buf.split(b"\n\n", 1)
                data_line = next((ln for ln in raw.splitlines()
                                  if ln.startswith(b"data: ")), None)
                if data_line:
                    events.append(_json.loads(data_line[len(b"data: "):]))
                if len(events) >= n:
                    return
    await asyncio.wait_for(_reader(), timeout=timeout)
    return events


async def test_events_emits_snapshot_on_connect(client, isolated_paths):
    state = client.server.app[STATE_KEY]
    state.record_history({"ts": "snap-1", "backend": "kokoro"})
    async with client.get("/events") as resp:
        assert resp.status == 200
        assert "text/event-stream" in resp.headers["Content-Type"]
        events = await _consume_events(resp, n=1)
    assert events[0]["type"] == "snapshot"
    assert any(e["ts"] == "snap-1" for e in events[0]["history"])


async def test_events_streams_live_render(client, isolated_paths):
    state = client.server.app[STATE_KEY]
    async with client.get("/events") as resp:
        # drain snapshot
        await _consume_events(resp, n=1)
        # broadcast a render
        state.record_history({"ts": "live-1", "backend": "kokoro"})
        events = await _consume_events(resp, n=1)
    assert events[0]["type"] == "render"
    assert events[0]["ts"] == "live-1"


async def test_events_resume_with_last_event_id(client, isolated_paths):
    state = client.server.app[STATE_KEY]
    # seq 1, 2, 3
    state.record_history({"ts": "h1", "backend": "kokoro"})
    state.record_history({"ts": "h2", "backend": "kokoro"})
    state.record_progress({"ts": "h1", "played_s": 5.0})

    async with client.get("/events", headers={"Last-Event-ID": "1"}) as resp:
        events = await _consume_events(resp, n=2)
    # Should get seq 2 (render h2) and seq 3 (progress h1)
    assert [ev["id"] for ev in events] == [2, 3]


async def test_events_ids_carry_the_daemon_instance(client, isolated_paths):
    """The SSE id line is `<instance_id>-<seq>`; echoing it resumes."""
    import asyncio
    state = client.server.app[STATE_KEY]
    state.record_history({"ts": "h1", "backend": "kokoro"})   # seq 1
    async with client.get("/events", headers={"Last-Event-ID": "0"}) as resp:
        raw = await asyncio.wait_for(resp.content.readuntil(b"\n\n"), 1.0)
    assert raw.splitlines()[0] == f"id: {state.instance_id}-1".encode()
    state.record_history({"ts": "h2", "backend": "kokoro"})   # seq 2
    resume = f"{state.instance_id}-1"
    async with client.get("/events", headers={"Last-Event-ID": resume}) as resp:
        events = await _consume_events(resp, n=1)
    assert [(ev["type"], ev["id"]) for ev in events] == [("render", 2)]


async def test_events_id_from_an_earlier_daemon_gets_a_snapshot(client, isolated_paths):
    """After a restart the new process's seq passes the client's old id: a
    replay from that id would skip the new process's first events, so an id
    from another instance gets a snapshot."""
    state = client.server.app[STATE_KEY]
    for i in range(3):
        state.record_history({"ts": f"new-{i}", "backend": "kokoro"})
    async with client.get("/events", headers={"Last-Event-ID": "0123abcd-2"}) as resp:
        events = await _consume_events(resp, n=1)
    assert events[0]["type"] == "snapshot"
    assert {e["ts"] for e in events[0]["history"]} >= {"new-0", "new-1", "new-2"}


async def test_reload_picks_up_external_history_append(client, isolated_paths):
    """POST /reload after an external db write must surface the new
    row in /history without restarting the daemon (no launchctl kickstart needed).
    """
    # Production invariant: every row in the in-memory cache also exists
    # in the db (engine.render inserts the row, then calls record_history).
    # Mirror that here: insert a row into the db AND seed the cache.
    row_a = {
        "ts": "2026-05-26T05:00:00Z", "kind": "say", "backend": "kokoro",
        "voice": "af_alloy", "speed": 1.0, "format": "mp3",
        "chars": 5, "words": 1, "duration_s": 0.0, "bytes": 100,
        "archive_name": "a.mp3", "archive_path": "/tmp/a.mp3",
        "text": "x", "tags": [],
    }
    _db.insert_render(row_a)
    state = client.server.app[STATE_KEY]
    state.record_history(row_a)

    # External write by another process (simulates register-fn.sh).
    # Daemon's cache is unaware — VoiceSay wouldn't see it until reload.
    row_b = {
        "ts": "2026-05-26T06:00:00Z", "kind": "render", "backend": "qwen3",
        "voice": "af_alloy", "speed": 1.0, "format": "mp3",
        "chars": 5, "words": 1, "duration_s": 0.0, "bytes": 100,
        "archive_name": "ep-99-qwen3.mp3",
        "archive_path": "/tmp/ep-99-qwen3.mp3",
        "text": "y", "tags": ["qwen3-rerender"],
    }
    _db.insert_render(row_b)

    # Pre-reload: /history shows only the cached row, NOT the appended
    # one — proves the bug the fix addresses is real.
    r0 = await client.get("/history?limit=10")
    pre = await r0.json()
    pre_ts = {e["ts"] for e in pre["entries"]}
    assert "2026-05-26T05:00:00Z" in pre_ts
    assert "2026-05-26T06:00:00Z" not in pre_ts

    # Reload.
    r1 = await client.post("/reload")
    assert r1.status == 200
    body = await r1.json()
    assert body["ok"] is True
    assert body["counts"]["history"] == 2

    # Post-reload: appended row is now visible.
    r2 = await client.get("/history?limit=10")
    post = await r2.json()
    post_ts = {e["ts"] for e in post["entries"]}
    assert "2026-05-26T06:00:00Z" in post_ts
    assert "2026-05-26T05:00:00Z" in post_ts


async def test_search_endpoint_returns_fts_hits(client, isolated_paths):
    """GET /search?q= runs an FTS5 transcript search and returns matching
    rows in {entries, total}, merged with progress/overlay like /history."""
    _db.insert_render({
        "ts": "2026-05-28T08:00:00Z", "kind": "render", "backend": "qwen3",
        "voice": "af_alloy", "speed": 1.0, "format": "mp3",
        "chars": 9, "words": 1, "duration_s": 0.0, "bytes": 100,
        "archive_name": "quokka.mp3", "archive_path": "/tmp/quokka.mp3",
        "text": "the quokkaword appears here", "tags": [],
    })
    r = await client.get("/search?q=quokkaword")
    assert r.status == 200
    body = await r.json()
    hit_ts = {e["ts"] for e in body["entries"]}
    assert "2026-05-28T08:00:00Z" in hit_ts


async def test_audio_endpoint_streams_bytes_for_known_ts(client, isolated_paths, tmp_path):
    """GET /audio/{ts} resolves a cached entry's archive_path and streams
    the file with the right mime type. This is what the MCP audio://
    resource calls now (post-2026-05-27); remote MCP clients no longer
    need disk co-location."""
    audio_bytes = b"\xff\xfb\x90\x00" + b"\x00" * 256
    # File must live inside ARCHIVE_ROOT to pass the path-traversal guard.
    archive_subdir = isolated_paths["archive"] / "2026" / "05"
    archive_subdir.mkdir(parents=True, exist_ok=True)
    audio_file = archive_subdir / "voice-x.mp3"
    audio_file.write_bytes(audio_bytes)

    state = client.server.app[STATE_KEY]
    state.record_history({
        "ts": "2026-05-27T10:00:00Z", "kind": "render", "backend": "qwen3",
        "voice": "af_alloy", "speed": 1.0, "format": "mp3",
        "chars": 10, "words": 2, "duration_s": 0, "bytes": len(audio_bytes),
        "archive_name": "voice-x.mp3", "archive_path": str(audio_file),
        "text": "hello", "tags": [],
    })

    r = await client.get("/audio/2026-05-27T10:00:00Z")
    assert r.status == 200
    assert r.headers["Content-Type"] == "audio/mpeg"
    body = await r.read()
    assert body == audio_bytes


async def test_audio_endpoint_404_for_unknown_ts(client, isolated_paths):
    r = await client.get("/audio/never-rendered")
    assert r.status == 404
    body = await r.json()
    assert body["error"] == "not_found"


async def test_audio_endpoint_403_when_path_escapes_archive_root(client, isolated_paths, tmp_path):
    """Path-traversal guard backported from the public bundle. A history
    row whose archive_path resolves outside ARCHIVE_ROOT (e.g. seeded by
    a poisoned db) must be refused with 403, not served."""
    rogue = tmp_path / "rogue.mp3"
    rogue.write_bytes(b"not in archive root")
    state = client.server.app[STATE_KEY]
    state.record_history({
        "ts": "2026-05-27T13:00:00Z", "kind": "render", "backend": "qwen3",
        "voice": "af_alloy", "speed": 1.0, "format": "mp3",
        "chars": 1, "words": 1, "duration_s": 0, "bytes": 100,
        "archive_name": "rogue.mp3",
        "archive_path": str(rogue),
        "text": "x", "tags": [],
    })
    r = await client.get("/audio/2026-05-27T13:00:00Z")
    assert r.status == 403
    body = await r.json()
    assert body["error"] == "forbidden"


async def test_audio_endpoint_404_when_file_missing(client, isolated_paths):
    """Cache entry exists with a path INSIDE ARCHIVE_ROOT but the file
    was cold-tiered/deleted — return 404 with a distinct `archived`
    error. (Path inside ARCHIVE_ROOT to pass the path-traversal guard;
    the missing-file check is what we're exercising.)"""
    # Construct a path inside ARCHIVE_ROOT that won't exist on disk.
    archive_subdir = isolated_paths["archive"] / "2026" / "05"
    archive_subdir.mkdir(parents=True, exist_ok=True)
    missing_path = archive_subdir / "does-not-exist.mp3"
    state = client.server.app[STATE_KEY]
    state.record_history({
        "ts": "2026-05-27T11:00:00Z", "kind": "render", "backend": "qwen3",
        "voice": "af_alloy", "speed": 1.0, "format": "mp3",
        "chars": 5, "words": 1, "duration_s": 0, "bytes": 100,
        "archive_name": "does-not-exist.mp3",
        "archive_path": str(missing_path),
        "text": "gone", "tags": [],
    })
    r = await client.get("/audio/2026-05-27T11:00:00Z")
    assert r.status == 404
    body = await r.json()
    assert body["error"] == "archived"


async def test_history_includes_progress_field(client, isolated_paths):
    # Seed via cache (mirrors how engine.render would call the hook after
    # inserting the row). The db row would also be present in prod.
    state = client.server.app[STATE_KEY]
    state.record_history({
        "ts": "2026-05-25T06:00:00Z", "kind": "render", "backend": "kokoro",
        "voice": "af_alloy", "speed": 1.0, "format": "mp3",
        "chars": 10, "words": 2, "duration_s": 0, "bytes": 100,
        "archive_name": "voice-x.mp3", "archive_path": "/tmp/voice-x.mp3",
        "text": "hello", "tags": [],
    })

    # No progress yet — entry.progress should be null
    r = await client.get("/history?limit=5")
    body = await r.json()
    assert len(body["entries"]) == 1
    assert body["entries"][0]["progress"] is None

    # Post progress, then fetch again
    await client.post("/progress/2026-05-25T06:00:00Z", json={
        "played_s": 5.0, "duration_s": 30.0, "started": True,
    })
    r2 = await client.get("/history?limit=5")
    body2 = await r2.json()
    prog = body2["entries"][0]["progress"]
    assert prog is not None
    assert prog["played_s"] == 5.0
    assert prog["duration_s"] == 30.0
    assert prog["play_count"] == 1


# --- /episode/* control routes (error-envelope wiring) ------------------------
# The play-while-render redesign added five POST routes; these lock the
# HTTP-layer contract (status + {"error": ...} envelope) that the EpisodeRegistry
# unit tests don't reach. Deterministic — no live render required.

async def test_episode_cancel_unknown_returns_404(client):
    r = await client.post("/episode/no-such-id/cancel")
    assert r.status == 404
    assert (await r.json())["error"] == "not_found"


async def test_episode_finalize_unknown_returns_404(client):
    r = await client.post("/episode/no-such-id/finalize")
    assert r.status == 404
    assert (await r.json())["error"] == "not_found"


async def test_episode_force_finalize_unknown_returns_404(client):
    r = await client.post("/episode/no-such-id/force_finalize")
    assert r.status == 404
    assert (await r.json())["error"] == "not_found"


async def test_episode_resume_missing_from_ts_returns_400(client):
    r = await client.post("/episode/resume", json={})
    assert r.status == 400
    assert (await r.json())["error"] == "request"


async def test_episode_resume_conflict_returns_409(client):
    # Claim an in-flight resume for this draft; the second resume must 409
    # before any render work (begin_resume returns False on re-entry).
    state = client.server.app[STATE_KEY]
    assert state.episodes.begin_resume("ts-resume-x") is True
    r = await client.post("/episode/resume", json={"from_ts": "ts-resume-x"})
    assert r.status == 409
    assert (await r.json())["error"] == "conflict"


async def test_bad_json_error_is_valid_json_with_quotes():
    class _Req:
        async def json(self):
            raise ValueError('bad "quoted" \\ input')
    with pytest.raises(web.HTTPBadRequest) as exc:
        await parse_json(_Req())
    body = json.loads(exc.value.text)   # was an f-string: quotes broke it
    assert body == {"error": "request", "message": 'bad JSON: bad "quoted" \\ input'}


async def test_render_route_cap_follows_config(client, monkeypatch):
    monkeypatch.setattr(config, "MAX_RENDER_CHARS", 50)
    r = await client.post("/render", json={"text": "x" * 51, "backend": "tts-a"})
    assert r.status == 413
    assert "50 limit" in (await r.json())["message"]


# --- POST /backends/{backend}/restart ------------------------------------------

class _FakeProc:
    def __init__(self, rc=0, err=b""):
        self.returncode, self._err = rc, err

    async def communicate(self):
        return b"", self._err


async def test_backend_restart_kickstarts_the_catalog_label(client, monkeypatch):
    """The daemon runs launchctl on the backend's catalog label, then reports up."""
    import os
    import httpx as httpx_mod
    from voice_say import _routes_meta
    calls = []

    async def fake_exec(*args, **kw):
        calls.append(args)
        return _FakeProc()

    async def fake_get(self, url, **kw):
        return type("R", (), {"status_code": 200})()

    monkeypatch.setattr(_routes_meta.asyncio, "create_subprocess_exec", fake_exec)
    monkeypatch.setattr(httpx_mod.AsyncClient, "get", fake_get)
    r = await client.post("/backends/tts-a/restart")
    assert r.status == 200, await r.text()
    body = await r.json()
    assert body["restarted"] is True and body["up"] is True
    assert body["label"] == "local.voicesay.tts-a"
    assert calls == [("launchctl", "kickstart", "-k", f"gui/{os.getuid()}/local.voicesay.tts-a")]


async def test_backend_restart_refuses_unknown_and_busy(client, monkeypatch):
    """Only catalog ids; never while a render runs or waits (launchctl untouched)."""
    from voice_say import _routes_meta
    calls = []

    async def fake_exec(*args, **kw):
        calls.append(args)
        return _FakeProc()

    monkeypatch.setattr(_routes_meta.asyncio, "create_subprocess_exec", fake_exec)
    assert (await client.post("/backends/nope/restart")).status == 404
    # A plain /render holds only the backend's lock: no episode, nothing waiting.
    async with engine._GATE.tts("tts-a"):
        r = await client.post("/backends/tts-a/restart")
    assert r.status == 409 and (await r.json())["error"] == "busy"
    assert calls == []


async def test_backend_restart_reports_launchctl_failure(client, monkeypatch):
    from voice_say import _routes_meta

    async def fake_exec(*args, **kw):
        return _FakeProc(rc=1, err=b"Operation not permitted")

    monkeypatch.setattr(_routes_meta.asyncio, "create_subprocess_exec", fake_exec)
    r = await client.post("/backends/tts-a/restart")
    assert r.status == 502 and "Operation not permitted" in (await r.json())["message"]


# --- voices a server lists itself (GET /v1/audio/voices) ----------------------

@pytest.fixture
def listing_catalog(monkeypatch, catalog):
    """`tts-a` plus `tts-c`, an entry that leaves `voices` out."""
    specs = {**{bid: {"url": b.base_url, "model": b.model, "voices": list(b.voices)}
                for bid, b in catalog.items()},
             "tts-c": {"url": "http://127.0.0.1:9103", "model": "org/model"}}
    monkeypatch.setattr(config, "load_backends", lambda: specs)
    monkeypatch.setattr(engine, "BACKENDS", engine._build_backends())
    monkeypatch.setattr(engine, "_listed_voices", {})
    monkeypatch.setattr(engine, "_unlisted", set())


def _fake_voices(monkeypatch, status, voices=()):
    import httpx as httpx_mod
    asked = []

    async def fake_get(self, url, params=None, **kw):
        asked.append((url, params))
        return httpx_mod.Response(status, json={"object": "list",
                                                "data": [{"id": v, "name": v} for v in voices]},
                                  request=httpx_mod.Request("GET", url))
    monkeypatch.setattr(httpx_mod.AsyncClient, "get", fake_get)
    return asked


async def test_voices_come_from_the_server_when_the_entry_lists_none(client, listing_catalog, monkeypatch):
    asked = _fake_voices(monkeypatch, 200, ["af_heart", "bm_george"])
    body = await (await client.get("/config")).json()
    voices = {b["id"]: b["voices"] for b in body["backends"]}
    assert voices == {"tts-a": ["v1"], "tts-b": [], "tts-c": ["af_heart", "bm_george"]}
    # only the entry without a `voices` key was asked, with its model id
    assert asked == [("http://127.0.0.1:9103/v1/audio/voices", {"model": "org/model"})]
    r = await client.get("/voices/tts-c")
    assert (await r.json())["voices"] == ["af_heart", "bm_george"]
    assert len(asked) == 1          # cached


async def test_a_server_that_answers_a_bare_list_of_voices(client, listing_catalog, monkeypatch):
    import httpx as httpx_mod

    async def fake_get(self, url, params=None, **kw):
        return httpx_mod.Response(200, json=[{"id": "af_heart"}, {"id": "bm_george"}],
                                  request=httpx_mod.Request("GET", url))
    monkeypatch.setattr(httpx_mod.AsyncClient, "get", fake_get)
    r = await client.get("/config")
    assert r.status == 200
    voices = {b["id"]: b["voices"] for b in (await r.json())["backends"]}
    assert voices["tts-c"] == ["af_heart", "bm_george"]


async def test_a_server_that_does_not_list_voices_is_asked_once(client, listing_catalog, monkeypatch):
    asked = _fake_voices(monkeypatch, 404)
    await client.get("/config")
    monkeypatch.setattr(engine, "_VOICES_RETRY_S", 0.0)
    await client.get("/config")
    r = await client.get("/voices/tts-c")
    assert r.status == 200 and (await r.json())["voices"] == []
    assert len(asked) == 1


async def test_a_server_not_up_yet_is_asked_on_the_next_request(client, listing_catalog, monkeypatch):
    """Daemon and backend started together: the startup ask is refused, and the
    first `voice-say voices` must not get an empty list for the next minute."""
    import httpx as httpx_mod
    up = False

    async def get(self, url, params=None, **kw):
        if not up:
            raise httpx_mod.ConnectError("refused")
        return httpx_mod.Response(200, json={"data": [{"id": "af_heart"}]},
                                  request=httpx_mod.Request("GET", url))
    monkeypatch.setattr(httpx_mod.AsyncClient, "get", get)
    await client.get("/config")
    up = True
    r = await client.get("/voices/tts-c")
    assert (await r.json())["voices"] == ["af_heart"]


async def test_a_server_that_times_out_is_asked_again_later(client, listing_catalog, monkeypatch):
    import httpx as httpx_mod
    calls = []

    async def slow(self, url, **kw):
        calls.append(url)
        raise httpx_mod.ReadTimeout("slow")
    monkeypatch.setattr(httpx_mod.AsyncClient, "get", slow)
    await client.get("/config")
    await client.get("/config")
    assert len(calls) == 1          # inside the retry window
    monkeypatch.setattr(engine, "_VOICES_RETRY_S", 0.0)
    await client.get("/config")
    assert len(calls) == 2
    assert (await client.get("/voices/nope")).status == 404
