# Customization

Tailor voice-say without editing code: change voice/backend, tune the say/render threshold, define your own tags, change ports, and configure CORS.

Everything here is driven by configuration (`config.local.toml` or environment
variables) and the daemon's HTTP surface. You never need to touch source.

The TOML config layer is shipped. Precedence is environment variables >
`config.local.toml` > `config.example.toml`. The keys below match `GET /config`,
which the daemon exposes from its resolved settings.

## Change voice or backend

Set the defaults once in `config.local.toml`:

```toml
default_backend = "kokoro"     # any id in the catalog (built-in: kokoro)
default_voice   = "default"
```

Or override per launch with environment variables:

```sh
VOICE_SAY_DEFAULT_BACKEND=kokoro VOICE_SAY_DEFAULT_VOICE=bm_george make run
```

Or per render, without changing any defaults:

- **CLI:** `voice-say render --backend=kokoro --voice=bm_george "hello"`
- **HTTP:** `POST /render` body `{ "text": "...", "backend": "kokoro", "voice": "bm_george" }`

Discover what is available at runtime:

```sh
curl http://127.0.0.1:8890/backends            # configured backends
curl http://127.0.0.1:8890/voices/kokoro       # voices for one backend
```

See [backends.md](./backends.md) for each backend's ports and tradeoffs.

## Tune the say/render threshold

Text whose length is `<= say_threshold_chars` (default 280) is classified
`kind="say"`, longer text is `kind="render"`; both kinds are stored identically.
See [configuration.md](./configuration.md) for the full rule.

```toml
say_threshold_chars = 280
```

Or override at launch:

```sh
VOICE_SAY_SAY_THRESHOLD_CHARS=280 make run
```

## Use tags

Tags are short labels that help you group and find renders. The daemon uses an **open vocabulary** by default: it accepts any normalized tag, and a tag in use appears in `GET /tags`. Tags are normalized by trimming, lowercasing, and converting spaces to hyphens (`"Daily Notes"` → `"daily-notes"`).

The `voice-say` CLI is stricter on purpose, so a typo does not become a new tag: `voice-say render --tag` and `voice-say set --tag` take only tags already in use (see `voice-say tags`). To coin a new one, use `voice-say render --new-tag=<name>` or `voice-say set <ts> --tag <name> --allow-new-tags`; after that, `--tag=<name>` works.

```bash
voice-say render --new-tag=briefing "Weekly summary draft."   # first use coins it
voice-say render --tag=briefing "Next week's summary."       # then it is in use
voice-say tags                                              # see all tags in use
```

### Optional: close the vocabulary

If you want a curated, consistent tag list, set `allowed_tags` in your local config:

```toml
allowed_tags = ["summary", "narration", "note", "daily-log"]
```

With a non-empty list, `POST /render` rejects an unknown tag with **HTTP 400** plus the allowed list. Leave `allowed_tags` **empty** (the default) for the open vocabulary.

Note: `star` (an overlay boolean) and playback `completed` (a progress field) are mechanisms, not tags.

## Change ports

The daemon's loopback port:

```toml
daemon_port = 8890
```

Backend addresses: the built-in `kokoro` is `http://127.0.0.1:8000` — see
[backends.md](./backends.md). If you remap a
backend's port at the service level, the daemon reaches it via the configured
backend definition.

## Configure CORS

By default the daemon is **loopback-only**: `cors_origins` is unset and no
cross-origin requests are allowed. CORS is an optional, off-by-default
mechanism — enable it only if you have a real cross-origin consumer to serve.
To allow an origin, set it as a **single** verbatim origin string (the value is
emitted directly as `Access-Control-Allow-Origin` — it is one origin, not a
comma-separated list):

```toml
cors_origins = "http://127.0.0.1:5173"
```

```sh
VOICE_SAY_CORS=http://127.0.0.1:5173 make run
```

Only set an origin you control. The `/audio` endpoint has a path-traversal guard, but
opening CORS widens the daemon's exposure — set the single most specific origin you need.

> CORS support stays dormant by default: it is kept harmless and off, not
> wired to any shipped surface.
