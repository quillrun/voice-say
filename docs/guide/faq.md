# FAQ & troubleshooting

Plain-language answers to common questions and quick fixes for the most frequent problems.

If you are new, read the [User guide](user-guide.md) first. For settings details, see [Configuration](../setup/configuration.md).

## Troubleshooting

### I hear no audio

Work through these in order:

1. **Check your Mac's volume and output device.** Make sure the volume is up and the right speakers or headphones are selected in Control Center.
2. **Confirm the render actually happened.** Look at your history list — does a new entry appear with a non-zero duration? If yes, the audio exists; the problem is playback.
3. **Press play in the inline player.** A render does not always auto-play; click the entry and press play.
4. **Try another entry.** If older renders play but a new one does not, the new render may have failed — check that the [daemon is running](#the-app-says-the-daemon-isnt-running) and that the chosen backend is up.
5. **Restart the app.** Closing and reopening reconnects playback to the system audio.

If renders never appear at all, the issue is the daemon or a backend, not audio output — see the next section.

### The app says the daemon isn't running

The **daemon** is the background service that does the actual text-to-speech. The app cannot render anything without it.

- The app usually offers a button to **start the daemon** — click it and wait a moment for the connection indicator to turn healthy.
- If you started voice-say from a terminal, make sure you ran the start command (for example `make run`) and left that process running.
- The daemon listens on `127.0.0.1:8890`. If another program is using that port, change the port in your local config (see [Configuration](../setup/configuration.md)) and restart, then point the `voice-say` command line and the app at the new port ([A daemon on another port](../setup/configuration.md#a-daemon-on-another-port)).
- Still stuck? Check the daemon's health endpoint in a browser: open `http://127.0.0.1:8890/health`. A healthy response means the daemon is up and the app just needs reconnecting (restart the app).

> Note: the speech backends are separate services outside this repo. The default, `kokoro`, is mlx-audio's server on `127.0.0.1:8000`. See [Backends](../setup/backends.md).

### How do I change the voice?

You have a few options, all easy:

- **Per render, in the app:** pick a different **voice** (and **backend**, if you like) in the Compose pane before you render.
- **Per render, on the command line:** add the `--voice` flag, e.g. `voice-say render --voice=default "Hello"`. See the [CLI reference](../api/cli.md).
- **Change the default for everything:** set `default_voice` (and `default_backend`) in your local config so new renders use it automatically. See [Configuration](../setup/configuration.md).

To see what you can choose, check [What voices are available?](#what-voices-are-available) below.

### Where are my audio files saved?

Every render is saved permanently to an **audio archive** on your own disk. By default this lives under the data folder (`./data` in the daemon directory, the committed default; if no config is present it falls back to `~/.local/share/voice-say`), organized by year and month, so files stay easy to find. You can point this somewhere else with the `data_root` setting in [Configuration](../setup/configuration.md).

The full transcript of every render — plus all its metadata — is recorded in a single **SQLite database** (`voice.db`, in your data folder), so nothing is ever truncated and every render is fully searchable. Together with the audio archive, this means you never lose a render. See [Can I search my transcripts?](#can-i-search-my-transcripts) below.

### Can I search my transcripts?

Yes. Because every render's full transcript is stored in the `voice.db` database, you can full-text search across all of them. Ask the daemon directly with `GET /search?q=<query>&limit=<n>` — it returns matching renders newest-first, in the same shape as the history list. The macOS app exposes the same capability. See the [HTTP API](../api/http-api.md).

### What's the difference between a "say" and a "render"?

Every render is classified by length at the time it is made. A short utterance — a status ping or a quick note — is a **say**; anything longer is a **render**. The cutoff is the `say_threshold_chars` setting (default `280` characters). The app surfaces "says" as a built-in category so quick clips stay easy to find. See [Configuration](../setup/configuration.md).

### Is any of my text sent to the cloud?

**No.** voice-say is **fully local**. It does not use any API keys, and it does not send your text or audio anywhere off your machine. The daemon and the speech backends all run on your own computer and listen only on the loopback address (`127.0.0.1`), so they are not reachable from the network by default. For the full guarantees, see [Security](../internals/security.md).

### How do I add a new tag?

The daemon uses an **open tag vocabulary** by default — it accepts any tag. Tags are normalized (lowercase; spaces and underscores to hyphens; only `a-z0-9-` kept), so `"My Notes"` and `"my-notes"` are the same tag. The list of tags in use is always visible via `voice-say tags` or `GET /tags`.

The `voice-say` CLI is stricter on purpose, so a typo does not become a new tag: `voice-say render --tag` and `voice-say set --tag` take only tags already in use (see `voice-say tags`). To coin a new one, use `voice-say render --new-tag=<name>` or `voice-say set <ts> --tag <name> --allow-new-tags`; after that, `--tag=<name>` works.

If your install is running in closed-vocabulary mode (the owner set a non-empty `allowed_tags` in config), only the listed tags are accepted. To add a new one, a maintainer edits `allowed_tags` in the local config.

### What voices are available?

Voices depend on which **backend** you are using — each speech engine ships its own set. To see the exact list for your setup:

- **In the app:** the voice picker in the Compose pane shows the voices for the selected backend.
- **On the command line / via the API:** ask the daemon directly. `voice-say voices <backend>` prints the voices of one backend (the same data as `GET /voices/{backend}`). See the [CLI reference](../api/cli.md) and [HTTP API](../api/http-api.md).

The default backend is `kokoro` with voice `af_heart`; `voice-say voices kokoro` lists the others. See [Backends](../setup/backends.md) for the full picture.

## Still stuck?

- Settings reference: [Configuration](../setup/configuration.md)
- How the parts connect: [Architecture](../internals/architecture.md)
- A bug or an idea: [open an issue](https://github.com/quillrun/voice-say/issues)
