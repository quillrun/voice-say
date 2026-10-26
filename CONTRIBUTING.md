# Developing voice-say

Pull requests are welcome, and so are bug reports and ideas as issues. Security reports go
through [SECURITY.md](SECURITY.md), not a public issue.

- For anything bigger than a fix, open an issue first so the approach is agreed before you build it.
- A pull request needs `make test` to pass, and `swift test` in `clients/macos` when it changes the app.
- Keep credentials out of commits: GitHub secret scanning and push protection are on for this
  repository and block a recognised secret.
- CI runs on a first-time contributor's pull request after a maintainer approves the run.
- Contributions are under the [licence](LICENSE) (MIT).

The rest of this file is dev notes: how to set up a dev environment, run the tests, and add a
backend.

voice-say is a local-only text-to-speech system: one Python daemon owns the render pipeline, and
thin clients (the `voice-say` CLI, with `render` to make audio, and a macOS app) funnel through it.
Changes should preserve the **single render path**: every render goes through the daemon's engine.
Keep secrets, machine paths and personal data out of committed files; your own settings go in
`daemon/config.local.toml` and your own backends in a catalog file outside the repo (see
[Configuration](docs/setup/configuration.md)), both untracked.

## Dev setup

Requires Python 3.10–3.12 (CI tests all three). `make setup` does the following for you; by
hand, the daemon package lives in `daemon/`, so install from there:

```bash
cd daemon
python3.12 -m venv .venv
.venv/bin/pip install -e ".[dev]"
```

The `[dev]` extra pulls in `pytest`, `pytest-asyncio` and `pytest-aiohttp`. The core daemon depends only on
`aiohttp`, `httpx`, `mutagen` (mp3 duration probe) and `tomli-w` (config writer), plus `tomli` on
Python 3.10. Two console entry points are installed into `daemon/.venv`:

| command | what it runs |
|---|---|
| `voice-say-daemon` | the aiohttp daemon (loopback `127.0.0.1:8890`) |
| `voice-say` | the library CLI (proxies the daemon over HTTP) |

Start the daemon first; all clients require it to be running.

## Running the test suite

```bash
cd daemon
.venv/bin/pytest
```

`pytest` is configured in `daemon/pyproject.toml` with `asyncio_mode = "auto"` and
`testpaths = ["tests"]`, so a bare invocation discovers everything. The suite covers the engine
render contract, the HTTP routes (incl. FTS5 `/search`), the `voice-say` CLI (`render` included) against a mock daemon, overlays, playback progress,
retention, daemon state, and security (CORS + audio path-traversal + slow-subscriber drop). Backends
are external HTTP services; tests stub the backend call rather than hitting a live model, so the
suite runs offline with no model weights present. Run a single module while iterating:

```bash
.venv/bin/pytest tests/test_engine.py -q
```

The macOS client carries its own Swift Testing suite (`import Testing`), run from the package root
with the full Xcode toolchain — it exercises the real app types via `@testable import VoiceSay`:

```bash
cd clients/macos
swift test
```

## Code layout

```
daemon/voice_say/         daemon package (the one render path)
  engine.py               render pipeline: backend call → 2 artefacts + events
  http_server.py          aiohttp app wiring + entry point (main)
  _routes_*.py            render / history / meta route handlers
  _sinks.py / _db.py      artefact writers (archive, voice.db) + SQLite helpers
  cli.py                  the voice-say library CLI (urllib, proxies the daemon)
cli/                      voice-say (+ voice-say-render, voice-say-stream) + voice-ctl
clients/macos/            VoiceSay — native SwiftUI app
docs/                     architecture, HTTP/CLI reference, setup
```

All routes ultimately call `engine.render()`, so the on-disk render contract lives in exactly one
place. See [`docs/internals/architecture.md`](docs/internals/architecture.md) for the deep walkthrough.

## How to add a backend

Backends are pluggable HTTP services that speak the OpenAI-compatible speech contract. The daemon
never imports a backend in-process; it POSTs to one.

1. **Implement the contract.** Accept `POST /v1/audio/speech` with an OpenAI-style JSON body
   (model/voice/input/response_format) and return raw audio bytes. Run it on a fixed loopback port.
2. **Register it.** Add an entry with its `url` and `model` to the JSON file that
   `VOICE_SAY_BACKENDS_CONFIG` points at ([backends.md](docs/setup/backends.md#adding-a-backend)).
   It then appears in `GET /backends`, its voices in `GET /voices/{backend_id}`, and it becomes
   selectable via the `backend` argument on `POST /render` (and `--backend=` on the CLI).
3. **Verify end to end:**

   ```bash
   voice-say render --no-play --backend=my-backend "hello from the new backend"
   ```

   Confirm both artefacts (the archive file and the `renders` row in `voice.db`) were written.

Keep committed defaults generic. If your backend is the new default for a class of hardware, change
the default only in the example config, never hard-coded.

## Style

- **Python:** `from __future__ import annotations`; type hints on public APIs; functions ≤ ~40 lines
  where reasonable; no `import *`.
- **Bash:** `set -euo pipefail`; quote variables; `[[` inside `bash`, `[` inside `sh`.

## Commit messages

```
[tag]: short imperative summary

Optional longer explanation. Wrap at 72 columns.
```

Tags: `daemon`, `cli`, `docs`, `ci`, `tests`, `chore`.

## Versioning

[Semantic Versioning](https://semver.org/). Bump `version` in `daemon/pyproject.toml` and
`__version__` in `daemon/voice_say/__init__.py` together, and add the changes under a new heading in
`CHANGELOG.md` ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/) style: Added, Changed,
Fixed, Removed). Breaking HTTP changes (response shape, removed endpoints) go there too, so the
macOS app and CLI clients stay in sync.

## Security

See [SECURITY.md](SECURITY.md) for reporting a vulnerability, and
[`docs/internals/security.md`](docs/internals/security.md) for the trust model.
