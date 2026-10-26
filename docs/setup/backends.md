# Backends

The TTS backends behind voice-say: the default (Kokoro on mlx-audio), how to add any
OpenAI-compatible speech server, the catalog fields, and inline `[emotion]` tag handling.

A **backend** is a local HTTP service that turns text into audio. The daemon does
not synthesize audio itself — it proxies to whichever backend a render names (or
the configured `default_backend`). Backends are **separate services that run
outside this repo**; the daemon only knows how to reach them.

## The speech contract

Every backend answers the OpenAI-compatible text-to-speech endpoint:

```
POST /v1/audio/speech   {"model": "...", "input": "...", "voice": "...", "response_format": "wav"}
```

The daemon sends the text, model, voice and format; the backend returns audio bytes:

```jsonc
POST <backend>/v1/audio/speech
{
  "model": "tts-1",
  "input": "the text to speak",
  "voice": "voice-id",           // optional: left out when the voice is "default"
  "response_format": "wav",
  "speed": 1.2                    // optional: sent only when supports_speed=true and the speed is not 1.0
}
→ HTTP 200, body = audio bytes
```

Optionally it also lists its voices at `GET /v1/audio/voices?model=...`, which
mlx-audio's server does. The daemon reads either `{"data": [{"id": "af_heart"}, …]}`
or a bare list of `{"id": …}` objects.

```mermaid
flowchart LR
  daemon["daemon\n127.0.0.1:8890"] -->|"POST /v1/audio/speech"| kokoro["mlx-audio server\nKokoro, :8000"]
  daemon -->|"POST /v1/audio/speech"| other["any OpenAI-compatible\nspeech server"]
```

## The default: Kokoro on mlx-audio

The committed catalog (`daemon/voice_say/config.py` `DEFAULT_BACKENDS`) has one entry,
`kokoro`: [Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M) (Apache-2.0) served by
[mlx-audio](https://github.com/Blaizzy/mlx-audio)'s server on Apple Silicon.
`make kokoro` runs the lines below (pinned to the versions measured together:
mlx-audio 0.6.1, misaki 0.9.4); `make kokoro-run` starts the server.

```sh
python3.12 -m venv ~/.venvs/mlx-audio   # misaki needs Python < 3.13
~/.venvs/mlx-audio/bin/pip install "mlx-audio[server]==0.6.1" "misaki[en]==0.9.4"
# macOS: the espeak-ng library that misaki loads (the espeakng-loader wheel, 0.2.3
# and 0.2.4) exits the server on the first render with "Error processing file
# '.../espeak-ng-data/phontab'" (a path from the wheel's build machine). Use Homebrew's instead:
brew install espeak-ng
ln -sf "$(brew --prefix)/lib/libespeak-ng.dylib" \
  "$(~/.venvs/mlx-audio/bin/python -c 'import espeakng_loader as e; print(e.get_library_path())')"
~/.venvs/mlx-audio/bin/python -m mlx_audio.server --host 127.0.0.1 --port 8000
```

`misaki` is Kokoro's text-to-phoneme step; `mlx-audio[server]` does not pull it in.
The first render downloads the model from Hugging Face (689 MB with its voice packs);
loading it takes ~8 s on an M2 Pro (16 GB), then under a second for a short line. Voices (`af_heart`,
`bm_george`, …) come from the server; `voice-say voices kokoro` lists them.

## Adding a backend

Point `VOICE_SAY_BACKENDS_CONFIG` at a JSON file. It **replaces** the committed catalog,
so list every backend you want. An entry needs two fields:

```json
{
  "kokoro": {"url": "http://127.0.0.1:8000", "model": "mlx-community/Kokoro-82M-bf16"},
  "my-tts": {"url": "http://127.0.0.1:9000", "model": "tts-1"}
}
```

```sh
VOICE_SAY_BACKENDS_CONFIG=$(pwd)/my-backends.json make run
voice-say render --backend=my-tts "hello"
```

The other fields are optional:

| Field | Default | Meaning |
|---|---|---|
| `url` | — | Base URL of the server (`http://host:port`; a trailing `/v1` is dropped). An entry may give `host` + `port` instead. |
| `model` | `tts-1` | Sent as the OpenAI `model` field, so one server can serve several models. |
| `voices` | asked from the server | The voice list for pickers. Leave it out and the daemon asks `GET /v1/audio/voices?model=`; give `[]` for a server that has no list. Not an allowlist: any voice passes through. |
| `default_voice` | `default` | Voice when the caller names none; `default` sends no voice field. |
| `label` | the id | Display name. |
| `output_format` | `mp3` | `mp3` or `wav`, what the server returns (mlx-audio needs ffmpeg for mp3, so `kokoro` uses `wav`). |
| `supports_speed` | `false` | Forward `--speed`. |
| `supports_emotion_tags` | `false` | Keep inline `[emotion]` / `<|…|>` tags; otherwise the daemon strips them. |
| `timeout_s` | `600` | Per-request timeout. |
| `longform_chunk_max` | `0` | Characters per request for long text; `0` = the global ~1200. A backend that carries continuity across its own seams sets it larger. |
| `service` | none | `{"kind": "launchd", "label": "..."}` lets the app start/stop it and `voice-say restart` restart it. The LaunchAgent plist must be at `~/Library/LaunchAgents/<label>.plist`: the app's Start runs `launchctl bootstrap gui/$(id -u) <plist>`, and refuses while the file is absent. |
| `accent` | grey | Hex colour in the app. |

`longform_max_chunks` (the cap on the *number* of chunks per render, default 40) is a
daemon setting, see [configuration.md](./configuration.md).

## Inline `[emotion]` tags

Text may contain inline emotion cues in square brackets, e.g.
`[calm] ... [excited] ...`.

- For any backend whose `supports_emotion_tags` is **false** (e.g. `kokoro`), the
  daemon **strips** every tag (a bracketed word or phrase on its own, like `[whisper]`)
  before synthesis, so the cues never reach the backend and never appear in audio.
  Brackets that are part of the text (`[1]`, `arr[0]`, `[word](link)`) and
  paragraph breaks stay.
- A backend whose model reads such cues sets `supports_emotion_tags = true`. For it the daemon leaves the
  inline `[bracket]`/`<angle>` cues **in the text** so the model can act on them; they are not
  stripped.

```mermaid
flowchart TD
  txt["text with [emotion] cues"] --> strip["daemon strips [bracket] tags (supports_emotion_tags=false backends only)"]
  strip --> synth["clean text synthesized"]
```

This means tag-bearing input sent to a non-expressive backend is always safe: the
bracketed cues are removed and only clean spoken text is rendered. Sent to a backend with
`supports_emotion_tags = true`, the cues are passed through to the model.

### A catalog that stays on your machine

A backend you do not want in the repo (a voice you trained yourself, a server on
another machine) goes in a catalog file outside git:

1. Write `daemon/backends.local.json`: the `kokoro` entry shown under
   [Adding a backend](#adding-a-backend) plus your own, with its `voices` and
   `default_voice` if the server does not list them. The `*.local.*` pattern in
   `.gitignore` keeps it out of commits.
2. Point the daemon at it: `VOICE_SAY_BACKENDS_CONFIG=/path/to/backends.local.json`
   (in the daemon's LaunchAgent `EnvironmentVariables`, or your shell).

The entry then appears in the CLI and the macOS app's voice pickers on your machine
only.

## Inspecting backends at runtime

```sh
curl http://127.0.0.1:8890/backends          # configured backends
curl http://127.0.0.1:8890/voices/kokoro     # voices for a backend
curl 'http://127.0.0.1:8890/health?deep=1'   # deep probe incl. backend reachability
```

## Performance notes

- Render concurrency: one backend request runs at a time per **gate key**
  (`engine._concurrency_key`, `engine._RenderGate`). Every backend on this machine
  (`127.0.0.1`, `localhost`, `::1`, `0.0.0.0`) shares one key, so two local models are
  never loaded and running at once; a backend on another host gets its own key and
  runs in parallel with the local ones. One longform render runs at a time across
  all backends, and it takes the gate per chunk, so a short render can slip in
  between two chunks.
- Per-backend timeout: configurable per entry in the catalog (`timeout_s`). The
  default is 600 s — raise it for a slow model or long chunks.

See [configuration.md](./configuration.md) for `default_backend` / `default_voice`
and [customization.md](./customization.md) for per-render overrides.
