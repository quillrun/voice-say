# ADR-0007: Cut the vault sidecar; one SQLite store for the full transcript

Remove the vault-sidecar feature entirely and consolidate the three JSONL files
into a single SQLite database (`voice.db`, WAL) that holds the full transcript.
Audio stays on disk as files.

- **Status:** Accepted (v0.6.0)

## Context

Every render historically produced **three** artefacts: the audio file, a vault
sidecar `.md` (full transcript + duplicated metadata, written under a
`vault_root`), and a row in `voice-history.jsonl` (which only held a 200-char
`text_excerpt`). State lived across **three** JSONL files —
`voice-history.jsonl` (append-only), `voice-progress.jsonl` and
`voice-overlays.jsonl` (latest-wins) — plus a hand-rolled `fcntl` lock and
compaction layer to keep them honest.

This was three sources of truth for one record. The full transcript existed only
in the sidecar, the excerpt only in the JSONL, and metadata was duplicated
between them. The sidecar was gated by `says_threshold_chars` (default 400),
the `/say` skill carried `--vault`/`--no-vault` flags, and `/render` took a
`save_vault` param — surface area whose only job was deciding whether to write a
redundant copy. Querying history meant scanning JSONL; there was no transcript
search.

## Decision

Reduce to **two** artefacts per render and **one** state store.

- **Audio stays a file.** The archive is unchanged: `voice-archive/YYYY/MM/<stem>.{mp3,wav}`,
  referenced by `archive_path`.
- **One SQLite store.** `voice.db` lives at `<data_root>/voice.db` in **WAL**
  mode and holds the **full transcript** plus all metadata. Tables: `renders`
  (append-only, including the full `text`), `progress`, `overlays`, and an
  **FTS5** virtual table `renders_fts` over the transcript. No vault, no
  sidecars, no JSONL, no `fcntl` locking, no compaction. There is no
  `vault_root` and no `sidecar_policy` anymore.
- **Render `kind`.** Each render is classified at render time: **`"say"`** when
  `len(text) <= say_threshold_chars` (default **280**), else **`"render"`**.
  "Says" are short utterances/status pings; the app surfaces them as a built-in
  category. The setting is `say_threshold_chars` (env
  `SAY_MCP_SAY_THRESHOLD_CHARS`, toml `say_threshold_chars`) and **replaces** the
  old `says_threshold_chars`/sidecar gate.
- **Transcript search.** `GET /search?q=<query>&limit=<n>` runs FTS5 over
  transcripts (newest-first) and returns the same `{entries, total}` shape as
  `/history`. A corresponding capability is exposed to the macOS app.

Removed surface: the `/say` `--vault`/`--no-vault` flags; the `/render`
`save_vault` body param; `/health` `vault_root` + `sidecar_mode` (now reports
`db_path` + `archive_root`); `/config` `says_threshold_chars` + `sidecar_policy`
+ `vault_root` (now reports `say_threshold_chars` + `db_path`). The MCP
`RenderResult`/`HistoryEntry` now carry `kind` + full `text` (no `vault_path`,
no `text_excerpt`).

## Consequences

**Positive**

- One source of truth per record — the full transcript and metadata live in one
  row, no excerpt/sidecar divergence.
- SQLite + WAL gives concurrent reads, atomic writes, and crash safety for free —
  the hand-rolled lock/compaction layer is gone.
- FTS5 makes transcripts searchable (`/search`) without scanning files.
- Smaller surface: three flags/params and several `/health`+`/config` fields
  removed; `kind` replaces a threshold whose only purpose was gating a sidecar.

**Negative / costs**

- One-time migration from the three JSONL files (+ existing sidecars, for the
  full transcript) into `voice.db`.
- The transcript is no longer a human-readable `.md` in the vault; reading it
  back means querying the store rather than opening a file.
- WAL adds `-wal`/`-shm` companion files alongside `voice.db`.
