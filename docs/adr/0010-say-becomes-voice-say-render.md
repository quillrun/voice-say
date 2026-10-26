# ADR-0010: `say` becomes `voice-say render`

Rendering moves from a top-level `say` command to a `render` subcommand of the
`voice-say` CLI. Supersedes the part of [ADR-0004](0004-rename-to-voice-say.md)
that kept the `say` command name.

- **Status:** Accepted (2026-10-26)

## Context

`cli/install.sh` linked `say` into `~/.local/bin`, which sits before `/usr/bin`
on a typical PATH, so it shadowed macOS's own `/usr/bin/say`. Scripts that
wanted Apple's voice had to hard-code `/usr/bin/say`, and anyone installing
voice-say would lose the system command without being told. The library side
was already one command (`voice-say`), so two names for one tool also split
the help: rules for rendering lived in `say --help`, the rest in
`voice-say --help`.

`speak` was considered and rejected: the command makes audio for the library
(title, tags, series), playing it is optional (`--no-play`).

## Decision

- `voice-say render …` takes every flag `say` took, with the same exit codes
  and the same playback controls (`--stop`, `--toggle`, `--seek`, also
  `voice-ctl`). The bash script stays (`cli/voice-say-render`); `voice-say`
  hands `render` to it before argument parsing, and `voice-say --help` lists it.
- `cli/install.sh` installs `voice-say` and `voice-ctl` only, and removes a
  `say` link that points into the repo. No `say` shim.
- A personal-defaults wrapper (default backend and voice) is a regular file
  named `voice-say` in `~/.local/bin`; `install.sh` leaves such a file alone.
- Stored values keep the old word: the `say` render kind and
  `say_threshold_chars` are data and config, not the command.

- The env prefix follows (it was kept in ADR-0004): `SAY_MCP_<X>` → `VOICE_SAY_<X>`,
  render's `SAY_DEFAULT_BACKEND` etc. → `VOICE_SAY_RENDER_*`. Old names are still
  read when the new one is unset, so existing launchd plists keep working.

## Consequences

- `/usr/bin/say` is reachable again after `make setup`.
- Callers of `say` (scripts, agents) must switch; there is no alias.
- `voice-say render` costs one Python start (~0.2 s) before the bash script.
