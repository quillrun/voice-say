# The tracked-core / private-overlay boundary

voice-say's code is split into a **clean tracked core** and a
**private local overlay**. The tracked core stays free of private voices and keys: it carries only
generic, non-personal defaults, and every machine- or person-specific value lives in a separate
private overlay that is never part of the tracked code. This page is the single authoritative
description of that boundary — what is in the tracked core, what is private, how the two connect, and
what enforces the split.

The *decision* behind it is [ADR-0001](../adr/0001-centralize-and-publishable.md); this page is the
*reference* for how it works in practice.

## Two layers

| Concern | Tracked core (this repo) | Private overlay (a separate config directory) |
|---|---|---|
| Tracked in the core? | Yes — generic only | No — lives only on your machine (or in your own private repo) |
| Default backend / voice | generic: `kokoro` / `default` | your choice (e.g. another backend + your own voice) |
| Paths | `./data` (relative) | real absolute data + archive paths |
| Backend catalog | `daemon/voice_say/config.py` `DEFAULT_BACKENDS` (one `kokoro` entry) | the live `backends.json` + any voice map of your own (each model keeps its own licence) |
| Service definitions | generic `daemon/launchd/*.plist.example` templates | the real personalized `launchd` plists (rendered from the templates) |
| Agent Skill | `skills/voice-say/SKILL.md` (generic) | personal defaults set by a wrapper around the CLI |

The tracked core never contains a personal voice id, real filesystem paths, a private backend
host, or any proprietary/personal term. Those exist **only** in the private overlay.

## How the two connect (the env-var seams)

The tracked-core daemon reads nothing personal at build time. At **runtime**, environment variables
point it at the private overlay:

| Env var | Points the daemon at | Effect |
|---|---|---|
| `VOICE_SAY_CONFIG` | the overlay's `config.local.toml` | real paths + the operator's default backend/voice |
| `VOICE_SAY_BACKENDS_CONFIG` | the overlay's `backends.json` | the live backend catalog (ports, voices, hosts) |

Config precedence is **`env` > `config.local.toml` > `config.example.toml`**. With none of these set,
the daemon runs entirely on the committed generic defaults — working speech, zero personal data.

## What enforces the split

`make publishable-check` (→ [`scripts/publishable-check.sh`](../../scripts/publishable-check.sh)) is
the mechanical gate. It fails on:

- committed **secrets**,
- **banned terms** — a deny-list of personal/proprietary names and absolute home paths (the full
  list is kept outside the repo, so a fork or CI run checks only the placeholders),
- **non-generic committed defaults** leaking into `config.example.toml`,
- failing tests, or a missing `LICENSE` / `README`.

Running the gate *is* the guarantee: the tracked core stays clean by construction, no scrubbing pass
needed.

## Related

- [ADR-0001 — centralize & keep private voices/overlay out of the tracked core](../adr/0001-centralize-and-publishable.md)
- [Configuration](../setup/configuration.md) — the full env / TOML reference
- [Security & Safety](security.md) — the clean-tracked-core invariant in the threat model
