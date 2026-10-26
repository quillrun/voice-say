"""Closed-vocabulary enforcement (allowed_tags).

The committed default is an OPEN vocabulary (`allowed_tags = []`): any
normalized tag is accepted. Setting `allowed_tags` to a non-empty list CLOSES
the vocabulary — `/render` and overlay tag-edits then reject unknown tags.
These tests pin the enforcement.
"""
from __future__ import annotations

import pytest

from voice_say import config, engine, overlays


@pytest.fixture
def closed_vocab(monkeypatch):
    """Close the vocabulary to {summary, daily-notes} for the test body."""
    monkeypatch.setattr(config, "ALLOWED_TAGS", ["Summary", "Daily Notes"])
    yield


def test_open_mode_accepts_everything(monkeypatch):
    monkeypatch.setattr(config, "ALLOWED_TAGS", [])
    assert engine.allowed_tag_set() == set()
    assert engine.unknown_tags(["anything", "goes-here"]) == []


def test_closed_mode_normalizes_allowed_list(closed_vocab):
    # config values are normalized too, so "Daily Notes" → "daily-notes".
    assert engine.allowed_tag_set() == {"summary", "daily-notes"}
    assert engine.unknown_tags(["summary"]) == []
    assert engine.unknown_tags(["summary", "random"]) == ["random"]


def test_render_rejects_unknown_tag(closed_vocab):
    with pytest.raises(engine.RenderError) as ei:
        engine._validate("hello", "kokoro", None, ["random"])
    assert ei.value.stage == "request"          # → HTTP 400
    assert "allowed_tags" in ei.value.message
    assert "daily-notes" in ei.value.message    # error body carries the list


def test_render_accepts_allowed_tag_normalized(closed_vocab):
    _text, _voice, _backend, tags = engine._validate(
        "hello", "kokoro", None, ["Summary"])
    assert tags == ["summary"]


def test_overlay_rejects_unknown_added_tag(isolated_paths, closed_vocab):
    with pytest.raises(ValueError):
        overlays.write("2026-01-01T00:00:00.000Z", tags=["nope"])


def test_overlay_accepts_allowed_added_tag(isolated_paths, closed_vocab):
    row = overlays.write("2026-01-01T00:00:00.000Z", tags=["Summary"])
    assert row["tags"] == ["summary"]


def test_overlay_removed_tags_are_not_gated(isolated_paths, closed_vocab):
    # You must be able to clear a tag that is no longer in the vocabulary.
    row = overlays.write("2026-01-01T00:00:00.000Z", removed_tags=["legacy-tag"])
    assert "legacy-tag" in row["removed_tags"]
