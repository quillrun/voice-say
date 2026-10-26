# Install

Get voice-say running locally: prerequisites, the plug-and-play `make` flow, and a health check.

voice-say is a **local-only** text-to-speech system. There are no API keys and no
cloud calls. A single Python daemon owns the render pipeline; thin clients (a bash
CLIs, and a macOS app) talk to it over
loopback HTTP at `127.0.0.1:8890`.

## Prerequisites

| Requirement | Notes |
|---|---|
| **Python 3.10–3.12** | Runs the aiohttp daemon and the `voice-say` CLI. `make setup` builds the venv with `python3.12`, else `python3.11`, else `python3.10` (`brew install python@3.12`; `SETUP_PYTHON=<path>` picks another). |
| **A TTS backend** | At least one OpenAI-compatible speech backend listening locally, run as its own service outside this repo (the default: Kokoro on mlx-audio's server, installed by `make kokoro`, which needs `brew install espeak-ng` on macOS). See [backends.md](./backends.md). |
| **`mpv`** (optional) | Headless playback for the CLI. Not needed for `--no-play` renders or for the macOS app (native `AVAudioPlayer`). |
| **`socat`** | Used by `voice-ctl` to drive the CLI's mpv IPC socket. |
| **`ffmpeg`** | Required for longform rendering — the daemon uses it for chunk concat + silence trim. Install via `brew install ffmpeg`. Only single short renders avoid it. |
| **macOS 26 + Xcode Command Line Tools** (optional) | Read-along word timings (`swiftc` builds a helper on macOS 26's Speech framework). `make setup` skips it on older macOS; read-along stays off. The macOS app needs macOS 26 and Xcode. |

## Plug-and-play flow (`make`)

```sh
make setup    # venv + deps + config + `voice-say`/`voice-ctl` in ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"   # if make setup said it is not on PATH
make doctor   # optional: check deps (mpv / socat / ffmpeg)
make kokoro       # one time: the default backend in its own venv
make kokoro-run   # terminal 1: the backend on 127.0.0.1:8000
make run          # terminal 2: the daemon (reads port from config/env)
voice-say render "Hello from voice-say"
```

`make setup` builds the daemon venv, installs the package + the `voice-say`/`voice-ctl` CLI
(into `~/.local/bin`), and seeds `config.local.toml`. macOS's default `PATH` does not
include `~/.local/bin`; when yours does not, `make setup` ends by saying so, and
`voice-say` is "command not found" until you add it. To keep it for new terminals:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

`make run` starts **only the daemon** — it does not start any TTS backend. Backends
are separate services; bring one up first (`make kokoro-run` for the default, or see
[backends.md](./backends.md)), then start the daemon.

## Optional: start the daemon at login (launchd)

`make run` keeps the daemon in a terminal. To have macOS start it at login instead, and
to let the macOS app's Start/Restart/Stop controls manage it, install the LaunchAgent
template from the repo root after `make setup`:

```sh
sed -e "s|__PYTHON__|$PWD/daemon/.venv/bin/python|g" \
    -e "s|__WORKDIR__|$PWD/daemon|g" \
    -e "s|__LOGDIR__|$HOME/Library/Logs|g" \
    daemon/launchd/local.voicesay.daemon.plist.example \
  > ~/Library/LaunchAgents/local.voicesay.daemon.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.voicesay.daemon.plist
curl -s http://127.0.0.1:8890/health
```

To remove it: `launchctl bootout gui/$(id -u)/local.voicesay.daemon`, then delete the plist.
The speech backend is not covered by this; start it as before.

## Verify

With the daemon running, hit the health endpoint:

```sh
curl http://127.0.0.1:8890/health
```

A healthy daemon returns a JSON body. For a deeper probe that also checks backend
reachability:

```sh
curl 'http://127.0.0.1:8890/health?deep=1'
```

If `curl` cannot connect, the daemon is not running — re-run `make run`. The CLI
surfaces this same condition as exit code `6` (daemon unreachable).

## Next steps

- [configuration.md](./configuration.md) — every config key, precedence, and the
  equivalent environment variables.
- [customization.md](./customization.md) — change voice/backend, tune the
  say/render threshold, define your own tags, change ports, enable CORS.
- [backends.md](./backends.md) — bring up each backend and the speech contract.
- [../../clients/macos/README.md](../../clients/macos/README.md) — build and run the
  native macOS app (`make app`), its full-window Settings screen, and the
  procedurally generated app icon.
- [distribution.md](./distribution.md) — the source/repo distribution model (build
  locally, no Apple ID); plus the optional Developer ID + notarization path if you
  ever hand a prebuilt app to another Mac.
