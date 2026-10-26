"""SQLite store — the single durable home for renders, progress, overlays.

Replaces the three JSONL files + the hand-rolled `_jsonl_store.py`
(fcntl locking + size-triggered compaction). One `voice.db` (WAL mode)
gives concurrent readers, native cross-process write serialization, and
FTS5 full-text search over transcripts — no custom locking or compaction.

Audio is NOT stored here: rendered audio stays as files under
`voice-archive/` and the `renders.archive_path` column references it.

Tables
  renders   append-only (never UPDATE/DELETE) — the render record incl. full text
  progress  one row per ts, UPSERT (latest-wins) — playback position
  overlays  one row per ts, UPSERT (latest-wins) — star/tags/bookmarks/soft-delete
  renders_fts  external-content FTS5 over renders.text (kept in sync by trigger)
  lifetime  one row — running totals bumped by trigger on every insert and
            never decremented, so they outlive deleted rows and deleted audio
  deleted_scripts  the transcript of any renders row deleted anyway (trigger)

The in-memory cache in `state.py` is hydrated from here at startup and is
purely a read-side projection; this module is the durability layer.
"""
from __future__ import annotations

import json
import sqlite3
import threading
from pathlib import Path
from typing import Any

from . import config


# Module-level connection. The daemon is single-process (asyncio, one
# thread) so one shared connection is correct; `check_same_thread=False`
# keeps the migration script + tests free to drive it from a worker
# thread. A lock guards writes so a stray cross-thread caller can't
# interleave a transaction.
_conn: sqlite3.Connection | None = None
_db_path: Path = config.DB_PATH
_lock = threading.RLock()


_SCHEMA = """
CREATE TABLE IF NOT EXISTS renders (
  ts            TEXT PRIMARY KEY,   -- ISO-8601 UTC; the entry id
  kind          TEXT NOT NULL,      -- 'say' | 'render'
  backend       TEXT NOT NULL,
  voice         TEXT,
  speed         REAL,
  format        TEXT,
  chars         INTEGER,
  words         INTEGER,
  duration_s    REAL,
  bytes         INTEGER,
  archive_name  TEXT,
  archive_path  TEXT,
  text          TEXT NOT NULL,      -- full transcript
  tags          TEXT                -- JSON array
  -- Post-v1 additive columns (resume_full_text, resume_char_offset,
  -- render_elapsed_s, seam_map) live ONLY in _migrate_add_columns so a fresh DB
  -- and an upgraded DB converge through one code path.
);
CREATE INDEX IF NOT EXISTS idx_renders_kind ON renders(kind);

CREATE TABLE IF NOT EXISTS progress (
  ts          TEXT PRIMARY KEY,
  played_s    REAL,
  duration_s  REAL,
  play_count  INTEGER,
  completed   INTEGER,              -- 0/1
  last_played TEXT
);

CREATE TABLE IF NOT EXISTS overlays (
  ts            TEXT PRIMARY KEY,
  starred       INTEGER,            -- 0/1
  deleted       INTEGER,            -- 0/1
  tags          TEXT,               -- JSON array
  removed_tags  TEXT,               -- JSON array
  bookmarks     TEXT,               -- JSON array of objects
  title         TEXT,               -- user-set display title (overrides derived)
  last_modified TEXT
);

CREATE VIRTUAL TABLE IF NOT EXISTS renders_fts
  USING fts5(text, content='renders', content_rowid='rowid');

-- renders is append-only in the daemon, but a row can still be deleted or
-- edited by hand; without the delete/update mirrors a reused rowid would
-- match the old row's words.
CREATE TRIGGER IF NOT EXISTS renders_ai AFTER INSERT ON renders BEGIN
  INSERT INTO renders_fts(rowid, text) VALUES (new.rowid, new.text);
END;
CREATE TRIGGER IF NOT EXISTS renders_ad AFTER DELETE ON renders BEGIN
  INSERT INTO renders_fts(renders_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
END;
CREATE TRIGGER IF NOT EXISTS renders_au AFTER UPDATE OF text ON renders BEGIN
  INSERT INTO renders_fts(renders_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
  INSERT INTO renders_fts(rowid, text) VALUES (new.rowid, new.text);
END;

CREATE TABLE IF NOT EXISTS lifetime (
  id          INTEGER PRIMARY KEY CHECK (id = 1),
  renders     INTEGER NOT NULL,
  chars       INTEGER NOT NULL,
  words       INTEGER NOT NULL,
  duration_s  REAL    NOT NULL,
  bytes       INTEGER NOT NULL,
  since       TEXT                -- earliest render the totals include
);

CREATE TRIGGER IF NOT EXISTS renders_lifetime AFTER INSERT ON renders BEGIN
  UPDATE lifetime SET
    renders    = renders + 1,
    chars      = chars + coalesce(new.chars, 0),
    words      = words + coalesce(new.words, 0),
    duration_s = duration_s + coalesce(new.duration_s, 0),
    bytes      = bytes + coalesce(new.bytes, 0),
    since      = coalesce(since, new.ts)
  WHERE id = 1;
END;

CREATE TABLE IF NOT EXISTS deleted_scripts (
  ts          TEXT PRIMARY KEY,
  title       TEXT,
  tags        TEXT,               -- JSON array
  chars       INTEGER,
  duration_s  REAL,
  text        TEXT NOT NULL,
  deleted_at  TEXT NOT NULL
);

-- renders is append-only; a row deleted anyway (manual cleanup) keeps its
-- script, and its title from overlays, here.
CREATE TRIGGER IF NOT EXISTS renders_keep_script BEFORE DELETE ON renders BEGIN
  INSERT OR REPLACE INTO deleted_scripts
    (ts, title, tags, chars, duration_s, text, deleted_at)
  VALUES (old.ts, (SELECT title FROM overlays WHERE ts = old.ts), old.tags,
          old.chars, old.duration_s, old.text,
          strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
END;
"""


def connect(path: Path | None = None) -> sqlite3.Connection:
    """Open (or reopen) the connection. Tests/migration pass an explicit
    path; the daemon calls with no args and gets `config.DB_PATH`."""
    global _conn, _db_path
    with _lock:
        if path is not None:
            _db_path = Path(path)
        if _conn is not None:
            _conn.close()
        _db_path.parent.mkdir(parents=True, exist_ok=True)
        _conn = sqlite3.connect(str(_db_path), check_same_thread=False)
        _conn.row_factory = sqlite3.Row
        _conn.execute("PRAGMA journal_mode=WAL")
        _conn.execute("PRAGMA synchronous=NORMAL")
        _conn.execute("PRAGMA foreign_keys=ON")
        return _conn


def _c() -> sqlite3.Connection:
    """Lazily ensure a connection exists (defaults to config.DB_PATH)."""
    if _conn is None:
        connect(_db_path)
    assert _conn is not None
    return _conn


def init_schema() -> None:
    """Create tables/index/FTS/trigger if absent. Idempotent."""
    with _lock:
        # A DB from before the delete trigger may hold deletes the index never saw.
        stale_fts = _c().execute(
            "SELECT 1 FROM sqlite_master WHERE name = 'renders'").fetchone() is not None \
            and _c().execute(
                "SELECT 1 FROM sqlite_master WHERE name = 'renders_ad'").fetchone() is None
        _c().executescript(_SCHEMA)
        if stale_fts:
            _c().execute("INSERT INTO renders_fts(renders_fts) VALUES ('rebuild')")
        _migrate_add_columns()
        _seed_lifetime()
        _c().commit()


def _migrate_add_columns() -> None:
    """Additive, idempotent column backfill for tables created before a
    column existed (CREATE TABLE IF NOT EXISTS never alters an existing
    table). Each ALTER is guarded by a pragma check so re-running is a no-op."""
    cols = {r[1] for r in _c().execute("PRAGMA table_info(overlays)")}
    if "title" not in cols:
        _c().execute("ALTER TABLE overlays ADD COLUMN title TEXT")
    # Series membership: a name and an episode number, so a series lists in
    # episode order (GET /history?series=) instead of by render time.
    if "series" not in cols:
        _c().execute("ALTER TABLE overlays ADD COLUMN series TEXT")
    if "episode" not in cols:
        _c().execute("ALTER TABLE overlays ADD COLUMN episode INTEGER")
    # Resume / continue-a-draft: a save-and-stop partial persists the joined
    # full text it was chunked from + the clean chunk-boundary char offset it
    # reached, so a later POST /episode/resume can re-chunk, skip the rendered
    # prefix, and render only the remainder. Both NULL for every existing row
    # and every non-draft render (only the finalized-early path sets them).
    rcols = {r[1] for r in _c().execute("PRAGMA table_info(renders)")}
    if "resume_full_text" not in rcols:
        _c().execute("ALTER TABLE renders ADD COLUMN resume_full_text TEXT")
    if "resume_char_offset" not in rcols:
        _c().execute("ALTER TABLE renders ADD COLUMN resume_char_offset INTEGER")
    # Wall-clock render time (seconds). NULL for every row written before this
    # column existed — the client shows "Unknown" for those; never backfilled.
    if "render_elapsed_s" not in rcols:
        _c().execute("ALTER TABLE renders ADD COLUMN render_elapsed_s REAL")
    # Read-along seam map: [audio_s, char_offset] points the client karaoke
    # highlight piecewise-interpolates play-head → char through: the chunk seams,
    # plus a point per spoken word once align.py has measured the audio. NULL
    # until then for a single render, and for rows nothing has aligned.
    if "seam_map" not in rcols:
        _c().execute("ALTER TABLE renders ADD COLUMN seam_map TEXT")


def _seed_lifetime() -> None:
    """Create the lifetime row once, from the renders already present; from
    then on only the insert trigger moves it."""
    _c().execute(
        """INSERT OR IGNORE INTO lifetime
             (id, renders, chars, words, duration_s, bytes, since)
           SELECT 1, count(*), coalesce(sum(chars), 0), coalesce(sum(words), 0),
                  coalesce(sum(duration_s), 0), coalesce(sum(bytes), 0), min(ts)
           FROM renders""")


def lifetime() -> dict[str, Any]:
    """Running totals of everything ever rendered (see the `lifetime` table)."""
    row = _c().execute(
        "SELECT renders, chars, words, duration_s, bytes, since FROM lifetime"
    ).fetchone()
    return dict(row) if row else {
        "renders": 0, "chars": 0, "words": 0, "duration_s": 0.0, "bytes": 0,
        "since": None}


def library() -> dict[str, Any]:
    """What is on disk now: renders not soft-deleted whose audio file exists."""
    rows = _c().execute(
        """SELECT r.archive_path, r.duration_s, r.bytes FROM renders r
           LEFT JOIN overlays o ON o.ts = r.ts
           WHERE coalesce(o.deleted, 0) = 0""").fetchall()
    kept = [r for r in rows
            if r["archive_path"] and Path(_abs_archive_path(r["archive_path"])).is_file()]
    return {"renders": len(kept),
            "duration_s": sum(r["duration_s"] or 0 for r in kept),
            "bytes": sum(r["bytes"] or 0 for r in kept)}


def close() -> None:
    global _conn
    with _lock:
        if _conn is not None:
            _conn.close()
            _conn = None


def _abs_archive_path(p: str | None) -> str | None:
    """A relative archive_path (a recordings bundle, which can't know where it
    will be unzipped) is relative to the data root — the db's own folder."""
    if not p or Path(p).is_absolute():
        return p
    return str(_db_path.parent / p)


def _entry_from_row(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "ts": row["ts"],
        "kind": row["kind"],
        "backend": row["backend"],
        "voice": row["voice"],
        "speed": row["speed"],
        "format": row["format"],
        "chars": row["chars"],
        "words": row["words"],
        "duration_s": row["duration_s"],
        "bytes": row["bytes"],
        "archive_name": row["archive_name"],
        "archive_path": _abs_archive_path(row["archive_path"]),
        "text": row["text"],
        "tags": json.loads(row["tags"]) if row["tags"] else [],
        # Resume columns are additive (migrated in for pre-existing DBs); be
        # tolerant of a row read before the migration ran.
        "resume_full_text": (
            row["resume_full_text"] if "resume_full_text" in row.keys() else None),
        "resume_char_offset": (
            row["resume_char_offset"] if "resume_char_offset" in row.keys() else None),
        # Additive (migrated in); tolerant of a row read before the migration.
        "render_elapsed_s": (
            row["render_elapsed_s"] if "render_elapsed_s" in row.keys() else None),
        # Per-chunk read-along seam map (JSON), tolerant of a pre-migration row.
        "seam_map": (
            json.loads(row["seam_map"])
            if "seam_map" in row.keys() and row["seam_map"] else None),
    }


def insert_render(entry: dict[str, Any]) -> None:
    """Insert one render row. The FTS mirror is maintained by trigger."""
    with _lock:
        _c().execute(
            """INSERT INTO renders
               (ts, kind, backend, voice, speed, format, chars, words,
                duration_s, bytes, archive_name, archive_path, text, tags,
                resume_full_text, resume_char_offset, render_elapsed_s, seam_map)
               VALUES
               (:ts, :kind, :backend, :voice, :speed, :format, :chars, :words,
                :duration_s, :bytes, :archive_name, :archive_path, :text, :tags,
                :resume_full_text, :resume_char_offset, :render_elapsed_s, :seam_map)""",
            {
                **entry,
                "tags": json.dumps(entry.get("tags") or [], ensure_ascii=False),
                # Nullable; the normal render() path never sets them → NULL,
                # so non-draft rows are byte-identical to the pre-resume schema.
                "resume_full_text": entry.get("resume_full_text"),
                "resume_char_offset": entry.get("resume_char_offset"),
                # Wall-clock render seconds; None for any caller not measuring it.
                "render_elapsed_s": entry.get("render_elapsed_s"),
                # Read-along points (JSON); None for a single render until aligned.
                "seam_map": (json.dumps(entry["seam_map"], ensure_ascii=False)
                             if entry.get("seam_map") else None),
            },
        )
        _c().commit()


# Upper bound for a single history/search query, shared by the HTTP routes'
# clamp and the FTS search ceiling so they cannot drift.
MAX_HISTORY_LIMIT = 5000


def read_history(limit: int = 200) -> list[dict[str, Any]]:
    """Newest-first, capped at `limit`. `limit <= 0` returns all rows
    (used by the cache hydrate at startup)."""
    sql = "SELECT * FROM renders ORDER BY ts DESC"
    params: tuple[Any, ...] = ()
    if limit > 0:
        sql += " LIMIT ?"
        params = (limit,)
    cur = _c().execute(sql, params)
    return [_entry_from_row(r) for r in cur.fetchall()]


def set_seam_map(ts: str, seam_map: list) -> bool:
    """Replace one row's read-along points (align.py measures them after the
    row lands). Returns whether the row exists."""
    with _lock:
        cur = _c().execute("UPDATE renders SET seam_map = ? WHERE ts = ?",
                           (json.dumps(seam_map), ts))
        _c().commit()
    return cur.rowcount > 0


def get_render(ts: str) -> dict[str, Any] | None:
    cur = _c().execute("SELECT * FROM renders WHERE ts = ?", (ts,))
    row = cur.fetchone()
    return _entry_from_row(row) if row else None


def _fts_query(q: str) -> str:
    """Turn a free-text query into a safe FTS5 MATCH expression: each
    whitespace-separated term becomes a quoted token (double-quotes
    escaped), AND-ed together. Returns "" when the query has no terms."""
    terms = [t for t in q.split() if t]
    return " ".join('"' + t.replace('"', '""') + '"' for t in terms)


def search(query: str, limit: int = 50) -> list[dict[str, Any]]:
    """Full-text search over transcripts, newest-first. Empty/whitespace
    query returns []."""
    match = _fts_query(query)
    if not match:
        return []
    limit = max(1, min(limit, MAX_HISTORY_LIMIT))
    cur = _c().execute(
        """SELECT r.* FROM renders_fts f
             JOIN renders r ON r.rowid = f.rowid
            WHERE renders_fts MATCH ?
            ORDER BY r.ts DESC LIMIT ?""",
        (match, limit),
    )
    return [_entry_from_row(r) for r in cur.fetchall()]


def _progress_from_row(row: sqlite3.Row) -> dict[str, Any]:
    out: dict[str, Any] = {
        "ts": row["ts"],
        "played_s": row["played_s"],
        "play_count": row["play_count"],
        "completed": bool(row["completed"]),
        "last_played": row["last_played"],
    }
    if row["duration_s"] is not None:
        out["duration_s"] = row["duration_s"]
    return out


def upsert_progress(row: dict[str, Any]) -> None:
    with _lock:
        _c().execute(
            """INSERT INTO progress (ts, played_s, duration_s, play_count, completed, last_played)
               VALUES (:ts, :played_s, :duration_s, :play_count, :completed, :last_played)
               ON CONFLICT(ts) DO UPDATE SET
                 played_s=excluded.played_s, duration_s=excluded.duration_s,
                 play_count=excluded.play_count, completed=excluded.completed,
                 last_played=excluded.last_played""",
            {
                "ts": row["ts"],
                "played_s": row.get("played_s"),
                "duration_s": row.get("duration_s"),
                "play_count": row.get("play_count"),
                "completed": 1 if row.get("completed") else 0,
                "last_played": row.get("last_played"),
            },
        )
        _c().commit()


def read_progress_all() -> dict[str, dict[str, Any]]:
    cur = _c().execute("SELECT * FROM progress")
    return {r["ts"]: _progress_from_row(r) for r in cur.fetchall()}


def read_progress(ts: str) -> dict[str, Any] | None:
    cur = _c().execute("SELECT * FROM progress WHERE ts = ?", (ts,))
    row = cur.fetchone()
    return _progress_from_row(row) if row else None


def _overlay_from_row(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "ts": row["ts"],
        "starred": bool(row["starred"]),
        "deleted": bool(row["deleted"]),
        "tags": json.loads(row["tags"]) if row["tags"] else [],
        "removed_tags": json.loads(row["removed_tags"]) if row["removed_tags"] else [],
        "bookmarks": json.loads(row["bookmarks"]) if row["bookmarks"] else [],
        "title": row["title"],
        "series": row["series"] if "series" in row.keys() else None,
        "episode": row["episode"] if "episode" in row.keys() else None,
        "last_modified": row["last_modified"],
    }


def upsert_overlay(row: dict[str, Any]) -> None:
    with _lock:
        _c().execute(
            """INSERT INTO overlays (ts, starred, deleted, tags, removed_tags, bookmarks,
                                   title, series, episode, last_modified)
               VALUES (:ts, :starred, :deleted, :tags, :removed_tags, :bookmarks,
                       :title, :series, :episode, :last_modified)
               ON CONFLICT(ts) DO UPDATE SET
                 starred=excluded.starred, deleted=excluded.deleted,
                 tags=excluded.tags, removed_tags=excluded.removed_tags,
                 bookmarks=excluded.bookmarks, title=excluded.title,
                 series=excluded.series, episode=excluded.episode,
                 last_modified=excluded.last_modified""",
            {
                "ts": row["ts"],
                "starred": 1 if row.get("starred") else 0,
                "deleted": 1 if row.get("deleted") else 0,
                "tags": json.dumps(row.get("tags") or [], ensure_ascii=False),
                "removed_tags": json.dumps(row.get("removed_tags") or [], ensure_ascii=False),
                "bookmarks": json.dumps(row.get("bookmarks") or [], ensure_ascii=False),
                "title": row.get("title"),
                "series": row.get("series"),
                "episode": row.get("episode"),
                "last_modified": row.get("last_modified"),
            },
        )
        _c().commit()


def read_overlays_all() -> dict[str, dict[str, Any]]:
    cur = _c().execute("SELECT * FROM overlays")
    return {r["ts"]: _overlay_from_row(r) for r in cur.fetchall()}


def read_overlay(ts: str) -> dict[str, Any] | None:
    cur = _c().execute("SELECT * FROM overlays WHERE ts = ?", (ts,))
    row = cur.fetchone()
    return _overlay_from_row(row) if row else None
