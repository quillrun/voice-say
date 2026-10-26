"""Tests for the retention job — cold-tiering and purge."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

import voice_say._db as _db
import voice_say.progress as progress
import voice_say.retention as retention


def _seed_entry(isolated_paths, ts: str, fname: str) -> Path:
    """Create the audio file + the render row that points to it."""
    audio_dir = isolated_paths["archive"] / "2025" / "01"
    audio_dir.mkdir(parents=True, exist_ok=True)
    audio = audio_dir / fname
    audio.write_bytes(b"\xff\xfb" + b"\x00" * 1024)
    _db.insert_render({
        "ts": ts,
        "kind": "render",
        "backend": "kokoro",
        "voice": "af_alloy",
        "speed": 1.0,
        "format": "mp3",
        "chars": 5,
        "words": 1,
        "duration_s": 0.0,
        "bytes": 1026,
        "archive_name": fname,
        "archive_path": str(audio),
        "text": "x",
        "tags": [],
    })
    return audio


def _make_stale(ts: str) -> None:
    """Backdate a progress row's last_played past any reasonable cutoff."""
    r = _db.read_progress(ts)
    r["last_played"] = (datetime.now(timezone.utc) - timedelta(days=400)).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    _db.upsert_progress(r)


def test_run_does_nothing_for_fresh_entries(isolated_paths):
    audio = _seed_entry(isolated_paths, "ts-fresh", "voice-fresh.mp3")
    progress.write("ts-fresh", played_s=100.0, completed=True)
    # last_played = now -> well under any cutoff
    r = retention.run(cold_days=30)
    assert r.cold_tiered == 0
    assert audio.exists()


def test_run_cold_tiers_stale_completed_entries(isolated_paths):
    audio = _seed_entry(isolated_paths, "ts-stale", "voice-stale.mp3")
    # Write progress, then backdate last_played to be older than cutoff.
    progress.write("ts-stale", played_s=100.0, completed=True)
    _make_stale("ts-stale")

    r = retention.run(cold_days=180)
    assert r.cold_tiered == 1
    assert not audio.exists()
    cold_audio = isolated_paths["archive"] / ".cold" / "2025" / "01" / "voice-stale.mp3"
    assert cold_audio.exists()


def test_run_purge_mode_removes_instead_of_moving(isolated_paths):
    audio = _seed_entry(isolated_paths, "ts-old", "voice-old.mp3")
    progress.write("ts-old", played_s=10.0, completed=True)
    _make_stale("ts-old")

    r = retention.run(cold_days=180, purge=True)
    assert r.cold_purged == 1
    assert r.cold_tiered == 0
    assert not audio.exists()
    cold_audio = isolated_paths["archive"] / ".cold" / "2025" / "01" / "voice-old.mp3"
    assert not cold_audio.exists()


def test_dry_run_mutates_nothing(isolated_paths):
    audio = _seed_entry(isolated_paths, "ts-stale2", "voice-stale2.mp3")
    progress.write("ts-stale2", played_s=10.0, completed=True)
    _make_stale("ts-stale2")

    pre = _db.read_progress("ts-stale2")
    r = retention.run(cold_days=180, dry_run=True)
    assert r.candidates_inspected == 1
    assert r.cold_tiered == 0
    assert r.cold_purged == 0
    assert audio.exists()
    # Progress row is untouched: still stale, still not cold-tiered.
    assert _db.read_progress("ts-stale2") == pre


def test_cold_days_zero_disables_cold_tier(isolated_paths):
    audio = _seed_entry(isolated_paths, "ts-x", "voice-x.mp3")
    progress.write("ts-x", played_s=10.0, completed=True)
    _make_stale("ts-x")

    r = retention.run(cold_days=0)
    assert r.candidates_inspected == 0
    assert audio.exists()


def test_run_skips_non_completed_entries(isolated_paths):
    audio = _seed_entry(isolated_paths, "ts-half", "voice-half.mp3")
    progress.write("ts-half", played_s=50.0, completed=False)
    # Even if last_played is ancient, half-played entries are NOT candidates.
    _make_stale("ts-half")

    r = retention.run(cold_days=180)
    assert r.cold_tiered == 0
    assert audio.exists()


def test_starred_and_bookmarked_entries_are_never_tiered(isolated_paths):
    import voice_say.overlays as overlays
    starred = _seed_entry(isolated_paths, "ts-star", "voice-star.mp3")
    marked = _seed_entry(isolated_paths, "ts-mark", "voice-mark.mp3")
    for ts in ("ts-star", "ts-mark"):
        progress.write(ts, played_s=100.0, completed=True)
        _make_stale(ts)
    overlays.write("ts-star", starred=True)
    overlays.write("ts-mark", bookmarks=[{"id": "b", "position": 0.5, "note": ""}])
    assert retention.run(cold_days=180).cold_tiered == 0
    assert starred.exists() and marked.exists()


async def test_audio_route_serves_a_cold_tiered_file(isolated_paths):
    from aiohttp.test_utils import TestClient, TestServer
    from voice_say.http_server import build_app
    _seed_entry(isolated_paths, "ts-cold", "voice-cold.mp3")
    progress.write("ts-cold", played_s=100.0, completed=True)
    _make_stale("ts-cold")
    assert retention.run(cold_days=180).cold_tiered == 1
    async with TestClient(TestServer(build_app())) as cli:
        r = await cli.get("/audio/ts-cold")
        assert r.status == 200
        assert (await r.read()).startswith(b"\xff\xfb")


def test_a_resumable_draft_is_never_tiered(isolated_paths):
    audio = _seed_entry(isolated_paths, "ts-draft", "voice-draft.mp3")
    with _db._c() as conn:                              # mark it a resumable draft
        conn.execute("UPDATE renders SET resume_full_text=?, resume_char_offset=? "
                     "WHERE ts=?", ("x and more", 1, "ts-draft"))
    progress.write("ts-draft", played_s=100.0, completed=True)
    _make_stale("ts-draft")
    assert retention.run(cold_days=180).cold_tiered == 0
    assert audio.exists()


async def test_a_bundled_relative_archive_path_resolves_against_the_data_root(isolated_paths):
    """A recordings bundle stores archive_path relative ("voice-archive/…"):
    it can't know where it will be unzipped. It is served from the data root."""
    from aiohttp.test_utils import TestClient, TestServer
    from voice_say.http_server import build_app
    audio = _seed_entry(isolated_paths, "ts-rel", "voice-rel.mp3")
    with _db._c() as conn:
        conn.execute("UPDATE renders SET archive_path=? WHERE ts=?",
                     ("voice-archive/2025/01/voice-rel.mp3", "ts-rel"))
    assert _db.get_render("ts-rel")["archive_path"] == str(audio)
    async with TestClient(TestServer(build_app())) as cli:
        r = await cli.get("/audio/ts-rel")
        assert r.status == 200
    assert _db.library()["renders"] == 1
