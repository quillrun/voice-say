"""Retention policy — periodic housekeeping for the voice archive.

One job:

1. **Cold-tier audio.** Move completed audio that hasn't been played in
   N days from voice-archive/YYYY/MM/ to voice-archive/.cold/YYYY/MM/.
   Starred and bookmarked entries are never moved. GET /audio/{ts} still
   serves a moved file (it looks in .cold/ when the recorded path is gone).
   Default N = 180 days. `--cold-days 0` disables the job; `--purge`
   deletes cold audio outright instead of moving it. Either way the
   renders row (SQLite) stays intact — the macOS app surfaces the entry
   as "audio archived" via resolvedAudioURL() returning nil.

Run standalone:
    .venv/bin/python -m voice_say.retention                  # default
    .venv/bin/python -m voice_say.retention --dry-run
    .venv/bin/python -m voice_say.retention --cold-days 365
    .venv/bin/python -m voice_say.retention --purge

Triggered by the `local.voicesay.retention` launchd job at 04:00 on the 1st
of each month. Logs go where that LaunchAgent's StandardOutPath and
StandardErrorPath point (~/Library/Logs with the install steps).
"""
from __future__ import annotations

import argparse
import json
import logging
import shutil
import sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import _db
from . import engine
from . import progress


COLD_TIER_SUBDIR = ".cold"

log = logging.getLogger("voice-say-retention")


@dataclass
class RetentionResult:
    cold_tiered: int              # audio files moved to .cold/
    cold_purged: int              # audio files PERMANENTLY deleted (unlink, not Trash)
    candidates_inspected: int

    def as_dict(self) -> dict:
        return self.__dict__


def run(cold_days: int = 180, dry_run: bool = False, purge: bool = False) -> RetentionResult:
    candidates, moved, purged = _cold_tier_audio(
        cold_days=cold_days, dry_run=dry_run, purge=purge,
    )
    return RetentionResult(
        cold_tiered=moved,
        cold_purged=purged,
        candidates_inspected=candidates,
    )


def _cold_tier_audio(*, cold_days: int, dry_run: bool, purge: bool) -> tuple[int, int, int]:
    """Walk the renders table + progress map; move audio for completed
    entries whose last_played is older than `cold_days`. Returns
    (candidates, moved, purged)."""
    if cold_days <= 0:
        return (0, 0, 0)
    rows = engine.read_history(limit=0)
    prog = progress.read_all()
    ovs = _db.read_overlays_all()
    cutoff = datetime.now(timezone.utc) - timedelta(days=cold_days)

    moved = 0
    purged = 0
    candidates = 0
    for row in rows:
        ts = row.get("ts")
        if not ts:
            continue
        archive_path_s = row.get("archive_path")
        if not archive_path_s:
            continue
        audio = Path(archive_path_s)
        # Already cold (or trashed) → nothing to do.
        if not audio.exists() or COLD_TIER_SUBDIR in audio.parts:
            continue

        # Starred or bookmarked entries are kept for re-listening, and a
        # resumable draft is kept for its continuation: never tiered.
        ov = ovs.get(ts) or {}
        if ov.get("starred") or ov.get("bookmarks") or row.get("resume_full_text"):
            continue
        prog_row = prog.get(ts)
        if not prog_row or not prog_row.get("completed"):
            continue
        last_played_s = prog_row.get("last_played")
        if not last_played_s:
            continue
        try:
            last_played = datetime.fromisoformat(last_played_s.replace("Z", "+00:00"))
        except ValueError:
            continue
        if last_played > cutoff:
            continue

        candidates += 1
        if dry_run:
            log.info("would %s: %s (last_played=%s)",
                     "purge" if purge else "move",
                     audio.name, last_played_s)
            continue

        if purge:
            try:
                audio.unlink()
                purged += 1
                log.info("purged: %s", audio.name)
            except OSError as exc:
                log.warning("purge failed for %s: %s", audio.name, exc)
        else:
            try:
                # relative_to raises ValueError for a row whose archive_path
                # lives outside ARCHIVE_ROOT (a moved or imported library); catch it
                # so one bad row can't abort the whole retention run.
                rel = audio.parent.relative_to(engine.ARCHIVE_ROOT)
                cold_dir = engine.ARCHIVE_ROOT / COLD_TIER_SUBDIR / rel
                cold_dir.mkdir(parents=True, exist_ok=True)
                shutil.move(str(audio), str(cold_dir / audio.name))
                moved += 1
                log.info("cold-tiered: %s -> %s", audio.name, cold_dir)
            except (OSError, ValueError) as exc:
                log.warning("cold-tier failed for %s: %s", audio.name, exc)
    return (candidates, moved, purged)


def main() -> None:
    parser = argparse.ArgumentParser(description="voice-say retention job")
    parser.add_argument("--cold-days", type=int, default=180,
                        help="move audio for completed entries unplayed for N days; 0 disables")
    parser.add_argument("--purge", action="store_true",
                        help="PERMANENTLY delete cold audio instead of cold-tiering "
                             "(unlink, not macOS Trash — irreversible)")
    parser.add_argument("--dry-run", action="store_true",
                        help="report what would happen, mutate nothing")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        stream=sys.stderr,
    )
    _db.connect()
    _db.init_schema()
    result = run(cold_days=args.cold_days, dry_run=args.dry_run, purge=args.purge)
    log.info("retention done: %s", json.dumps(result.as_dict()))
    print(json.dumps({"dry_run": args.dry_run, **result.as_dict()}, indent=2))


if __name__ == "__main__":
    main()
