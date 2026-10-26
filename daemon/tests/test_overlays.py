"""Tests for the user-overlays store (star, soft-delete, tags, bookmarks).
Now SQLite-backed (_db); latest-wins per ts. Uses the shared
`isolated_paths` fixture from conftest.py."""
from __future__ import annotations

import pytest

import voice_say.overlays as overlays


def test_read_missing_returns_none(isolated_paths):
    assert overlays.read("never") is None
    assert overlays.read_all() == {}


def test_write_then_read_round_trip(isolated_paths):
    row = overlays.write("ts-a", starred=True, tags=["completed", "draft"])
    assert row["starred"] is True
    assert row["deleted"] is False  # default
    assert row["tags"] == ["completed", "draft"]
    assert row["bookmarks"] == []
    got = overlays.read("ts-a")
    assert got is not None
    assert got["starred"] is True
    assert got["tags"] == ["completed", "draft"]


def test_partial_update_inherits_prev(isolated_paths):
    overlays.write("ts-b", starred=True, tags=["one"])
    overlays.write("ts-b", deleted=True)  # only deleted; star + tags must persist
    row = overlays.read("ts-b")
    assert row["starred"] is True
    assert row["deleted"] is True
    assert row["tags"] == ["one"]


def test_tags_get_normalized(isolated_paths):
    overlays.write("ts-c", tags=["DRAFT", "Done ", "draft", "  spaced word"])
    row = overlays.read("ts-c")
    # Lowercase, kebab-case, dedup preserving order.
    assert row["tags"] == ["draft", "done", "spaced-word"]


def test_bookmarks_reject_invalid_positions(isolated_paths):
    overlays.write("ts-d", bookmarks=[
        {"id": "ok", "position": 0.5, "note": "fine"},
        {"id": "neg", "position": -0.1, "note": "drop me"},
        {"id": "huge", "position": 1.5, "note": "drop me too"},
        {"id": "str", "position": "0.7", "note": "wrong type"},
    ])
    row = overlays.read("ts-d")
    assert [b["id"] for b in row["bookmarks"]] == ["ok"]


def test_latest_wins_via_db(isolated_paths):
    overlays.write("ts-z", starred=True)
    overlays.write("ts-z", starred=False, tags=["x"])
    row = overlays.read("ts-z")
    assert row["starred"] is False
    assert row["tags"] == ["x"]


def test_write_rejects_empty_ts(isolated_paths):
    with pytest.raises(ValueError):
        overlays.write("", starred=True)


def test_title_round_trip(isolated_paths):
    row = overlays.write("ts-t", title="One Machine, Two Minds")
    assert row["title"] == "One Machine, Two Minds"
    assert overlays.read("ts-t")["title"] == "One Machine, Two Minds"


def test_title_inherits_on_partial_update(isolated_paths):
    overlays.write("ts-t2", title="Keep Me")
    overlays.write("ts-t2", starred=True)  # title not passed → must persist
    row = overlays.read("ts-t2")
    assert row["title"] == "Keep Me"
    assert row["starred"] is True


def test_title_empty_clears(isolated_paths):
    overlays.write("ts-t3", title="Temporary")
    overlays.write("ts-t3", title="")  # explicit empty clears the override
    assert overlays.read("ts-t3")["title"] is None


def test_title_normalized_and_capped(isolated_paths):
    row = overlays.write("ts-t4", title="  multi\n  line   title  ")
    assert row["title"] == "multi line title"
    long = overlays.write("ts-t5", title="x" * 500)
    assert len(long["title"]) == 200
