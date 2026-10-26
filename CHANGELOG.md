# Changelog

All notable changes to voice-say are documented here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 2.0.1 — 2026-10-27

### Fixed
- macOS app: a daemon on another port can be set with `defaults write local.voicesay.VoiceSay voicesay.daemonURL http://127.0.0.1:<port>` (the override key was undocumented and misnamed). Render before the daemon has answered says the daemon isn't answering, instead of "unknown backend kokoro". Backends are shown and probed at the `url` the daemon reports, so one on another host no longer shows as down. A voice without a sample clip has no preview row (was a disabled button). Starting a backend with no LaunchAgent points at the `service` entry in docs/setup/backends.md. The cold-start voice is `af_heart`, Kokoro's default; the User-Agent carries the app version.
- `voice-say render --out`: the copy takes the extension of the audio the backend made, with a warning when the path named another (a `.mp3` path got WAV bytes).
- `voice-say voices` says why a list is empty.
- Docs checked against the code: tag normalization, the voices response shapes, the render-gate rule, HTTP status codes (413 over-length, 409s), `/stats`, archive names, the app's folder-access permission, align and `[pronounce]` settings, the optional retention job.

### Removed
- `voice-say render --format` (it never reached the daemon; the backend decides the format).
- The pre-rename environment names (`SAY_MCP_*`, `SAY_MOCK_*`, `SAY_DEFAULT_*`, `SAY_TIMEOUT`, `SAY_*_THRESHOLD`): only `VOICE_SAY_*` is read.
- Code paths for daemons older than 2.0.0 in `voice-say render` and `voice-say restart`.

### Changed
- `voice-ctl`: the fallback that controls other apps when no voice-say player is live is an optional `media-remote` command you provide (beside `voice-ctl`, on PATH, or `$VOICE_CTL_MEDIA_REMOTE`).
- CI runs the tests on Python 3.10 too. `pyproject.toml` lists macOS, a readme and the project URLs.
- Contributing: a pull request needs `make test` (and the Swift tests for app changes); bugs and ideas go to the issues.

## 2.0.0 — 2026-10-26

First public release.
