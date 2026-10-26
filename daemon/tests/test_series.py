"""Series + episode numbers: stored on the overlay, set with a render or
POST /overlays, cleared with null, and GET /history?series= lists a series in
episode order. The overlays table migrates on an old db."""
from __future__ import annotations

import sqlite3

import pytest
from aiohttp.test_utils import TestClient, TestServer

from voice_say import _db, engine
from voice_say.http_server import STATE_KEY, build_app


@pytest.fixture
async def client(isolated_paths):
    async with TestClient(TestServer(build_app())) as cli:
        yield cli


def _row(cli, ts: str) -> None:
    cli.server.app[STATE_KEY].record_history({"ts": ts, "backend": "tts-local", "text": ts})


async def test_series_in_episode_order_not_render_order(client):
    for ts, ep in [("2026-01-03T00:00:00Z", 2), ("2026-01-01T00:00:00Z", 10),
                   ("2026-01-02T00:00:00Z", 1), ("2026-01-04T00:00:00Z", None)]:
        _row(client, ts)
        body = {"series": "Daily Notes"} | ({"episode": ep} if ep is not None else {})
        assert (await client.post(f"/overlays/{ts}", json=body)).status == 200
    _row(client, "2026-01-05T00:00:00Z")                       # not in the series
    await client.post("/overlays/2026-01-05T00:00:00Z", json={"series": "Other", "episode": 0})
    r = await client.get("/history", params={"series": "daily notes"})
    got = [(e["overlay"]["episode"]) for e in (await r.json())["entries"]]
    assert got == [1, 2, 10, None]                              # unnumbered last
    r = await client.get("/history", params={"series": " Daily   Notes "})
    assert len((await r.json())["entries"]) == 4                # spacing as stored


async def test_deleted_rows_drop_out_and_null_clears(client):
    ts = "2026-01-01T00:00:00Z"
    _row(client, ts)
    await client.post(f"/overlays/{ts}", json={"series": "S", "episode": 3, "title": "T"})
    r = await client.post(f"/overlays/{ts}", json={"starred": True})       # partial update
    assert (await r.json())["episode"] == 3                                 # kept
    r = await client.post(f"/overlays/{ts}", json={"episode": None})
    assert (await r.json())["episode"] is None and (await r.json())["series"] == "S"
    await client.post(f"/overlays/{ts}", json={"deleted": True})
    r = await client.get("/history", params={"series": "S"})
    assert (await r.json())["entries"] == []


@pytest.mark.parametrize("bad", [-1, 1.5, "x", True, "inf", "nan", float("inf"), 10**12])
async def test_bad_episode_is_a_400(client, bad):
    _row(client, "2026-01-01T00:00:00Z")
    r = await client.post("/overlays/2026-01-01T00:00:00Z", json={"episode": bad})
    assert r.status == 400


async def test_render_sets_title_series_episode(client, monkeypatch):
    async def fake_render(text, **_kw):
        return {"ts": "2026-02-01T00:00:00Z", "archive_name": "a.mp3", "chars": 2,
                "backend": "tts-local", "voice": "v"}
    monkeypatch.setattr(engine, "render", fake_render)
    r = await client.post("/render", json={"text": "hi", "title": "Ep 4",
                                           "series": "Daily Notes", "episode": "4"})
    body = await r.json()
    assert r.status == 200
    assert body["overlay"]["title"] == "Ep 4"
    assert (body["overlay"]["series"], body["overlay"]["episode"]) == ("Daily Notes", 4)
    r = await client.post("/render", json={"text": "hi", "episode": -2})
    assert r.status == 400                                      # refused before rendering


async def test_old_overlays_table_migrates(tmp_path):
    db = tmp_path / "old.db"
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE overlays (ts TEXT PRIMARY KEY, starred INTEGER, deleted INTEGER,"
                " tags TEXT, removed_tags TEXT, bookmarks TEXT, last_modified TEXT)")
    con.execute("INSERT INTO overlays (ts, starred) VALUES ('t', 1)")
    con.commit()
    con.close()
    _db.connect(db)
    try:
        _db.init_schema()
        row = _db.read_overlay("t")
        assert row["starred"] and row["series"] is None and row["episode"] is None
    finally:
        _db.close()


async def test_longform_streams_by_default_and_stamps_client_ref(client, monkeypatch):
    """Every longform render (agent, CLI, app) shows live in the app; only the
    sender's own episode_start carries its client_ref."""
    seen: dict = {}

    async def fake_longform(text, *, mode, on_episode_event, **_kw):
        seen["mode"] = mode
        on_episode_event({"type": "episode_start", "episode_id": "e1"})
        on_episode_event({"type": "chunk_ready", "episode_id": "e1"})
        return {"ts": "2026-02-02T00:00:00Z", "archive_name": "a.mp3", "chars": 2,
                "backend": "tts-local", "voice": "v"}
    monkeypatch.setattr(engine, "render_longform", fake_longform)
    sent: list = []
    monkeypatch.setattr(client.server.app[STATE_KEY], "broadcast", sent.append)

    assert (await client.post("/render_longform", json={"text": "hi"})).status == 200
    assert seen["mode"] == "stream" and "client_ref" not in sent[0]
    sent.clear()
    await client.post("/render_longform", json={"text": "hi", "client_ref": "job-7"})
    assert sent[0]["client_ref"] == "job-7" and "client_ref" not in sent[1]


async def test_episode_start_carries_title_series_episode(client, monkeypatch):
    """A live render shows what it is before its row exists: episode_start
    carries the request's title / series / episode (only those set); the other
    episode events don't, and a request without them keeps the old payload."""
    async def fake_longform(text, *, on_episode_event, **_kw):
        on_episode_event({"type": "episode_start", "episode_id": "e1"})
        on_episode_event({"type": "chunk_ready", "episode_id": "e1"})
        return {"ts": "2026-02-03T00:00:00Z", "archive_name": "a.mp3", "chars": 2,
                "backend": "tts-local", "voice": "v"}
    monkeypatch.setattr(engine, "render_longform", fake_longform)
    sent: list = []
    monkeypatch.setattr(client.server.app[STATE_KEY], "broadcast", sent.append)

    await client.post("/render_longform", json={"text": "hi", "title": "Ep 181",
                                                "series": "Daily Notes", "episode": 181})
    assert (sent[0]["title"], sent[0]["series"], sent[0]["episode"]) == ("Ep 181", "Daily Notes", 181)
    assert not {"title", "series", "episode"} & sent[1].keys()
    sent.clear()
    await client.post("/render_longform", json={"text": "hi", "series": "S", "episode": 0})
    assert (sent[0]["series"], sent[0]["episode"]) == ("S", 0) and "title" not in sent[0]
    sent.clear()
    await client.post("/render_longform", json={"text": "hi"})
    assert sent[0] == {"type": "episode_start", "episode_id": "e1"}


async def test_resume_episode_start_carries_the_drafts_title(client, monkeypatch):
    ts = "2026-02-04T00:00:00Z"
    _row(client, ts)
    await client.post(f"/overlays/{ts}", json={"title": "Draft T", "series": "S", "episode": 2})

    async def fake_resume(draft_ts, *, on_episode_event, **_kw):
        on_episode_event({"type": "episode_start", "episode_id": "e2"})
        return {"ts": "2026-02-05T00:00:00Z", "archive_name": "a.mp3", "chars": 2,
                "backend": "tts-local", "voice": "v"}
    monkeypatch.setattr(engine, "resume_longform", fake_resume)
    sent: list = []
    monkeypatch.setattr(client.server.app[STATE_KEY], "broadcast", sent.append)

    assert (await client.post("/episode/resume", json={"from_ts": ts})).status == 200
    assert (sent[0]["title"], sent[0]["series"], sent[0]["episode"]) == ("Draft T", "S", 2)
