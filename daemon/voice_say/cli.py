"""voice-say — the CLI: `render` makes audio, the rest works the library
(find, search, tag, retitle, star, delete).

`render` runs `cli/voice-say-render` (render, archive, play with mpv; its own
`--help`). The other commands work the history behind the daemon's HTTP API. Everything goes through the daemon,
never the database, so the same render gate, overlay rules and SSE events
apply as for the app.

    voice-say render [TEXT | --file=PATH] [--title=T] [--no-play] ...
    voice-say health [--deep]
    voice-say history [--series NAME] [--limit N] [--json]
    voice-say search QUERY [--limit N] [--json]
    voice-say tags [--check TAG ...]
    voice-say voices BACKEND
    voice-say restart BACKEND
    voice-say align [TS ...] [--limit N] [--min-seconds S]
    voice-say set TS [--title T | --no-title] [--star | --unstar]
                     [--delete [--keep-file] | --undelete]
                     [--tag T ... | --clear-tags] [--remove-tag T ...]
                     [--series S | --no-series] [--episode N] [--allow-new-tags]

Tags: `set --tag` applies tags already in use (the vocabulary from `tags`);
an unknown tag is refused with the nearest existing ones, `--allow-new-tags`
coins it. `tags --check` is the same test for scripts (`render` calls it).

Exit codes: 0 ok · 1 the daemon answered with an error · 2 usage ·
4 refused before any request (unknown tag, bad value) · 6 daemon unreachable;
`render` adds 3 render failed · 7 timed out.
Standard library only on Python 3.11+ (3.10 also needs tomli, which reads
the config), so it runs without the daemon's venv; `VOICE_SAY_DAEMON_URL`
points it at the daemon (default http://127.0.0.1:8890).
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

from . import __version__, config
from .tags import normalize_tag

DAEMON_URL = (config.env("VOICE_SAY_DAEMON_URL") or "http://127.0.0.1:8890").rstrip("/")

EXIT_OK, EXIT_DAEMON_ERROR, EXIT_USAGE, EXIT_REFUSED, EXIT_DOWN = 0, 1, 2, 4, 6

# The most rows GET /history returns (the daemon clamps `limit` to this).
HISTORY_MAX = 5000

# `render` is the bash script next to the other CLIs (mpv, IPC, timeouts).
RENDER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "cli", "voice-say-render")


class DaemonDown(Exception):
    pass


class DaemonError(Exception):
    def __init__(self, status: int, body: Any):
        self.status, self.body = status, body
        if isinstance(body, dict):
            msg = f"{body.get('error', 'http')}: {body.get('message', '')}".rstrip(": ")
        else:
            msg = str(body)[:200]
        super().__init__(f"daemon HTTP {status} — {msg}")


def _request(method: str, path: str, *, params: dict[str, Any] | None = None,
             body: dict[str, Any] | None = None, timeout: float = 30.0) -> Any:
    url = DAEMON_URL + path
    if params:
        url += "?" + urllib.parse.urlencode({k: v for k, v in params.items() if v is not None})
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json"} if data else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = raw.decode(errors="replace")
        raise DaemonError(exc.code, parsed) from None
    except (urllib.error.URLError, OSError, TimeoutError) as exc:
        raise DaemonDown(str(exc)) from None
    return json.loads(raw) if raw else None


def _seg(value: str) -> str:
    """One URL path segment: a ts or backend id cannot re-target another route."""
    return urllib.parse.quote(str(value), safe="")


# ---------------------------------------------------------------- tags --

def nearest_tags(unknown: list[str], known: list[str], limit: int = 5) -> list[str]:
    """Up to `limit` known tags sharing a prefix with an unknown one; the first
    known tags fill the rest, so the hint is never empty while tags exist."""
    hits: list[str] = []
    seen: set[str] = set()
    for u in unknown:
        prefix = u[:3] if len(u) >= 3 else u
        for k in known:
            if k not in seen and k.startswith(prefix):
                hits.append(k)
                seen.add(k)
    for k in known:
        if len(hits) >= limit:
            break
        if k not in seen:
            hits.append(k)
            seen.add(k)
    return hits[:limit]


def check_tags(candidates: list[str]) -> tuple[list[str], list[str]]:
    """(unknown candidates as given, known vocabulary normalized and sorted).
    Empty after normalization counts as unknown (it could never be stored)."""
    known = sorted({normalize_tag(t) for t in _request("GET", "/tags").get("tags", [])} - {""})
    known_set = set(known)
    return [raw for raw in candidates if normalize_tag(raw) not in known_set], known


def _refuse_unknown(unknown: list[str], known: list[str], remedy: str | None = None) -> int:
    near = nearest_tags([normalize_tag(u) for u in unknown], known)
    hint = f"nearest existing: {', '.join(near)}" if near else "no tags in use yet"
    msg = f"ERR: unknown tag(s) {', '.join(unknown)} — {hint}."
    if remedy:
        msg += f"\n     Reuse one (voice-say tags), or coin it on purpose with {remedy}."
    print(msg, file=sys.stderr)
    return EXIT_REFUSED


# ------------------------------------------------------------ printing --

def _fmt_dur(seconds: float | None) -> str:
    s = int(round(seconds or 0))
    return f"{s // 60}:{s % 60:02d}"


def _entry_line(e: dict[str, Any]) -> str:
    ov = e.get("overlay") or {}
    title = ov.get("title") or " ".join((e.get("text") or "").split())[:60]
    flags = ("★" if ov.get("starred") else " ") + ("✗" if ov.get("deleted") else " ")
    where = ""
    if ov.get("series"):
        ep = ov.get("episode")
        where = f"  [{ov['series']}" + (f" · {ep}" if ep is not None else "") + "]"
    tags = sorted(set(e.get("tags") or []) | set(ov.get("tags") or []))
    tag_s = f"  #{' #'.join(tags)}" if tags else ""
    return (f"{e['ts']}  {flags} {e.get('kind', 'render'):6} {_fmt_dur(e.get('duration_s')):>6}  "
            f"{title}{where}{tag_s}")


def _print_entries(body: dict[str, Any], as_json: bool) -> None:
    if as_json:
        print(json.dumps(body, indent=2, ensure_ascii=False))
        return
    entries = body.get("entries", [])
    for e in entries:
        print(_entry_line(e))
    sys.stdout.flush()
    print(f"{len(entries)} entr{'y' if len(entries) == 1 else 'ies'}", file=sys.stderr)


# ------------------------------------------------------------ commands --

def cmd_health(a: argparse.Namespace) -> int:
    try:
        body = _request("GET", "/health", params={"deep": "1"} if a.deep else None, timeout=10)
    except DaemonDown as exc:
        if a.json:
            print(json.dumps({"status": "down", "daemon_url": DAEMON_URL, "error": str(exc)}))
        else:
            print(f"down  {DAEMON_URL}  ({exc})")
        return EXIT_DOWN
    if a.json:
        print(json.dumps(body, indent=2))
        return EXIT_OK
    q = body.get("queue") or {}
    print(f"{body.get('status', '?')}  voice-say {body.get('version', '?')}  {DAEMON_URL}")
    print(f"queue: {q.get('waiting', 0)} waiting"
          + (f", episode running {int(q['episode_running_s'])} s" if q.get("episode_running_s") else ""))
    al = body.get("alignment")
    if al:
        print("alignment: " + ("off" if not al.get("on") else
              f"aligning {al['running']}, {al.get('waiting', 0)} waiting" if al.get("running")
              else "idle"))
    for bid, st in (body.get("backends") or {}).items():
        print(f"backend {bid}: {st}")
    return EXIT_OK


def cmd_history(a: argparse.Namespace) -> int:
    # Soft-deleted rows are hidden client-side (the newest rows are often the
    # ones just deleted), so fetch a wide window (1000) and cut afterwards.
    fetch = a.limit if a.all else 1000
    body = _request("GET", "/history", params={"limit": fetch, "series": a.series})
    if not a.all:
        body["entries"] = [e for e in body["entries"]
                           if not (e.get("overlay") or {}).get("deleted")][: a.limit]
        body["total"] = len(body["entries"])
    _print_entries(body, a.json)
    return EXIT_OK


def cmd_search(a: argparse.Namespace) -> int:
    body = _request("GET", "/search", params={"q": a.query, "limit": a.limit})
    _print_entries(body, a.json)
    return EXIT_OK


def cmd_tags(a: argparse.Namespace) -> int:
    if a.check:
        unknown, known = check_tags(a.check)
        if unknown:
            return _refuse_unknown(unknown, known)
        print("ok: " + ", ".join(normalize_tag(t) for t in a.check))
        return EXIT_OK
    tags = _request("GET", "/tags").get("tags", [])
    if a.json:
        print(json.dumps(tags))
    else:
        print("\n".join(tags) if tags else "(no tags in use)")
    return EXIT_OK


def cmd_voices(a: argparse.Namespace) -> int:
    try:
        body = _request("GET", f"/voices/{_seg(a.backend)}")
    except DaemonError as exc:
        if exc.status == 404:
            print(f"ERR: unknown backend {a.backend!r}", file=sys.stderr)
            return EXIT_REFUSED
        raise
    if a.json:
        print(json.dumps(body))
    elif body.get("voices"):
        print("\n".join(body["voices"]))
    else:
        print("(no voices listed: the backend is down or does not list its voices)",
              file=sys.stderr)
    return EXIT_OK


def cmd_restart(a: argparse.Namespace) -> int:
    """Restart a backend's launchd service through the daemon (which runs
    launchctl, so a client without launchctl access works too). Refused while
    a render runs."""
    try:
        body = _request("POST", f"/backends/{_seg(a.backend)}/restart", timeout=60)
    except DaemonError as exc:
        if exc.status == 404:
            print(f"ERR: unknown backend {a.backend!r}", file=sys.stderr)
            return EXIT_REFUSED
        if exc.status == 409:
            print(f"ERR: {exc}", file=sys.stderr)
            return EXIT_REFUSED
        raise
    if a.json:
        print(json.dumps(body))
    else:
        state = f"up after {body.get('waited_s', 0)} s" if body.get("up") else \
            f"not answering after {body.get('waited_s', 0)} s (launchd KeepAlive may still bring it up)"
        print(f"restarted {body.get('backend')} ({body.get('label')}): {state}")
    return EXIT_OK if body.get("up") else EXIT_DAEMON_ERROR


def _trash(path: str) -> str:
    """Move an archive file to the Trash the way the app does (never rm).
    Returns a one-line note for the user."""
    if not path or not os.path.exists(path):
        return "file: not on disk (already gone)"
    tool = shutil.which("trash")
    if not tool:
        return f"file: kept — no `trash` command on PATH ({path})"
    r = subprocess.run([tool, path], capture_output=True, text=True)
    if r.returncode != 0:
        return f"file: NOT trashed ({r.stderr.strip() or r.returncode}) — {path}"
    return f"file: moved to Trash ({os.path.basename(path)})"


def cmd_set(a: argparse.Namespace) -> int:
    payload: dict[str, Any] = {}
    if a.title is not None:
        payload["title"] = a.title
    if a.no_title:
        payload["title"] = ""
    if a.star:
        payload["starred"] = True
    if a.unstar:
        payload["starred"] = False
    if a.delete:
        payload["deleted"] = True
    if a.undelete:
        payload["deleted"] = False
    if a.clear_tags:
        payload["tags"] = []
    elif a.tag:
        payload["tags"] = a.tag
    if a.remove_tag:
        payload["removed_tags"] = a.remove_tag
    if a.series is not None:
        payload["series"] = a.series
    if a.no_series:
        payload["series"] = ""
    if a.episode is not None:
        if a.episode < 0:
            print("ERR: --episode must be a whole number >= 0", file=sys.stderr)
            return EXIT_REFUSED
        payload["episode"] = a.episode
    if not payload:
        print("ERR: nothing to set — pass at least one of the set flags (voice-say set --help)",
              file=sys.stderr)
        return EXIT_USAGE

    to_check = list(a.tag or []) + list(a.remove_tag or [])
    if to_check and not a.allow_new_tags:
        unknown, known = check_tags(to_check)
        if unknown:
            return _refuse_unknown(unknown, known, remedy="--allow-new-tags")

    entry = None
    if a.delete and not a.keep_file:
        # The row's file, before the overlay write: the same order the app
        # should use (overlay first, then the file) is kept below. /history is
        # the only route that names the file, and it holds the newest rows only.
        hist = _request("GET", "/history", params={"limit": HISTORY_MAX})
        entry = next((e for e in hist.get("entries", []) if e.get("ts") == a.ts), None)

    row = _request("POST", f"/overlays/{_seg(a.ts)}", body=payload)
    if a.json:
        print(json.dumps(row, indent=2, ensure_ascii=False))
    else:
        bits = [f"ts: {row.get('ts', a.ts)}"]
        if "title" in payload:
            bits.append(f"title: {row.get('title') or '(derived)'}")
        if "starred" in payload:
            bits.append("starred" if row.get("starred") else "unstarred")
        if "deleted" in payload:
            bits.append("deleted" if row.get("deleted") else "restored")
        if "tags" in payload:
            bits.append(f"tags: {', '.join(row.get('tags') or []) or '(none)'}")
        if "removed_tags" in payload:
            bits.append(f"removed: {', '.join(row.get('removed_tags') or []) or '(none)'}")
        if "series" in payload or "episode" in payload:
            bits.append(f"series: {row.get('series') or '(none)'}"
                        + (f" · episode {row['episode']}" if row.get("episode") is not None else ""))
        print("\n".join(bits))
    if a.delete and not a.keep_file:
        # Under --json stdout stays one JSON document.
        note = (_trash(entry.get("archive_path") or "") if entry is not None else
                f"file: kept — the entry is not among the newest {HISTORY_MAX} renders, "
                "so its file was not found; move it to the Trash by hand")
        print(note, file=sys.stderr if a.json else sys.stdout)
    if a.undelete:
        print("note: a file moved to the Trash on delete is not put back — restore it by hand "
              "if it is gone from the archive", file=sys.stderr)
    return EXIT_OK


# -------------------------------------------------------------- parser --

def _unaligned(e: dict[str, Any]) -> bool:
    """No word points yet: no seam_map, or only chunk seams (well under one
    point per four words)."""
    seam = e.get("seam_map") or []
    return len(seam) < max(2, (e.get("words") or 0) // 4)


def cmd_align(a: argparse.Namespace) -> int:
    if a.ts:
        targets = list(a.ts)
    else:
        rows = _request("GET", "/history", params={"limit": HISTORY_MAX})["entries"]
        targets = [e["ts"] for e in rows
                   if not (e.get("overlay") or {}).get("deleted")
                   and (e.get("duration_s") or 0) >= a.min_seconds and _unaligned(e)]
        targets = targets[: a.limit] if a.limit else targets
    failed = 0
    for n, ts in enumerate(targets, 1):
        try:
            body = _request("POST", f"/align/{_seg(ts)}", timeout=1800.0)
            print(f"[{n}/{len(targets)}] {ts}: {body['points']} word points")
        except DaemonError as exc:
            failed += 1
            print(f"[{n}/{len(targets)}] {ts}: {exc}", file=sys.stderr)
            if exc.status == 503:
                return EXIT_DAEMON_ERROR
    return EXIT_DAEMON_ERROR if failed else EXIT_OK


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="voice-say",
        description="Make audio with `render`; work the voice-say library with the rest: "
                    "find, search, tag, retitle, star, delete.",
        epilog="Exit codes: 0 ok · 1 daemon error · 2 usage · 4 refused (unknown tag, bad value) "
               "· 6 daemon unreachable; render adds 3 render failed · 7 timed out. "
               "Daemon: VOICE_SAY_DAEMON_URL (default http://127.0.0.1:8890).")
    p.add_argument("--version", action="version", version=f"voice-say {__version__}")
    sub = p.add_subparsers(dest="cmd", required=True, metavar="COMMAND")

    # Listed for --help only: main() hands `render` to the script before parsing.
    sub.add_parser("render", help="render text, save it to the library, play it "
                                  "(flags and rules: voice-say render --help)")

    s = sub.add_parser("health", help="daemon status; --deep probes each backend")
    s.add_argument("--deep", action="store_true")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_health)

    s = sub.add_parser("history", help="recent renders, newest first (or a series in episode order)")
    s.add_argument("--series", help="only this series, in episode order")
    s.add_argument("--limit", type=int, default=50)
    s.add_argument("--all", action="store_true", help="include soft-deleted rows")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_history)

    s = sub.add_parser("search", help="full-text search over transcripts")
    s.add_argument("query")
    s.add_argument("--limit", type=int, default=20)
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_search)

    s = sub.add_parser("tags", help="tags in use; --check TAG... exits 4 if any is unknown")
    s.add_argument("--check", nargs="+", metavar="TAG")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_tags)

    s = sub.add_parser("voices", help="voices of one backend")
    s.add_argument("backend")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_voices)

    s = sub.add_parser("restart", help="restart one backend's launchd service (refused while a render runs)")
    s.add_argument("backend")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_restart)

    s = sub.add_parser("set", help="change one entry: title, star, delete, tags, series, episode")
    s.add_argument("ts", help="entry id (the ts column of history/search)")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--title")
    g.add_argument("--no-title", action="store_true", help="back to the transcript-derived title")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--star", action="store_true")
    g.add_argument("--unstar", action="store_true")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--delete", action="store_true",
                   help="soft-delete (hidden in the app) and move the audio file to the Trash")
    g.add_argument("--undelete", action="store_true")
    s.add_argument("--keep-file", action="store_true", help="with --delete: leave the audio file in place")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--tag", action="append", metavar="TAG",
                   help="replace the entry's tags with these (repeatable; existing tags only)")
    g.add_argument("--clear-tags", action="store_true")
    s.add_argument("--remove-tag", action="append", metavar="TAG",
                   help="hide these render-time tags on the entry (repeatable)")
    g = s.add_mutually_exclusive_group()
    g.add_argument("--series")
    g.add_argument("--no-series", action="store_true", help="take the entry out of its series")
    s.add_argument("--episode", type=int)
    s.add_argument("--allow-new-tags", action="store_true", help="coin a tag not yet in use")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_set)

    s = sub.add_parser("align", help="measure word timings for the reader's highlight "
                                     "(new renders get them automatically)")
    s.add_argument("ts", nargs="*", help="entry ids; none = every unaligned entry, newest first")
    s.add_argument("--limit", type=int, default=0, help="with no ids: align at most this many")
    s.add_argument("--min-seconds", type=float, default=15.0,
                   help="with no ids: skip renders shorter than this (default 15)")
    s.set_defaults(fn=cmd_align)
    return p


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["render"]:
        if not os.access(RENDER, os.X_OK):
            print(f"ERR: render script not found at {os.path.normpath(RENDER)}", file=sys.stderr)
            return EXIT_REFUSED
        os.execv(RENDER, [RENDER, *argv[1:]])
    args = build_parser().parse_args(argv)
    try:
        return int(args.fn(args))
    except DaemonDown as exc:
        print(f"ERR: voice-say daemon unreachable at {DAEMON_URL} ({exc})\n"
              "     Start it with `make run` in the voice-say repo.", file=sys.stderr)
        return EXIT_DOWN
    except DaemonError as exc:
        print(f"ERR: {exc}", file=sys.stderr)
        return EXIT_DAEMON_ERROR


if __name__ == "__main__":
    sys.exit(main())
