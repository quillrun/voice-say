# CLI

One command, a thin client of the local daemon: `voice-say render` renders text to speech and plays it, and the other `voice-say` commands work the library (find, search, tag, retitle, star, delete). Both are installed by `cli/install.sh` next to `voice-ctl`. `VOICE_SAY_DAEMON_URL` names the daemon URL (the pre-2026-10-26 names, `SAY_MCP_*` and `SAY_DEFAULT_*`, are still read when the new one is unset).

# `voice-say render`

A small bash front end that renders text to speech and plays it, all through the local daemon.

`voice-say render` is the fastest way to turn text into spoken audio from a terminal. It is a thin client: it sends your text to the voice-say daemon at `http://127.0.0.1:8890`, the daemon renders and archives the audio, and `voice-say render` plays it back. Because the daemon owns the render pipeline, audio produced from the CLI lands in the same archive and history as audio produced from the macOS app or from `voice-say`-managed scripts.

> **Prerequisite:** the daemon must be running (`make run`), and the backend it targets must already be up as its own service. If the daemon is unreachable, `voice-say render` exits with code `6`.

## Usage

```
voice-say render [flags] "text to speak"
voice-say render [flags] --file=path/to/text.txt
```

A flag that takes a value accepts it after `=` or as the next word: `--file=notes.txt` and `--file notes.txt` are the same. The examples use `=`.

By default `voice-say render` renders on the configured default backend/voice and plays the result immediately.

## Flags

| Flag | Argument | Description |
|---|---|---|
| `--voice` | `<voice-id>` | Voice to render with. Defaults to the backend's default voice. |
| `--speed` | `<float>` | Playback rate. Honoured only by speed-capable backends; ignored otherwise. |
| `--format` | `mp3` \| `wav` \| `pcm` | Extension for the `--out` file. The CLI does **not** send a format to the daemon — the actual encoding is backend-determined; this only sets the output filename's extension. Without `--out` or `--format`, the file takes the extension of the audio the daemon stored (`.wav` from a WAV backend). |
| `--out` | `<path>` | Also write the rendered audio to this path. |
| `--file` | `<path>` | Read the text to render from a file instead of an argument. |
| `--no-play` | — | Render and archive only; do not play back. |
| `--json` | — | Print one JSON object on stdout — `{id, path, out, title, duration_s, backend, voice, kind, playing}` (`id` is the row's `ts`, `path` the archived file, `out` the copy) — and send every other line to stderr. Refused (exit 4) with `--fast`, which makes no library row. |
| `--stop` | — | Stop any currently playing audio and exit. |
| `--seek` | `±N` | Seek the current playback by N seconds (e.g. `--seek=+15`, `--seek=-10`). |
| `--toggle` | — | Toggle play/pause on the current playback. |
| `--tag` | `<name>` | Attach a tag to the render. **Repeatable.** The tag must already be in use (see `voice-say tags`); an unknown tag exits `4` and names the nearest existing ones. |
| `--new-tag` | `<name>` | Like `--tag`, but coins a tag that is not yet in use, on purpose. Repeatable. |
| `--title` | `<str>` | Set a durable overlay title for the render (sent with the render request), so the UI shows it instead of the first-sentence auto-title. **Required** for text over the daemon's say threshold (exit `4`). |
| `--title-from` | `<path.md>` | Same as `--title`, but reads the title from the file's first `# ` heading. `--title` wins if both are given. |
| `--series` | `<str>` | Put the render in a series (the app lists a series in episode order). |
| `--episode` | `<n>` | Episode number within `--series`, a whole number ≥ 0 (anything else exits `4` before rendering). |
| `--backend` | `<backend-id>` | Speech backend id, e.g. `kokoro` (`voice-say health --deep` lists them). Defaults to the daemon's configured default. See [Backends](../setup/backends.md). |
| `--stream` | — | Force the chunked longform render path (`POST /render_longform`) regardless of length. Long text (over `VOICE_SAY_RENDER_STREAM_THRESHOLD`, default ~1200 chars) auto-uses this path even without the flag. |
| `--fast` | — | Stream audio from the fast backend (`VOICE_SAY_RENDER_FAST_BACKEND`, else the daemon's `default_backend`) straight to the player via `cli/voice-say-stream`, bypassing the daemon archive — first word in ~0.2 s on a warm Kokoro instead of a full render round-trip. Once the backend answers, it continues in the background and returns (a backend that is down exits `6` in the foreground). `--voice=` picks the voice, else the backend's default. An explicit `--backend=` overrides it and keeps the normal archived path. |
| `--wait` | — | With `--fast`, stay in the foreground and block until playback finishes instead of auto-backgrounding (needed for half-duplex callers, e.g. an open-mic loop, so the mic isn't re-armed mid-reply). No effect without `--fast`. |

### Notes on behaviour

- **Kind.** Every render is classified at render time into a `kind`: text at or below the daemon's say threshold (`say_threshold_chars`, default 280 characters) is a `say` — a short utterance or status ping — while longer text is a `render` (see [Configuration](../setup/configuration.md)). The full transcript and metadata are stored either way; there is no flag to toggle this — it follows from the text length.
- **Title rule.** Text longer than the daemon's say threshold (`say_threshold_chars`, read from `GET /config`) is a library entry, not a ping, so it needs a title (`--title` or `--title-from`). Without one `voice-say render` exits `4` and renders nothing. Short text needs no title.
- **Tag rule.** Tags are normalized (lowercase; spaces/underscores → hyphens; only `a-z0-9-` kept; hyphen runs collapsed and trimmed — the same rule as the app). Every `--tag` must already be in use: `voice-say render` checks them with `voice-say tags --check` against `GET /tags`. An unknown tag exits `4` before rendering, naming the nearest existing tags; `--new-tag=<name>` coins one on purpose. In closed-vocabulary mode (when `allowed_tags` is set in config), a tag outside the list is still rejected by the daemon (the render fails with exit `3`).
- **Pronunciation.** Fixes for words the voice mispronounces live in the daemon config's `[pronounce]` table (see `daemon/config.example.toml`), not in the text you pass.
- **Titles.** `--title` / `--title-from` / `--series` / `--episode` ride on the render request; against an older daemon that ignores them the CLI sets them with `POST /overlays/<ts>` after the render. That follow-up is best-effort: a failed write only warns on stderr and the run still exits `0`. The old warning for a missing title on long text is gone, because a missing title is now a refusal (exit `4`).
- **Failures.** A failed render prints the daemon's stage and message; when the finished part of a longform render was kept, a `kept: draft <ts>` line names it.
- **Playback control flags** (`--stop`, `--seek`, `--toggle`) act on the current playback session rather than rendering new text. They don't require a text argument.
- **Format.** `--format` only sets the extension of the `--out` file; it does not change what the daemon renders (the encoding is backend-determined). Without it, the default `--out` file takes the stored audio's extension.
- **Streaming / longform.** Text longer than the stream threshold (default 1200 characters, configurable via `VOICE_SAY_RENDER_STREAM_THRESHOLD`) is rendered through the longform endpoint automatically, even without `--stream`.
- **Fast path (`--fast`).** Unlike `--stream` (still archived, just chunked), `--fast` bypasses the daemon archive entirely: it reads the backend's url and model from `GET /config` and sends `POST /v1/audio/speech` with `stream: true, response_format: "pcm"` straight to the backend, piping the 16-bit mono PCM into the player (rate from a `rate=` in the Content-Type, else 24 kHz). mlx-audio's server streams this way. Nothing is written to `voice.db` on this path — `--tag`/`--title` don't apply. Use `--backend=<id>` (the normal `/render` path) for an archived, tagged render on the same backend.
- **Emotion tags.** On backends without emotion support (`supports_emotion_tags: false`, e.g. `kokoro`), inline `[emotion]`-style bracket tags are stripped by the daemon before synthesis (the CLI does not strip them itself). On backends with `supports_emotion_tags: true` the bracket text is left intact so the backend can interpret it.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `2` | No text provided (no positional argument and no `--file`), or the `--file` is missing or unreadable |
| `3` | Pipeline failure — the render itself failed (e.g. the backend errored, or a tag was rejected in closed-vocab mode) |
| `4` | Refused before rendering — `mpv` or `voice-ctl` missing for a render that plays (`--no-play` needs neither), unknown flag, malformed `--seek` or `--episode` value, a missing title on text over the say threshold, or an unknown `--tag` (use `--new-tag` to coin one) |
| `6` | Daemon unreachable — could not connect to the daemon at `127.0.0.1:8890` |
| `7` | Timed out — no reply within the timeout (1 s per 10 characters, at least 600 s; `VOICE_SAY_RENDER_TIMEOUT` overrides). A render that had started is finished and archived by the daemon, so check history before retrying; one still queued behind another render is dropped |

These map onto the daemon's behaviour: a `3` corresponds to a failed render (a `4xx`/`5xx` from `POST /render` (or `POST /render_longform` for `--stream`/long text)), and a `6` to the daemon not answering at all. Scripts can branch on these codes — for example, retry on `6` (daemon still warming up) but surface `3` to the user.

## Examples

Render and play a one-liner with the defaults:

```bash
voice-say render "Build finished successfully."
```

Pick a specific backend and voice:

```bash
voice-say render --backend=kokoro --voice=bm_george "Good morning."
```

Render a longer document from a file and tag it (it is stored as a `render`, since it exceeds the say threshold, so it needs a title; the tag must already exist):

```bash
voice-say render --file=./notes/briefing.txt --title="Weekly briefing" --tag=briefing
```

Render without playing (archive only), and also save a copy to a path:

```bash
voice-say render --no-play --out=./out/welcome.wav --format=wav "Welcome aboard."
```

Attach multiple tags (repeat `--tag`):

```bash
voice-say render --tag=briefing --new-tag=draft "Draft of the weekly briefing."
```

Control the current playback:

```bash
voice-say render --toggle        # pause / resume
voice-say render --seek=+15      # jump forward 15 seconds
voice-say render --seek=-10      # jump back 10 seconds
voice-say render --stop          # stop playback and exit
```

Instant low-latency playback, unarchived:

```bash
voice-say render --fast "Quick reply."
```

Branch on the exit code in a script:

```bash
if voice-say render --no-play "Nightly summary ready."; then
  echo "rendered"
else
  case $? in
    3) echo "render failed" ;;
    6) echo "daemon down — start it with 'make run'" ;;
  esac
fi
```

# `voice-say`

The library CLI: it works the history behind the daemon's HTTP API. Everything goes through the daemon, never the database, so the same render gate, overlay rules and SSE events apply as for the app. Rendering and playback are `voice-say render` (above). It needs only Python's standard library on 3.11+ (3.10 also needs `tomli`), so it runs without the daemon's venv; if the daemon is unreachable it exits `6`.

```
voice-say health [--deep] [--json]
voice-say history [--series NAME] [--limit N] [--all] [--json]
voice-say search QUERY [--limit N] [--json]
voice-say tags [--check TAG ...] [--json]
voice-say voices BACKEND [--json]
voice-say restart BACKEND [--json]
voice-say align [TS ...] [--limit N] [--min-seconds S]
voice-say set TS [flags] [--json]
```

## Subcommands

| Command | What it does |
|---|---|
| `health` | Daemon status, version, queue and per-backend state. `--deep` probes each backend. Exits `6` when the daemon is down. |
| `history` | Recent entries, newest first, default `--limit 50`. `--series NAME` lists one series in episode order. Soft-deleted entries are hidden unless `--all` is given. |
| `search QUERY` | Full-text search over transcripts (FTS5 `/search`), default `--limit 20`. |
| `tags` | Prints the tags in use, one per line. `--check TAG ...` tests tags instead: exit `0` and `ok: ...` if all are in use, exit `4` and the nearest existing tags if not (this is what `voice-say render` calls). |
| `voices BACKEND` | Prints the voices of one backend, one per line. An unknown backend exits `4`. |
| `restart BACKEND` | Asks the daemon to restart one backend's service. Works only for a backend whose catalog entry names a launchd `service` (see [Backends](../setup/backends.md)); refused (exit `4`) for an unknown backend, a backend with no service, or while a render runs. Exits `1` if the backend is not answering afterwards. |
| `align [TS ...]` | Measures word timings for the reader's highlight (new renders get them automatically when read-along is on). With no ids it aligns every entry that has none yet, newest first, skipping renders shorter than `--min-seconds` (default 15); `--limit N` caps how many. Exits `1` if any fails. |
| `set TS` | Changes one entry; `TS` is the id in the first column of `history` and `search`. At least one change flag is required (else exit `2`). |

`--json` on any command that has it prints the daemon's raw JSON instead of the text form (`align` has none).

## `set` flags

| Flag | Effect |
|---|---|
| `--title T` / `--no-title` | Set the title, or go back to the transcript-derived one. |
| `--star` / `--unstar` | Star or unstar. |
| `--delete` / `--undelete` | Soft-delete (hidden in the app) and move the audio file to the Trash, like the app does; or restore the entry. A file already in the Trash is not put back. |
| `--keep-file` | With `--delete`: leave the audio file in place. |
| `--tag T` (repeatable) / `--clear-tags` | Replace the entry's tags with these, or remove them all. Only tags already in use. |
| `--remove-tag T` (repeatable) | Hide these render-time tags on the entry. |
| `--allow-new-tags` | Let `--tag` coin a tag not yet in use. |
| `--series S` / `--no-series` | Put the entry in a series, or take it out. |
| `--episode N` | Episode number, a whole number >= 0. |

Before any write, `set` checks `--tag` and `--remove-tag` against `GET /tags`. An unknown tag exits `4` with `ERR: unknown tag(s) ... nearest existing: ...`, and nothing is changed.

## Output

`history` and `search` print one line per entry, with a count on stderr:

```
<ts>  <star><deleted> <kind> <m:ss>  <title>  [series · episode]  #tag #tag
```

`★` marks a starred entry and `✗` a soft-deleted one. `set` prints one `key: value` line per change (`ts`, `title`, `starred`, `deleted`, `tags`, `removed`, `series`), then a `file:` line after `--delete` saying whether the audio file was moved to the Trash (on stderr under `--json`, so stdout stays one JSON document). The file is looked up among the newest 5000 renders; an older entry is soft-deleted and its file is kept, with a `file: kept` line saying so.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Success |
| `1` | The daemon answered with an error |
| `2` | Usage error (bad arguments, or `set` with nothing to set) |
| `4` | Refused before the request: unknown tag, bad value (e.g. a negative `--episode`), or unknown backend |
| `6` | Daemon unreachable |

## Examples

Find a ts, then retitle it:

```bash
voice-say history --series "Daily Notes"
voice-say set 2026-10-19T09-14-02 --title "Daily Notes 17: Post-training"
```

Search transcripts:

```bash
voice-say search "post-training"
```

See which tags exist, then tag an entry (replacing its tags):

```bash
voice-say tags
voice-say set <ts> --tag briefing --tag draft
```

Coin a new tag on purpose:

```bash
voice-say set <ts> --tag fresh --allow-new-tags
```

Delete an entry (soft-delete, audio file to the Trash):

```bash
voice-say set <ts> --delete
voice-say set <ts> --delete --keep-file   # keep the audio file
```
