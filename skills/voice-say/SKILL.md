---
name: voice-say
description: Turn text into speech saved in a local audio library, and find, search, tag or retitle what is already there, with the voice-say CLI. Use when the user asks to read something aloud, make an audio version of a text or document, narrate a script or episode, or look up, tag or tidy past renders. Needs the voice-say daemon and a speech backend running locally.
---

# voice-say

`voice-say` is a thin client of a local daemon (`http://127.0.0.1:8890`,
`VOICE_SAY_DAEMON_URL` overrides). The daemon renders through a speech backend,
saves the audio, and indexes the transcript. Never call the daemon or a backend
by hand; the CLI applies the library's rules.

## Make audio

```sh
voice-say render --json --no-play "Short line."
voice-say render --json --no-play --file=notes.md --title="Weekly notes" --tag=notes
voice-say render --json --file=ep-03.txt --title="The Bridge" --series="River Town" --episode=3
```

- `--json` prints one object on stdout: `id` (the row id), `path` (the archived
  file), `out`, `title`, `duration_s`, `backend`, `voice`, `kind`, `playing`.
  Everything else goes to stderr.
- Leave out `--no-play` only when the user wants to hear it now.
- Text longer than the daemon's threshold (`GET /config` → `say_threshold_chars`)
  needs `--title` (3–8 words) or `--title-from=<file.md>` (its first `# ` heading).
- `--tag` takes tags already in use (`voice-say tags`); `--new-tag=<name>` coins
  one on purpose. Prefer an existing tag.
- Pass long or quoted text with `--file=`, not as an argument.
- Long text renders as one episode; it can take minutes. Do not retry on a
  timeout (exit 7) before checking `voice-say history`: the render usually lands.
- `voice-say render --help` has every flag and how inline expression cues (`[whisper]`) work.

## Work the library

```sh
voice-say history --json --limit 20            # newest first: {entries, total}
voice-say history --json --series "River Town"  # one series, in episode order
voice-say search --json "bridge"                # full-text over transcripts
voice-say tags                                   # tags in use
voice-say voices <backend>                       # voices of one backend
voice-say set <id> --title "New title"           # also --star, --tag, --series, --episode
voice-say set <id> --delete                      # soft-delete; the file goes to the Trash
```

`<id>` is the `id` from `render --json` or the `ts` field of `history` /
`search`. Ask before `set --delete` on anything you did not render yourself.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | ok | |
| 1 | the daemon answered with an error | read stderr |
| 2 | usage | fix the command |
| 3 | render failed (stderr names the stage; a kept draft is named) | report it |
| 4 | refused before anything ran (missing title, unknown tag, bad value) | fix the flag; nothing was rendered |
| 6 | daemon unreachable | tell the user the daemon is down |
| 7 | render timed out | check `voice-say history` before retrying |
