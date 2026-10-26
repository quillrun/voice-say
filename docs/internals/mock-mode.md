# Mock mode (model-bypass dev/test)

Mock mode lets you exercise the **entire render and playback lifecycle with no
speech model loaded** — useful on a RAM-tight machine, in CI, or when iterating
on the UI. A render flagged `mock` skips the backend and replays a set of
pre-existing fixture WAVs on a timer, but otherwise drives the *real* pipeline:
chunking, gapless concat, the archive write, the `voice.db` row, and the full
SSE stream (`episode_start` / `chunk_ready` / `episode_complete`).

It is **one mechanism**, not a backend. There is no `mock` entry in the backend
catalog; `mock` is a per-render boolean that short-circuits synthesis.

## How to turn it on

Both routes set the same daemon flag:

- **HTTP** — `POST /render_longform` with `"mock": true` in the body
  (`_routes_render.py`).
- **Resume** — a draft that was rendered with mock carries the `mock` tag, and
  `POST /episode/resume` re-derives the flag from the tag, so a mock draft
  **continues model-free** end to end.

Every mock render is auto-tagged `mock`, so mock output is trivially filtered
and purged and never masquerades as a real render.

## What it exercises

Because mock drives the same `_render_longform_stream` path as a real render,
the whole lifecycle works against it: **stream** (play-while-rendering), **Pause**
(finish the current chunk, then keep what's rendered as a resumable draft), **Stop
Now** (skip the chunk being rendered, keep what's done), **Delete** (cancel, keep
nothing), **resume** (continue a draft), and client-side **pause / seek**. The lifecycle controls are
backend-agnostic (they flip flags on the episode registry), so they behave
identically with mock and with a real model.

## Fixtures

The fixtures are a directory of pre-existing chunk WAVs, cycled
`VOICE_SAY_MOCK_CHUNK_MULT` times (default 2) to form the chunk list, replayed one
fixture per chunk (wrapping by `i % len(fixtures)`):

- `VOICE_SAY_MOCK_CHUNK_DIR` — fixtures directory (default `daemon/mock-fixtures/`).
- `VOICE_SAY_MOCK_RTF` — per-chunk pause as a multiple of the fixture's own audio
  seconds (real-time factor; default 1.0 ≈ renders in the time it plays). This
  is the primary pacing: a flat per-chunk timer made an N-chunk mock "finish"
  in N×0.6s while the audio played far longer, so the render frontier raced to
  100%. `0` disables the audio-scaled pause (used by tests).
- `VOICE_SAY_MOCK_CHUNK_MS` — minimum per-chunk pause in ms; the floor for odd /
  zero-duration fixtures (default 600).
- `VOICE_SAY_MOCK_CHUNK_MULT` — how many times to cycle the fixture set, multiplying
  the chunk count (and total audio + render time). Default 2; `1` = one chunk
  per fixture (used by tests).

The fixtures are **local-only and git-ignored** (`mock-fixtures/`): put a few
WAVs there yourself (any earlier render's chunks will do). With no fixtures
present a mock render errors clearly rather than producing silence.

### Predicted duration

A mock render's `episode_start.predicted_total_s` is computed from the **real
durations of the fixtures it will replay** (parsed from the WAV headers), not the
text-derived `chars / CHARS_PER_SECOND` estimate a real render uses. The fixtures
have a fixed length unrelated to the input text, so the text estimate would be
far too small and the render-head fraction, the time readout, and the waveform
render-frontier would all saturate to 100% on the first chunk. On a resume, the
already-rendered draft prefix is added so the bar starts part-filled.

## Code map

- `daemon/voice_say/config.py` — `MOCK_CHUNK_DIR`, `MOCK_CHUNK_MS`, `MOCK_RTF`,
  `MOCK_CHUNK_MULT`.
- `daemon/voice_say/engine.py` — `_load_mock_fixtures`, `_mock_chunk_plan`,
  `_mock_synth`, `_mock_fixture_durations`, `_mock_total_audio_s`; the `mock`
  param threaded through `render_longform` → `_render_longform_stream` /
  sequential → `_tts_post` → `_mock_synth`, and `resume_longform`.
- `daemon/voice_say/_routes_render.py` — reads `mock` from the request body.
- `daemon/tests/test_mock_backend.py` — the mock contract (chunk-per-fixture,
  SSE shape, one tagged row, predicted-total-from-fixtures, model-free resume).

## Related

- [SSE & state](sse-and-state.md) — the streaming events mock drives
- [Architecture](architecture.md) — how the daemon and backends connect
