"""Shared test fixtures.

Post-vault-cut: the durable store is one SQLite db (`voice.db`); audio
stays as files under ARCHIVE_ROOT. `isolated_paths` redirects both into a
per-test tmp dir so tests never touch the real archive / db.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest

import voice_say.engine as engine
from voice_say import _db, _sinks, config


def pytest_configure(config: pytest.Config) -> None:
    """Fail loudly if the async plugin is missing.

    The resume / stream / cancel / finalize suite is almost entirely
    `async def` tests run under asyncio_mode='auto'. Without pytest-asyncio
    those tests are silently SKIPPED — a green-looking run that never
    exercised the feature. Error at collection time instead of letting a
    silent skip masquerade as a pass. Run via the daemon venv:
    `daemon/.venv/bin/python -m pytest`."""
    if importlib.util.find_spec("pytest_asyncio") is None:
        raise pytest.UsageError(
            "pytest-asyncio is not installed — the async resume/stream tests "
            "would silently SKIP. Install dev deps (pip install -e '.[dev]') "
            "or run via daemon/.venv/bin/python -m pytest.")


@pytest.fixture(autouse=True)
def _no_alignment(monkeypatch):
    """The daemon starts the read-along aligner when its helper is built;
    tests never run the recognizer (test_align.py injects a fake aligner)."""
    monkeypatch.setattr(config, "ALIGN_ENABLED", False)
    monkeypatch.setattr(engine, "aligner", None)


@pytest.fixture
def isolated_paths(tmp_path: Path, monkeypatch):
    """Redirect the audio archive to tmp and point the SQLite store at a
    throwaway db. Yields {'archive', 'db'}."""
    archive = tmp_path / "voice-archive"
    db = tmp_path / "voice.db"
    monkeypatch.setattr(engine, "ARCHIVE_ROOT", archive)
    monkeypatch.setattr(_sinks, "ARCHIVE_ROOT", archive)
    _db.connect(db)
    _db.init_schema()
    yield {"archive": archive, "db": db}
    _db.close()


@pytest.fixture
def catalog(monkeypatch):
    """Two launchd-managed test backends in place of the committed catalog:
    `tts-a` in the url form, `tts-b` in the older host + port form."""
    specs = {
        "tts-a": {"url": "http://127.0.0.1:9101", "model": "tts-model", "voices": ["v1"],
                  "service": {"kind": "launchd", "label": "local.voicesay.tts-a"}},
        "tts-b": {"host": "127.0.0.1", "port": 9102, "model": "tts-model", "voices": [],
                  "service": {"kind": "launchd", "label": "local.voicesay.tts-b"}},
    }
    monkeypatch.setattr(config, "load_backends", lambda: specs)
    monkeypatch.setattr(engine, "BACKENDS", engine._build_backends())
    return engine.BACKENDS
