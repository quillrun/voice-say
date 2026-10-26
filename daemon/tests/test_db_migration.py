"""Tests for the additive, idempotent schema migration on `renders`.

The resume/continue-a-draft feature adds two nullable columns
(resume_full_text, resume_char_offset) via _migrate_add_columns(), mirroring
the existing `overlays.title` migration. These tests assert the migration is
present and re-running init_schema() is a no-op (so an existing voice.db gains
the columns without breaking the 126 existing rows/tests)."""
from __future__ import annotations

from pathlib import Path

import voice_say._db as _db
import voice_say._sinks as _sinks


def _render_cols() -> set[str]:
    return {r[1] for r in _db._c().execute("PRAGMA table_info(renders)")}


def test_init_schema_adds_resume_columns(isolated_paths):
    cols = _render_cols()
    assert "resume_full_text" in cols
    assert "resume_char_offset" in cols


def test_init_schema_adds_render_elapsed_column(isolated_paths):
    assert "render_elapsed_s" in _render_cols()


def test_init_schema_is_idempotent(isolated_paths):
    # Running the schema/migration twice must not raise (duplicate-column
    # ALTER would error) and must leave exactly one of each column.
    _db.init_schema()
    _db.init_schema()
    cols = list(c for c in
                (r[1] for r in _db._c().execute("PRAGMA table_info(renders)")))
    assert cols.count("resume_full_text") == 1
    assert cols.count("resume_char_offset") == 1
    assert cols.count("render_elapsed_s") == 1


def test_migration_backfills_a_preexisting_table(isolated_paths, monkeypatch):
    """Simulate an OLD db: drop the resume columns by recreating renders
    without them, then run the migration and assert it adds them back."""
    conn = _db._c()
    # Build a renders table at the pre-resume schema (no resume_* columns).
    conn.executescript(
        """
        DROP TABLE IF EXISTS renders;
        CREATE TABLE renders (
          ts TEXT PRIMARY KEY, kind TEXT NOT NULL, backend TEXT NOT NULL,
          voice TEXT, speed REAL, format TEXT, chars INTEGER, words INTEGER,
          duration_s REAL, bytes INTEGER, archive_name TEXT, archive_path TEXT,
          text TEXT NOT NULL, tags TEXT
        );
        """
    )
    conn.commit()
    assert "resume_full_text" not in _render_cols()

    _db._migrate_add_columns()
    conn.commit()
    cols = _render_cols()
    assert "resume_full_text" in cols
    assert "resume_char_offset" in cols
    # render_elapsed_s is part of the same additive migration — an old db
    # (no such column) gains it without breaking existing rows.
    assert "render_elapsed_s" in cols


def test_insert_render_round_trips_resume_fields(isolated_paths):
    """An entry carrying resume_* fields persists and reads back; an entry
    WITHOUT them inserts NULL (back-compat with pre-resume callers)."""
    base = {
        "ts": "2026-06-01T00:00:00.000000Z", "kind": "render",
        "backend": "kokoro", "voice": "af_alloy", "speed": 1.0,
        "format": "mp3", "chars": 5, "words": 1, "duration_s": 1.0,
        "bytes": 100, "archive_name": "a.mp3", "archive_path": "/tmp/a.mp3",
        "text": "hello", "tags": ["draft"],
        "resume_full_text": "hello world", "resume_char_offset": 5,
    }
    _db.insert_render(base)
    got = _db.get_render(base["ts"])
    assert got["resume_full_text"] == "hello world"
    assert got["resume_char_offset"] == 5

    # A caller that omits the keys (legacy shape) → NULL, no KeyError.
    legacy = dict(base)
    legacy["ts"] = "2026-06-01T00:00:01.000000Z"
    del legacy["resume_full_text"]
    del legacy["resume_char_offset"]
    _db.insert_render(legacy)
    got2 = _db.get_render(legacy["ts"])
    assert got2["resume_full_text"] is None
    assert got2["resume_char_offset"] is None


def test_build_entry_carries_render_elapsed():
    """build_entry stamps render_elapsed_s when given, None when omitted —
    so the row carries the value (or NULL for callers that don't measure)."""
    timed = _sinks.build_entry(
        "hello", "render", "kokoro", "af_alloy", 1.0,
        Path("/tmp/a.mp3"), b"\x00" * 10, "2026-06-01T00:00:02.000000Z",
        ["t"], 1.0, "mp3", render_elapsed_s=8.137)
    assert timed["render_elapsed_s"] == 8.137

    untimed = _sinks.build_entry(
        "hi", "say", "kokoro", "af_alloy", 1.0,
        Path("/tmp/b.mp3"), b"\x00", "2026-06-01T00:00:03.000000Z", [], 1.0)
    assert untimed["render_elapsed_s"] is None


def test_insert_render_round_trips_render_elapsed(isolated_paths):
    """render_elapsed_s persists and reads back; an entry without it inserts
    NULL (so historical/legacy rows read as None → the client shows Unknown)."""
    base = {
        "ts": "2026-06-01T00:00:00.000000Z", "kind": "render",
        "backend": "kokoro", "voice": "af_alloy", "speed": 1.0,
        "format": "mp3", "chars": 5, "words": 1, "duration_s": 1.0,
        "bytes": 100, "archive_name": "a.mp3", "archive_path": "/tmp/a.mp3",
        "text": "hello", "tags": [], "render_elapsed_s": 8.137,
    }
    _db.insert_render(base)
    got = _db.get_render(base["ts"])
    assert got["render_elapsed_s"] is not None
    assert abs(got["render_elapsed_s"] - 8.137) < 1e-6

    # A caller that omits the key (historical/legacy shape) → NULL, no KeyError.
    legacy = dict(base)
    legacy["ts"] = "2026-06-01T00:00:01.000000Z"
    del legacy["render_elapsed_s"]
    _db.insert_render(legacy)
    assert _db.get_render(legacy["ts"])["render_elapsed_s"] is None


def _row(ts: str, text: str) -> dict:
    return {"ts": ts, "kind": "say", "backend": "kokoro", "voice": "v", "speed": 1.0,
            "format": "wav", "chars": len(text), "words": len(text.split()),
            "duration_s": 1.0, "bytes": 1, "archive_name": "a.wav",
            "archive_path": "/x/a.wav", "text": text, "tags": []}


def test_search_forgets_a_row_deleted_by_hand(isolated_paths):
    _db.insert_render(_row("2026-01-01T00:00:00Z", "apple tart"))
    _db.insert_render(_row("2026-01-02T00:00:00Z", "banana bread"))
    _db._c().execute("DELETE FROM renders WHERE ts = '2026-01-02T00:00:00Z'")
    _db.insert_render(_row("2026-01-03T00:00:00Z", "cherry pie"))   # reuses the rowid
    assert _db.search("banana") == []
    assert [r["ts"] for r in _db.search("cherry")] == ["2026-01-03T00:00:00Z"]


def test_old_db_index_is_rebuilt_once(isolated_paths):
    _db.insert_render(_row("2026-01-01T00:00:00Z", "banana bread"))
    _db._c().executescript("DROP TRIGGER renders_ad; DROP TRIGGER renders_au;")
    _db._c().execute("DELETE FROM renders")                          # a delete the index never saw
    _db.insert_render(_row("2026-01-02T00:00:00Z", "cherry pie"))
    _db.init_schema()
    assert _db.search("banana") == []
