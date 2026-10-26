"""Lifetime totals and kept scripts: the totals only ever grow, so deleting
recordings (rows or audio) never lowers them, and a deleted row's transcript
survives in deleted_scripts. Also GET /stats."""
from __future__ import annotations

import json

import pytest
from aiohttp.test_utils import TestClient, TestServer

import voice_say._db as _db
from voice_say.http_server import build_app


def _entry(ts: str, *, chars: int = 10, words: int = 2, duration_s: float = 3.0,
           bytes_: int = 1000, path: str | None = None) -> dict:
    return {
        "ts": ts, "kind": "render", "backend": "tts-local", "voice": "v",
        "speed": 1.0, "format": "mp3", "chars": chars, "words": words,
        "duration_s": duration_s, "bytes": bytes_, "archive_name": "a.mp3",
        "archive_path": path, "text": f"script {ts}", "tags": ["t"],
    }


@pytest.fixture
async def client(isolated_paths):
    async with TestClient(TestServer(build_app())) as cli:
        yield cli


def test_lifetime_counts_every_insert(isolated_paths):
    assert _db.lifetime()["renders"] == 0
    _db.insert_render(_entry("2026-06-01T00:00:00Z"))
    _db.insert_render(_entry("2026-06-02T00:00:00Z", chars=5, duration_s=1.5))
    lt = _db.lifetime()
    assert (lt["renders"], lt["chars"], lt["words"], lt["duration_s"], lt["bytes"]) \
        == (2, 15, 4, 4.5, 2000)
    assert lt["since"] == "2026-06-01T00:00:00Z"


def test_deleting_a_row_keeps_totals_and_script(isolated_paths):
    ts = "2026-06-01T00:00:00Z"
    _db.insert_render(_entry(ts))
    _db._c().execute("INSERT INTO overlays (ts, title) VALUES (?, ?)", (ts, "Episode 1"))
    _db._c().execute("DELETE FROM renders WHERE ts = ?", (ts,))
    _db._c().commit()
    assert _db.lifetime()["renders"] == 1
    kept = _db._c().execute("SELECT * FROM deleted_scripts WHERE ts = ?", (ts,)).fetchone()
    assert kept["text"] == f"script {ts}"
    assert kept["title"] == "Episode 1"
    assert json.loads(kept["tags"]) == ["t"]


def test_seed_counts_rows_already_present_once(isolated_paths):
    _db.insert_render(_entry("2026-06-01T00:00:00Z"))
    _db._c().execute("DELETE FROM lifetime")
    _db._c().commit()
    _db.init_schema()   # an upgraded db: seeds from the existing rows
    _db.init_schema()   # idempotent
    assert _db.lifetime()["renders"] == 1


def test_library_counts_only_files_on_disk_not_soft_deleted(isolated_paths, tmp_path):
    present = tmp_path / "a.mp3"
    present.write_bytes(b"x")
    gone_soft = tmp_path / "b.mp3"
    gone_soft.write_bytes(b"x")
    _db.insert_render(_entry("2026-06-01T00:00:00Z", path=str(present)))
    _db.insert_render(_entry("2026-06-02T00:00:00Z", path=str(tmp_path / "missing.mp3")))
    _db.insert_render(_entry("2026-06-03T00:00:00Z", path=str(gone_soft)))
    _db._c().execute("INSERT INTO overlays (ts, deleted) VALUES ('2026-06-03T00:00:00Z', 1)")
    _db._c().commit()
    assert _db.library()["renders"] == 1
    assert _db.lifetime()["renders"] == 3


async def test_stats_endpoint(client, isolated_paths):
    _db.insert_render(_entry("2026-06-01T00:00:00Z"))
    r = await client.get("/stats")
    assert r.status == 200
    body = await r.json()
    assert body["lifetime"]["renders"] == 1
    assert body["library"]["renders"] == 0
