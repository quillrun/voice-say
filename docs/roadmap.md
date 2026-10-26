# Roadmap

Planned work for voice-say. Everything on this page is **PLANNED** unless under "Shipped today".
Items below are direction, not commitments, and may change.

## Shipped today (baseline)

- aiohttp daemon (loopback `127.0.0.1:8890`) owning the single render path.
- Clients: the `voice-say` CLI (`render` in bash, the library commands in Python), macOS SwiftUI app.
- Backends: **kokoro** (the committed default, Kokoro-82M on mlx-audio's server) or any other
  server added as a `url` + `model` entry. All are separate services outside this repo, speaking
  the OpenAI-compatible `POST /v1/audio/speech` contract. See
  [Backends](internals/public-vs-private.md).
- **Config layer**: precedence `env > config.local.toml > config.example.toml`; only generic
  defaults are committed and every value is env-overridable. `make setup` writes the local overlay
  and puts the CLI on your PATH; launchd service definitions are rendered separately from the bundled
  `*.plist.example` templates. See [the public/private boundary](internals/public-vs-private.md).
- Render contract: permanent audio archive plus a single SQLite store (`voice.db`, WAL mode) holding
  the full transcript and all metadata across the `renders` (append-only), `progress`, and
  `overlays` tables, with an FTS5 transcript index; SSE event stream. See
  [ADR-0007](adr/0007-cut-vault-and-sqlite-store.md).

## Planned

_No planned additional UI surfaces. The **macOS SwiftUI app is the sole UI**. The daemon's opt-in
CORS support (`VOICE_SAY_CORS` / `cors_origins`) is now **dormant** — it stays off by default and
harmless; remove it only if a future cleanup confirms no non-loopback consumer will ever exist._

### Say App v1 program (2026-06-11)

Operator-approved ticket program for the app/MCP surface: taxonomy v2
(first-class categories, tag cleanup + closed vocabulary), bookmarks/transcript
UX fixes, render registry (one queue for all sources), MCP dumb-control
contract, analytics. **18 tickets** in waves; the ticket plan and its specs
(taxonomy v2, render registry) are working documents and are not published.

### App backlog (from live-testing)

In-app fixes to the existing macOS surface (not new surfaces):

- [ ] **Settings sample clips collide across backends** — two backend/voice entries can show/play
  the same sample clip in Settings. The `_samples/<voice>.mp3` preview lookup keys on voice id, so a
  voice offered on two backends resolves to one clip — fix so each Settings entry previews its own
  audio (key by backend+voice, or give each its own clip).
- [ ] **Produce per-voice sample clips** — most voices have no `_samples/<voice>.mp3`
  yet, so the picker preview falls back to the simulated waveform (play disabled). Generate the real
  clips so previews work in the app.

## Ongoing

### Tracked core stays clean of personal data

The tracked code holds **only** generic
defaults — personal voices, secrets, and machine specifics live in the untracked overlay,
never in committed files. This keeps the git history clean and the config seam honest:

- generic committed defaults (`kokoro` / `default` / loopback-only),
- no secrets or personal data in tracked files,
- local specifics isolated in the untracked config overlay,
- a per-commit hygiene gate (`make publishable-check`) that blocks violations.

Documented as [ADR-0001](adr/0001-centralize-and-publishable.md) and treated as a standing
constraint on all future work. See [the public/private boundary](internals/public-vs-private.md).
