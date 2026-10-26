# voice-say daemon

The Python package behind [voice-say](https://github.com/quillrun/voice-say): local
text-to-speech for macOS. It installs two commands:

- `voice-say-daemon`: the HTTP daemon on `127.0.0.1:8890`. It sends text to a speech backend
  (Kokoro by default; any OpenAI-compatible speech server), saves the audio and the transcript
  to a local SQLite library, and streams events to its clients.
- `voice-say`: the library CLI (history, search, tags, voices, set; `voice-say render` makes audio).

Setup, configuration and the HTTP API are documented in the repository's
[README](https://github.com/quillrun/voice-say#readme) and
[docs](https://github.com/quillrun/voice-say/tree/main/docs).
