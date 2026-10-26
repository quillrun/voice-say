# ADR-0004: voice-say is the official name; one repo for daemon + app + CLI

Rename the project from "say-mcp" to **voice-say** and make the single repo the
source of truth for all three surfaces (HTTP daemon, macOS app, `/say` CLI).

- **Status:** Accepted

## Context

The system began as "say-mcp" and grew three separately-living pieces: the daemon
(`say-mcp`), a macOS app (a standalone app project), and a bash `/say` skill. Three
names and three locations for one product invited drift — docs, identifiers, and
mental models diverged. The name "say-mcp" also overweights one surface (the MCP
stdio adapter) when MCP is just one of several thin clients over the daemon.

## Decision

Adopt **voice-say** as the official software name and consolidate everything into
one canonical repo:

- **Package** `voice_say`; **daemon** `daemon/`; **macOS app** `clients/macos/`
  (display name "VoiceSay"); **CLI/skill** `cli/` (`say`, `voice-ctl`).
- The `/say` *command* name is kept (short, ergonomic) — only the project/service
  is renamed. _(Superseded by [ADR-0010](0010-say-becomes-voice-say-render.md), 2026-10-26: the command is now `voice-say render`.)_ The `SAY_MCP_*` environment-variable prefix is **also kept** as a
  stable public-API name; renaming it would be a gratuitous breaking change.
- Personal/identity material never enters the repo (enforced by the
  publishable-check gate); it lives in a separate private overlay injected via
  `SAY_MCP_CONFIG`.

## Consequences

**Positive**

- One name, one repo, one source of truth — docs and clients can't drift apart.
- The name describes the product (text → voice) rather than one transport.
- Going public is a visibility flip, not a rename project.

**Negative / costs**

- A one-time rename touched the package, launchd labels, MCP server id, wiki, and
  app display name. The kept `SAY_MCP_*` env prefix means the name isn't *fully*
  uniform, but that is a deliberate compatibility choice.
