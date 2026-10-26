# ADR-0006: Per-backend output format — WAV passthrough, no transcode dependency

Let each backend declare its container format and carry it through the pipeline,
rather than forcing every backend to mp3 or bundling an mp3 encoder.

- **Status:** Accepted (v0.5.0)

> **Storage note:** the "JSONL + sidecar" format language below describes the
> pre-ADR-0007 on-disk layout. Render metadata is now consolidated into the single
> `voice.db` store (see ADR-0007); read that ADR for the current storage model.

## Context

The render pipeline historically hardcoded mp3: it requested `response_format:
"mp3"`, wrote a `.mp3` archive file, probed duration as mp3, and recorded
`format: mp3` in the JSONL + sidecar. That held while every backend returned mp3.

The native MLX-Swift backend returns **24 kHz mono WAV** — macOS has no native
mp3 *encoder*, so producing mp3 from a Swift service would mean bundling an
encoder (e.g. LAME) as a dependency. That cuts against the native-first goal
(fewer non-Apple dependencies).

## Decision

Add a per-backend **`output_format`** (default `"mp3"`) to the backend catalog and
thread it through the pipeline:

- `_tts_post` requests the backend's own `response_format`.
- `archive_write` uses the format as the file extension (`.wav` vs `.mp3`).
- `probe_duration_s` probes WAV via `mutagen.wave`, mp3 via `mutagen.mp3`.
- the JSONL row + vault sidecar record the actual `format`.

The native backend declares `output_format = "wav"`; the Python backends keep the
`"mp3"` default unchanged. **No transcode step, no encoder dependency** — WAV
flows through verbatim.

## Consequences

**Positive**

- Native-first: the Apple-Silicon backend needs no mp3 encoder.
- The change is additive and backwards-compatible — mp3 backends are untouched
  (the default preserves prior behavior; existing tests stay green).
- Clients already read `format`/`archive_name` from the entry, so `.wav` renders
  play + display correctly without client changes.

**Negative / costs**

- WAV files are larger than mp3 on disk (uncompressed PCM).
- Two probe paths to maintain (WAV + mp3), though both are thin `mutagen` calls.
