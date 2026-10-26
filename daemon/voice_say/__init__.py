"""voice-say — centralized local TTS pipeline.

Three surfaces share one engine:

  - HTTP daemon (this package, default port 8890) — called by the app and
    the CLI (`voice-say render` renders and plays, the rest works the library)
  - Direct Python import (engine.render) — for tests + ad-hoc scripts

Every render flow goes through engine.render() so the on-disk contract
(audio archive file + a row in the SQLite store, incl. full transcript)
lives in exactly one place.
"""
__version__ = "2.0.1"
