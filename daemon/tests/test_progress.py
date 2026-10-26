"""Tests for the playback-progress store (SQLite-backed)."""
from __future__ import annotations

import pytest

import voice_say.progress as progress


def test_read_missing_returns_none(isolated_paths):
    assert progress.read("never-written") is None
    assert progress.read_all() == {}


def test_write_then_read_round_trip(isolated_paths):
    row = progress.write("2026-05-25T01:00:00Z", played_s=42.0, duration_s=120.0, started=True)
    assert row["played_s"] == 42.0
    assert row["duration_s"] == 120.0
    assert row["play_count"] == 1
    assert row["completed"] is False
    assert row["last_played"]

    got = progress.read("2026-05-25T01:00:00Z")
    assert got is not None
    assert got["played_s"] == 42.0
    assert got["play_count"] == 1


def test_latest_wins_on_multiple_writes(isolated_paths):
    ts = "2026-05-25T02:00:00Z"
    progress.write(ts, played_s=10.0, duration_s=200.0, started=True)
    progress.write(ts, played_s=20.0)
    progress.write(ts, played_s=30.0)
    row = progress.read(ts)
    assert row["played_s"] == 30.0
    # play_count only bumped once (only first call had started=True)
    assert row["play_count"] == 1
    # duration_s stuck from the first write
    assert row["duration_s"] == 200.0


def test_started_bumps_play_count(isolated_paths):
    ts = "2026-05-25T03:00:00Z"
    progress.write(ts, played_s=5.0, started=True)
    progress.write(ts, played_s=15.0, started=False)
    progress.write(ts, played_s=0.0, started=True)  # second session
    row = progress.read(ts)
    assert row["play_count"] == 2


def test_completed_flag_sticks(isolated_paths):
    ts = "2026-05-25T04:00:00Z"
    progress.write(ts, played_s=100.0, duration_s=100.0, completed=True)
    # Subsequent write without completed kwarg keeps the existing value.
    progress.write(ts, played_s=0.0)
    row = progress.read(ts)
    assert row["completed"] is True


def test_read_all_aggregates_across_ts(isolated_paths):
    progress.write("ts-a", played_s=1.0, started=True)
    progress.write("ts-b", played_s=2.0, started=True)
    progress.write("ts-a", played_s=10.0)
    state = progress.read_all()
    assert set(state.keys()) == {"ts-a", "ts-b"}
    assert state["ts-a"]["played_s"] == 10.0
    assert state["ts-b"]["played_s"] == 2.0


def test_write_rejects_invalid_input(isolated_paths):
    with pytest.raises(ValueError):
        progress.write("", played_s=1.0)
    with pytest.raises(ValueError):
        progress.write("ts-x", played_s=-1.0)
    with pytest.raises(ValueError):
        progress.write("ts-y", played_s=0.0, duration_s=-1.0)
