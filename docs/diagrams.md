# voice-say — Diagrams Gallery

A curated set of valid Mermaid diagrams covering the architecture, render
pipeline, long-form / streaming render, data lifecycle, event flow,
configuration, tag policy, and backend topology of voice-say — a local-only
text-to-speech system.

All diagrams use generic labels. The daemon, the config layer, the backend
catalog (one `kokoro` entry on mlx-audio's server, a separate service outside
this repo), the consolidated **SQLite store** (`voice.db`, WAL) with FTS5
transcript search, and one-command daemon setup are all **shipped**. The client
surfaces are the **CLI** (`voice-say`, `render` included) and the **macOS app**.

---

## 1. System Architecture

Thin client surfaces (the CLIs and the macOS app) all
funnel through one local aiohttp daemon on `127.0.0.1:8890`, which drives the
pluggable TTS backends and broadcasts render/progress/overlay events back to
every client over Server-Sent Events.

```mermaid
flowchart TD
    subgraph Clients
        CLI["CLI (voice-say, render included)"]
        APP["macOS app (SwiftUI — VoiceSay.app)"]
    end

    subgraph Daemon["aiohttp daemon — 127.0.0.1:8890"]
        API["HTTP routes\n/render /history /search /events /config\n/tags /progress /overlays /audio /health"]
        PIPE["render pipeline (engine.render)"]
        SSE["SSE broadcaster"]
    end

    subgraph Backends["local TTS backends (OpenAI-compatible, separate services)"]
        KOK["mlx-audio server :8000\nKokoro, the default"]
        OTH["any other server\nOpenAI-compatible /v1/audio/speech"]
    end

    CLI --> API
    APP --> API
    API --> PIPE
    PIPE -->|POST /v1/audio/speech| KOK
    PIPE -->|POST /v1/audio/speech| OTH
    PIPE --> SSE
    SSE -->|render / progress / overlay events| CLI
    SSE --> APP
```

---

## 2. Render Sequence

A single `/render` call: the daemon validates input, posts to the chosen backend,
writes the audio atomically using the backend's own format, classifies the render
into a `kind` (`say` vs `render`) by transcript length, inserts one row (full
transcript + metadata) into the SQLite store, fires the in-memory cache hook, and
returns the entry dict.

```mermaid
sequenceDiagram
    participant C as Caller (CLI / app)
    participant D as Daemon (:8890)
    participant B as Backend (:889x)
    participant FS as Filesystem
    participant DB as SQLite store (voice.db)
    participant H as State cache / SSE

    C->>D: POST /render {text, backend, voice, tags}
    D->>D: validate + normalize tags
    D->>D: resolve backend.output_format (mp3 | wav)
    D->>B: POST /v1/audio/speech {response_format}
    B-->>D: audio bytes
    D->>FS: atomic archive write (<stem>.<ext>)
    D->>FS: duration probe (mutagen.mp3 | mutagen.wave)
    D->>D: classify kind (len <= say_threshold_chars ? "say" : "render")
    D->>DB: INSERT into renders (full text, kind, archive_path, format, ...)
    Note over DB: FTS5 renders_fts updated over transcript
    D->>H: on_history_appended hook (best-effort)
    H-->>C: render event over SSE
    D-->>C: 200 + entry dict
```

---

## 3. Data / Artefact Lifecycle

Every render produces two artefacts under a shared `<stem>` — the audio file on
disk and one row in the SQLite store. The audio extension follows the backend's
format (`.mp3` or `.wav`); the row in `renders` carries the **full transcript**
plus all metadata (`kind`, `archive_path`, `format`, tags, duration, ...). State
lives entirely in `voice.db` (WAL mode): the append-only `renders` table, the
mutable `progress` and `overlays` tables, and the `renders_fts` FTS5 virtual
table over the transcript. No vault sidecars, no JSONL files, no manual locking
or compaction.

```mermaid
flowchart LR
    R["render(text)"] --> STEM["shared stem"]

    subgraph Disk["audio on disk (permanent)"]
        A["audio\n./data/voice-archive/YYYY/MM/&lt;stem&gt;.{mp3|wav}\n(referenced by archive_path)"]
    end

    subgraph DB["SQLite store — voice.db (WAL)"]
        J["renders (append-only)\nfull text + kind + archive_path + format + ..."]
        FTS["renders_fts (FTS5 virtual table)\nfull-text over transcript"]
        P["progress\n(playback memory)"]
        O["overlays\n(star / tags / bookmarks / soft-delete)"]
    end

    STEM --> A
    STEM --> J
    J -->|indexed by| FTS
    J -.references by ts.-> P
    J -.references by ts.-> O
```

---

## 4. SSE Event Flow + Reconnect

On connect the daemon either replays buffered events (when `Last-Event-ID` is
still inside the ring buffer) or sends a full snapshot; after that it streams
live render/progress/overlay events with periodic keepalives.

```mermaid
sequenceDiagram
    participant C as Client (SSE consumer)
    participant D as Daemon /events

    C->>D: GET /events (Last-Event-ID optional)
    alt id missing, aged out, or past restart
        D-->>C: snapshot {history, progress, overlays, instance_id}
    else id still inside ring buffer
        D-->>C: replay events with id > Last-Event-ID
    end
    loop live stream
        D-->>C: event: render / progress / overlay
        D-->>C: :keepalive (every 15s of quiet)
    end
    Note over C,D: on drop, client reconnects with last seen id
```

---

## 5. Config Precedence

Configuration resolves from environment variables first, then a local override
file, then committed example defaults — `env > config.local.toml >
config.example.toml`. The daemon reads the effective config at boot and exposes
it to clients via `GET /config`. Generic committed defaults work with zero edits
once a backend is up.

```mermaid
flowchart TD
    ENV["environment variables\n(highest precedence)"] --> RESOLVE["effective config\n(read at boot, served via GET /config)"]
    LOCAL["config.local.toml\n(local override, gitignored)"] --> RESOLVE
    EXAMPLE["config.example.toml\n(committed generic defaults)"] --> RESOLVE
    RESOLVE --> KEYS["data_root (committed default ./data;\n~/.local/share/voice-say is the in-code fallback),\ndb_path (&lt;data_root&gt;/voice.db),\ndefault_backend=kokoro,\ndefault_voice=default,\nsay_threshold_chars=280,\nallowed_tags=[] (open), daemon_port=8890"]
```

---

## 6. Tag Normalization Flow

Tags use an **open vocabulary** by default (any normalized tag accepted). The
`allowed_tags` config key can close the vocabulary; `GET /tags` always shows
the distinct tags in use.

```mermaid
flowchart TD
    IN["incoming tag (raw string)"]
    IN --> NORM["normalize: trim, lowercase, spaces to hyphens"]
    NORM --> EMPTY{"empty after normalize?"}
    EMPTY -->|yes| DROP["discard"]
    EMPTY -->|no| MODE{"allowed_tags set\nin config?"}
    MODE -->|"no (open vocab, default)"| ACCEPT["accept — tag is stored"]
    MODE -->|yes| CHECK{"tag in allowed_tags?"}
    CHECK -->|yes| ACCEPT
    CHECK -->|no| REJECT["HTTP 400 + allowed list"]
    ACCEPT --> STORE["stored in renders + overlays\nappears in GET /tags"]
```

---

## 7. Backend Topology

All TTS backends run locally and speak the OpenAI-compatible
`POST /v1/audio/speech` contract. Each is its own service, outside this repo:
the committed default is Kokoro on mlx-audio's server (`:8000`); any other
server with that contract is one catalog entry (`url` + `model`). A backend
that understands inline emotion tags says so with `supports_emotion_tags`.
`voice-say render --fast` skips the daemon and streams from a backend directly
(`stream: true`).

```mermaid
flowchart LR
    D["daemon render pipeline"]

    D -->|"POST /v1/audio/speech"| KOK["mlx-audio server :8000\n(Kokoro, wav)"]
    D -->|"POST /v1/audio/speech"| OTH["any OpenAI-compatible server\n(url + model)"]
    F["voice-say render --fast"] -->|"stream: true (no archive)"| KOK
```

---

## 8. Render Kind + Transcript Search

At render time every entry is classified into a **`kind`** by transcript length:
`say` when `len(text) <= say_threshold_chars` (default **280**), else `render`.
"Says" are short utterances / status pings; the macOS app surfaces them as a
built-in category. The same `voice.db` powers full-text search — the daemon's
`GET /search?q=<query>&limit=<n>` HTTP endpoint runs FTS5 over the `renders_fts`
transcript index (newest-first) and returns the same `{entries, total}` shape as
`/history`; `voice-say search` and the macOS app expose the matching capability.

```mermaid
flowchart TD
    REND["render(text)"] --> LEN{"len(text) <= say_threshold_chars\n(default 280)?"}
    LEN -->|yes| SAY["kind = 'say'\n(short utterance / status ping)"]
    LEN -->|no| LONG["kind = 'render'"]
    SAY --> ROW["INSERT renders row\n(full text + kind)"]
    LONG --> ROW
    ROW --> FTS["renders_fts (FTS5)\nover transcript"]

    Q["GET /search?q=...&limit=n"] --> FTS
    FTS --> RES["{entries, total}\nnewest-first (same shape as /history)"]
    RES --> CLIENTS["voice-say search · macOS app"]
```

---

## 9. Long-form / Streaming Render

`POST /render_longform` is a first-class path for text too long for a single
render: it chunks the input (≤ a **backend-specific** char ceiling — default
**1200** chars/chunk; a backend that stitches long input itself can set e.g.
**12500** for whole-module POSTs; capped at **40** chunks), renders chunks serially, then
**gapless-concats** them into **one** audio file plus **one** `renders` row —
so a long episode lands as a single archive artefact, not N fragments. Before
the concat, each chunk's leading + trailing silence is trimmed to a uniform
~210 ms seam pause, **except the final chunk** which keeps its natural trailing
tail so the last word's soft decay isn't clipped. In `mode="stream"` the daemon
also broadcasts `episode_start` / `chunk_ready` / `episode_complete` over SSE so
a client can play and read while the render is still in flight. The macOS app
shows a provisional streaming card (play-while-rendering, before any `voice.db`
row exists) and drives a read-while-rendering transcript reader from
`episode_start.text` (the full chunked transcript) + `chunk_ready.rendered_chars`
(the render-head char offset).

`POST /episode/{id}/finalize` is **save-and-stop**: instead of cancelling, the
in-flight episode keeps the audio rendered so far as **one** `renders` row tagged
**`draft`** (the `draft` tag persists; the macOS app surfaces drafts in the
**Rendering** bucket) and persists a resume boundary — the validated full
chunked text (`resume_full_text`) plus the char offset already rendered
(`resume_char_offset`), two NULLABLE columns set *only* on a draft row.
`POST /episode/resume` (body `{"from_ts": "<draft ts>"}`) later continues it:
re-chunk the stored full text, skip the chunks whose cumulative end is already
inside the rendered prefix, render only the remainder, gapless-concat
`[draft audio + new chunks]` into **one new** canonical row, and supersede the
draft (overlay `deleted=true`) — reusing the **same** `episode_start` /
`chunk_ready` / `episode_complete` SSE contract as a fresh stream render.

```mermaid
sequenceDiagram
    participant C as Caller (CLI / app)
    participant D as Daemon (:8890)
    participant B as Backend (:889x)
    participant FS as Filesystem
    participant DB as SQLite store (voice.db)
    participant S as SSE consumers

    C->>D: POST /render_longform {text, mode}
    D->>D: chunk text (<= backend-specific limit, max 40)
    opt mode = "stream"
        D-->>S: event: episode_start {text, predicted_total_s}
    end
    loop each chunk (serial)
        D->>B: POST /v1/audio/speech {response_format}
        B-->>D: chunk audio bytes
        D->>D: trim chunk silence (final chunk: keep trailing tail)
        D->>FS: write transient chunk file
        opt mode = "stream"
            D-->>S: event: chunk_ready {rendered_chars, cumulative_audio_s}
        end
    end
    D->>FS: gapless-concat chunks -> ONE audio file
    alt POST /episode/{id}/finalize (save-and-stop)
        D->>DB: INSERT one renders row (tag=draft)<br/>+ resume_full_text + resume_char_offset
        D-->>S: event: episode_complete {ts, total_s, save_and_stop=true}
    else ran to completion
        D->>DB: INSERT one renders row (full text + archive_path)
        D-->>S: event: episode_complete {ts, total_s}
    end
    D-->>C: 200 + entry dict
    Note over S: macOS streaming card plays + read-while-rendering reader follows render-head

    rect rgb(238, 238, 238)
        Note over C,DB: later — POST /episode/resume {from_ts} (reuses the same episode_* SSE events)
        C->>D: POST /episode/resume {from_ts = draft ts}
        D->>DB: load draft row (resume_full_text + resume_char_offset)
        D->>D: re-chunk full text, skip chunks whose<br/>cumulative end <= resume_char_offset
        D-->>S: event: episode_start {text, predicted_total_s}
        loop remainder chunks (serial)
            D->>B: POST /v1/audio/speech {response_format}
            B-->>D: chunk audio bytes
            D-->>S: event: chunk_ready {rendered_chars, cumulative_audio_s}
        end
        D->>FS: gapless-concat [draft audio + new chunks] -> ONE audio file
        D->>DB: INSERT ONE new canonical row
        D->>DB: supersede the draft (overlay deleted=true)
        D-->>S: event: episode_complete {ts, total_s}
        D-->>C: 200 + entry dict
    end
```

> The single-`/render` path (diagram 2) stays the default for short text; only
> `/render_longform` chunks. `/episode/{id}/cancel` (drop everything, write no
> row) and `/episode/{id}/finalize` (**save-and-stop** — keep the rendered-so-far
> audio as one `draft` row with a persisted resume boundary) control an in-flight
> streaming episode; `POST /episode/resume` later continues a draft. On failure
> the stream emits `episode_error` in place of `episode_complete`. A double-fired
> resume of the same draft is rejected with `409 conflict` (one in-flight resume
> per draft); the POST stays open until completion (client uses a 600s timeout).
