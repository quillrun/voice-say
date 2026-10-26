# Data Model

> The artefacts voice-say produces: an on-disk audio file per render plus one SQLite store that holds the full transcript, render history, and all client state.

## Audio on disk, everything else in SQLite

Every render produces **two artefacts**: a permanent audio file on disk and a
row in the SQLite store. The audio file is named from a `<stem>` shared with its
database row.

A longform/streaming render obeys the same two-artefact contract: even though it
is chunked internally and rendered chunk-by-chunk, it collapses to exactly one
audio file (always `mp3`, regardless of the backend's native container) and one
append-only `renders` row — indistinguishable downstream from a single-shot
render.

| artefact | location | written |
|---|---|---|
| audio | `<data_root>/voice-archive/YYYY/MM/<stem>.<ext>` | every render (permanent) |
| render row | `voice.db` → `renders` (incl. full `text`) | every render (append-only) |
| playback progress | `voice.db` → `progress` | on each playback update |
| overlays | `voice.db` → `overlays` | on star / tag / bookmark / soft-delete |
| transcript index | `voice.db` → `renders_fts` (FTS5) | maintained from `renders.text` |

`<data_root>` resolves in layers: the committed `config.example.toml` default is
`./data`, and a relative path in a config file resolves against that file's
folder (so `daemon/data`); `~/.local/share/voice-say` is the in-code fallback
used only when no config TOML supplies `data_root`. `VOICE_SAY_DATA_ROOT`
overrides either, and a relative value there resolves against the directory the
daemon was started from. The SQLite store lives at `<data_root>/voice.db` and
runs in WAL mode. The full transcript lives in the `renders` row, with no
separate transcript files.

The `renders` table is the **single source of truth** for "what was rendered,"
and it carries the full transcript text. The `progress` and `overlays` tables are
pure client-state projections: clearing `progress` resets "played to here"
memory; clearing `overlays` drops stars/tags/bookmarks. Neither touches audio or
render history. The audio file on disk is the only thing kept outside the
database.

## Shared stem derivation

The audio file and its `renders` row are named from one `stem()` call, so they
always agree on a filename:

```
voice-<slug>-<utc-stamp>-<hex>
```

- `<slug>` — first up to 4 alphanumeric words of the text, lowercased and
  hyphen-joined, capped at 32 chars (empty slug is omitted).
- `<utc-stamp>` — `YYYYMMDD-HHMMSS` in UTC.
- `<hex>` — a short random suffix that guarantees no collision even when two
  renders land in the same UTC second.

Example: `voice-quarterly-revenue-review-notes-20260529-141203-9af2`.

## Render kind: `say` vs `render`

Every render is classified at render time into a `kind`: `"say"` when the text
length is `<= say_threshold_chars` (default `280`), else `"render"` (see
[Configuration](../setup/configuration.md) for the threshold key). `kind` is
stored on the `renders` row and returned with every history/render result. The
full transcript is always stored regardless of kind — short and long renders
alike keep their complete `text`.

## `renders` table

The `renders` table is append-only, one row per render, and carries the full
transcript in its `text` column. This is the canonical entry shape — the same
dict returned by `POST /render` and broadcast as the `render` SSE event:

```json
{
  "ts": "2026-05-29T14:12:03.481920Z",
  "kind": "render",
  "backend": "kokoro",
  "voice": "af_heart",
  "speed": 1.0,
  "format": "wav",
  "chars": 612,
  "words": 122,
  "duration_s": 41.3,
  "bytes": 1982444,
  "archive_name": "voice-quarterly-revenue-review-notes-20260529-141203-9af2.mp3",
  "archive_path": "~/.local/share/voice-say/voice-archive/2026/05/voice-quarterly-revenue-review-notes-20260529-141203-9af2.mp3",
  "text": "Full transcript text goes here, verbatim, as it was sent to the backend.",
  "tags": ["briefing"],
  "resume_full_text": null,
  "resume_char_offset": null,
  "render_elapsed_s": 3.7,
  "seam_map": null
}
```

Notes:

- `kind` is `"say"` when `chars <= say_threshold_chars`, else `"render"`.
- `text` is the verbatim transcript, exactly as sent to the backend — full, not
  truncated, for every render.
- `tags` is the user-supplied tags only, normalized (lowercase; spaces and
  underscores to hyphens; only `a-z0-9-` kept; hyphen runs collapsed); the backend id and `voice` are stored in their own
  columns, not folded into `tags`.
- `words` is a real whitespace-token word count of the transcript, computed
  after stripping inline `[emotion]` and `<angle>` tags (floored at 1) — not a
  `chars / 5` estimate.
- `resume_full_text` (TEXT, nullable) and `resume_char_offset` (INTEGER,
  nullable) are set **only** on a save-and-stop draft and are `NULL` for every
  normal or completed render.
- `seam_map` (TEXT JSON, nullable) holds the read-along points
  `[[audio_s, char_off], ...]`, each mapping an audio second to a transcript char
  offset: the chunk seams of a streaming render, plus a point per spoken word once
  alignment has measured the audio. It is `NULL` for a single-shot render until
  it is aligned. These columns were added
  after the first schema: on start the daemon adds any that an older `voice.db`
  lacks (checked with `PRAGMA table_info`), in place, and existing rows keep
  `NULL` in them.

### Resume columns

A save-and-stop draft records two extra fields so a partially rendered episode
can be continued later:

- `resume_full_text` — the complete source text the episode was rendering when
  it was stopped.
- `resume_char_offset` — how far into that text the rendered audio reached.

`POST /episode/resume` re-chunks `resume_full_text`, skips every chunk whose
cumulative end falls at or before `resume_char_offset`, renders only the
remainder, and merges the draft audio with the freshly rendered chunks into a
single new canonical `renders` row (the draft row is superseded). Both columns
remain `NULL` on the merged result and on every other render.

## Full-text search (`renders_fts`)

`renders_fts` is an FTS5 virtual table over the transcript `text`, kept in sync
with `renders`. It backs `GET /search?q=<query>&limit=<n>`, which runs FTS5 over
transcripts newest-first and returns the same `{entries, total}` shape as
`/history`. The macOS app exposes a corresponding transcript-search capability.

## Client-state tables

`progress` and `overlays` hold per-render client state, keyed by `ts`, latest
write wins on read. They live in the same `voice.db` (WAL mode) — no separate
files, no fcntl locking, no compaction.

### `progress`

```json
{"ts": "...", "played_s": 12.3, "duration_s": 45.6,
 "play_count": 2, "completed": false, "last_played": "..."}
```

`play_count` increments only when a write marks the start of a new playback
session; mid-playback ticks leave it unchanged. `duration_s` sticks once known.
`completed` is a **playback-completion** field, not a tag: it tracks whether a
render was *played to the end* (`played_s >= duration_s`), not whether the render
finished synthesizing. A freshly-rendered clip carries `completed=false` until
it is listened to; once played to the end it flips to `true`. This field
drives the virtual, undeletable `#completed` tag on the macOS client — the tag
appears only when `completed` is true (see [tags.md](tags.md)). Render completion
is tracked separately and is not the same thing.

### `overlays`

```json
{"ts": "...", "starred": false, "deleted": false,
 "tags": ["briefing", "draft"],
 "removed_tags": [],
 "title": null,
 "bookmarks": [{"id": "uuid", "position": 0.42, "note": "..."}],
 "last_modified": "..."}
```

The whole overlay is written on every update (small N per entry), so reads never
merge patches across rows. `deleted` is a soft-delete (hide in list, keep the
row). `starred` is an overlay boolean **mechanism**, not a tag. Bookmark
`position` is a 0.0–1.0 fraction of the track. Tag editing follows the same
open-vocabulary normalization as render-time tags (see [tags.md](tags.md)).
