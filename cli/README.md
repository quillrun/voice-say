# `voice-say` — the CLI

`voice-say render` renders text to speech through the voice-say daemon, then
plays it headlessly via mpv with an IPC socket for control (the script is
`voice-say-render`). The other `voice-say` commands work the library behind
the daemon: find, search, tag, retitle, star, delete.

## Install

```bash
bash install.sh         # symlinks `voice-say` and `voice-ctl` into ~/.local/bin
```

Prerequisites:
- `mpv` — only for renders that play: `brew install mpv` (macOS) / `apt install mpv` (Debian/Ubuntu)
- `socat` — `brew install socat` / `apt install socat`
- `python3` — for the JSON helpers and the library commands (standard library only on 3.11+;
  3.10 also needs `tomli`)
- a TTS backend reachable from the daemon (see `../docs/setup/backends.md`)
- the `voice-say` daemon running on `127.0.0.1:8890` (override with
  `VOICE_SAY_DAEMON_URL`)

## Usage of `voice-say render`

```bash
voice-say render "hello world"                       # render + play, configured default backend
voice-say render --backend=kokoro "hello"            # a named backend
voice-say render --voice=default "hello"             # specific voice
voice-say render --no-play "long article…"           # render only
voice-say render --json --no-play "…"                # one JSON line: id, path, title, duration_s, …
voice-say render --stream "long article…"            # force chunked longform endpoint
voice-say render --fast "quick reply"                 # instant streaming playback from the fast backend, unarchived
voice-say render --fast --wait "quick reply"          # same, but block until playback finishes (half-duplex callers)
voice-say render --file=/tmp/script.txt              # read text from a file
voice-say render --tag=todo --tag=ep01 "…"           # tags stored with the render (existing tags only)
voice-say render --new-tag=fresh "…"                 # coin a new tag on purpose
voice-say render --title="Ep 17 — Post-Training" …   # the library title
voice-say render --file=ep-17.body.txt --title-from=ep-17.md   # title from the file's first '# ' H1
voice-say render --series="Daily Notes" --episode=17 --file=ep-17.body.txt   # lists in episode order
```

`--title` / `--title-from`, `--series` and `--episode` ride on the render
request, so the new row carries them (an older daemon gets a follow-up
`POST /overlays/<ts>`). The title replaces the `"It is a {weekday}…"`
first-sentence auto-title; `--title-from=<md>` reads the file's first `# `
heading. `--title` wins if both are given. `--episode` must be a whole number
≥ 0 (else exit 4 before rendering). None of these apply to `--fast`.

Long text (over `VOICE_SAY_RENDER_STREAM_THRESHOLD`) renders as one episode and shows live
under Rendering in the macOS app while it renders.

Control playback:

```bash
voice-say render --toggle              # play/pause
voice-say render --seek=10             # forward 10s
voice-say render --seek=-10            # back 10s
voice-say render --stop                # quit playback
```

## Env vars

The pre-2026-10-26 names (`SAY_MCP_DAEMON_URL`, `SAY_DEFAULT_BACKEND`, `SAY_DEFAULT_VOICE`,
`SAY_STREAM_THRESHOLD`, `SAY_TIMEOUT`) are still read when the new one is unset.

| Var | Default | Notes |
|---|---|---|
| `VOICE_SAY_DAEMON_URL` | `http://127.0.0.1:8890` | Where the daemon lives. |
| `VOICE_SAY_RENDER_BACKEND` | daemon's configured default | Initial backend. |
| `VOICE_SAY_RENDER_VOICE` | `default` | `default` = daemon picks. |
| `VOICE_SAY_RENDER_FAST_BACKEND` | daemon's default backend | Backend `--fast` streams from. |
| `VOICE_SAY_RENDER_STREAM_THRESHOLD` | `1200` | Text length (chars) above which `voice-say render` auto-uses the chunked longform endpoint; `--stream` forces it regardless. |
| `VOICE_CTL_CUE` | `voice-ctl-cue` on PATH | Command `voice-ctl` runs with `click` or `error` for feedback sounds; skipped when absent. |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | success |
| 2 | no text provided, or the `--file` is missing or unreadable |
| 3 | render HTTP failure |
| 4 | refused: bad flag, missing dependency, missing title for long text, unknown tag |
| 6 | voice-say daemon unreachable |
| 7 | no reply within the timeout (1 s per 10 chars, at least 600 s; `VOICE_SAY_RENDER_TIMEOUT` overrides) |

## Usage of `voice-say`

```bash
voice-say history --series "Daily Notes"      # find a ts (newest first, or a series in episode order)
voice-say search "post-training"              # full-text search over transcripts
voice-say tags                                # tags in use; `tags --check TAG...` exits 4 if any is unknown
voice-say voices kokoro                       # voices of one backend
voice-say set <ts> --title "Ep 17"            # retitle; also --star, --series, --episode, --tag, --remove-tag
voice-say set <ts> --delete                   # soft-delete and move the audio file to the Trash (--keep-file to leave it)
voice-say health --deep                       # daemon status, probes each backend
```

Tags must already be in use; `--allow-new-tags` coins one. Everything goes
through the daemon, never the database. Exit codes: 0 ok, 1 daemon error,
2 usage, 4 refused (unknown tag, bad value, unknown backend), 6 daemon
unreachable. `voice-say --help` and `voice-say set --help` list every flag.

## Agents and scripts

An agent or a script uses `voice-say` directly; `voice-say --help` and
`voice-say render --help` carry the rules (title, tags, exit codes).
[`skills/voice-say/SKILL.md`](../skills/voice-say/SKILL.md) is the same as an Agent
Skill: copy the folder into your agent's skills directory (for Claude Code,
`~/.claude/skills/`).

## See also

- `../docs/setup/backends.md` — bringing up the TTS backends
- `../docs/api/http-api.md` — daemon endpoints (incl. /search)
