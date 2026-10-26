# voice-say — Use Cases

Concrete ways people put voice-say to work, all running locally on their own machine.

## Narrating notes and articles to audio

You have a long note, a saved article, or a draft you would rather listen to than read. Hand the file to `voice-say render --file` and it renders the whole thing to an audio file you can play immediately or replay later from your render history. The full transcript is stored alongside every render in the local `voice.db` store — so the spoken version and the written version stay paired, and you can search across every transcript later. The audio lives in your own archive in an open format, ready to move onto a phone or a podcast app for offline listening.

```bash
voice-say render --file=./notes/article.md --title="Article"
```

## Giving agents and scripts a voice

An AI assistant or a script can speak through voice-say without ever touching the speech engine directly. It calls `voice-say render` to render and play text, and the other `voice-say` commands to find, search, tag, retitle or delete what is already in the library; both are thin clients of the daemon. Start the daemon first, and the agent gains a local voice that produces the same archived, tagged renders as every other surface. Each command's `--help` states its rules (a title for long text, tags that already exist).

## Accessibility and read-aloud

For read-aloud and accessibility, voice-say turns on-screen text into clear spoken audio entirely offline — useful when you would rather listen than read, or cannot read comfortably. Select a voice that suits you and send text from the CLI or the macOS app; the app gives you an expandable inline player with a waveform scrubber, media-key and Control Center integration, and bookmarks, so you can pause, seek, and resume long passages. Nothing is sent to a cloud service, which matters when the text being read aloud is private.

## Drafting podcasts and longform

When you are producing a podcast episode, an audiobook chapter, or any longform script, pick the backend and voice that fit the piece; a backend whose model reads inline `[emotion]` tags (`supports_emotion_tags`) lets you direct delivery straight in the script. Each pass writes a permanent audio file and records the full transcript in `voice.db`, so you can iterate on the wording, re-render, and keep every take in your history while you settle on the final cut. On a backend without emotion support, any `[bracket]` tags in your script are stripped before synthesis, so you can leave editorial notes inline without them being read aloud.

```bash
voice-say render --file=./episode-01.md --title="Episode 1" --series="My Show" --episode=1
```

## Quick spoken status pings from shell scripts

voice-say is small enough to drop into shell scripts for spoken notifications — a build that finished, a deploy that went green, a long job that just completed. Short utterances like these are classified as a **"say"** (longer text becomes a `"render"`); see [Configuration](../setup/configuration.md) for the exact `say_threshold_chars` rule. The app surfaces "says" as a built-in category, so your status pings stay grouped and easy to scan. The result is a spoken ping that lands in history with its full transcript, costs nothing per use, and never leaves the machine.

```bash
make build && voice-say render "build finished"   # short → kind: "say"
```

## Finding an old render by what it said

Because every render stores its full transcript in `voice.db`, you can search across everything you have ever spoken by content rather than by filename or date. The daemon exposes `GET /search?q=<query>&limit=<n>`, which runs an FTS5 full-text query over the transcripts and returns the matching renders newest-first in the same `{entries, total}` shape as `/history`. The macOS app offers a transcript search too — its search field matches against the full transcript of every loaded render — so you can type a phrase you remember and jump straight back to the audio that contained it.
