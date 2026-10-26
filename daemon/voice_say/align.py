"""Read-along alignment: where each word of a transcript is spoken in its audio.

The reader highlights by interpolating between ``[audio_s, char_offset]``
points (the row's ``seam_map``). Chunk seams alone give one point every few
minutes, so inside a chunk the highlight runs at an even pace and drifts from
the voice (median 0.8 s, max 3 s on an 18-min episode). Here macOS's on-device recognizer (SpeechTranscriber) transcribes
the audio with word timestamps, and its words are matched back to the stored
transcript: every matched word adds a point at its start. Words it misheard
fall between points and are interpolated. The measurement is of the audio
itself, so every backend and voice gets the same accuracy.

The recognizer runs in a small Swift helper (``align/words.swift``, built by
``make setup`` into ``.build/voice-say-words``): nothing to install, about 16 s
and 140 MB for an 18-min episode (mlx-whisper took 63 s, 2.9 GB and a 1 GB
venv; same words matched, timings within 0.08 s median).
One alignment runs at a time. Every failure returns None, and the caller keeps
the seams it already had.
"""
from __future__ import annotations

import asyncio
import difflib
import json
import logging
import re
from pathlib import Path

from . import config

log = logging.getLogger("voice_say")

# A transcript whose words match less than this share of the model's words is
# not the audio's script (wrong file, a hallucinating model): no points.
MIN_MATCH = 0.5

# The Swift helper (see the module docstring); the editable install keeps this
# file in the source tree, next to daemon/.build.
HELPER = Path(__file__).resolve().parents[1] / ".build" / "voice-say-words"

_WORD = re.compile(r"\S+")
_one_at_a_time = asyncio.Semaphore(1)
# What /health shows: the file being aligned now, and how many wait their turn.
running: str | None = None
waiting = 0


def available() -> bool:
    """True when alignment is on in the config and the helper is built."""
    return config.ALIGN_ENABLED and HELPER.is_file()


def _norm(word: str) -> str:
    return re.sub(r"[^0-9a-z]", "", word.lower())


def points(text: str, words: list, *, base_s: float = 0.0,
           base_char: int = 0) -> list[list[float]] | None:
    """``[[audio_s, char_offset], ...]`` at the start of each transcript word the
    model heard, strictly increasing in both. ``words`` is the model's
    ``[[start_s, end_s, word], ...]``; ``base_s`` / ``base_char`` shift the
    points into the episode's timeline and text (a chunk's start). None when
    under ``MIN_MATCH`` of the transcript's words were heard."""
    script = [(m.start(), _norm(m.group())) for m in _WORD.finditer(text)]
    script = [(off, w) for off, w in script if w]
    heard = [(float(s), _norm(w)) for s, _e, w in words if _norm(str(w))]
    if not script or not heard:
        return None
    matcher = difflib.SequenceMatcher(
        None, [w for _, w in script], [w for _, w in heard], autojunk=False)
    out: list[list[float]] = []
    matched = 0
    last_t, last_off = -1.0, -1
    for a, b, n in matcher.get_matching_blocks():
        for k in range(n):
            t, off = heard[b + k][0], script[a + k][0]
            matched += 1
            if t <= last_t or off <= last_off:
                continue  # a timestamp that steps back would bend the map backwards
            out.append([round(base_s + t, 3), base_char + off])
            last_t, last_off = t, off
    if matched < MIN_MATCH * len(script):
        log.info("align: %d of %d words matched; keeping the chunk seams",
                 matched, len(script))
        return None
    return out


async def transcribe(audio: Path, timeout_s: float = 900.0) -> list | None:
    """The model's ``[[start_s, end_s, word], ...]`` for ``audio``, or None."""
    global running, waiting
    waiting += 1
    try:
        await _one_at_a_time.acquire()
    finally:
        waiting -= 1
    running = audio.name
    try:
        return await _transcribe(audio, timeout_s)
    finally:
        running = None
        _one_at_a_time.release()


async def _transcribe(audio: Path, timeout_s: float) -> list | None:
    try:
        proc = await asyncio.create_subprocess_exec(
            str(HELPER), str(audio), config.ALIGN_LOCALE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    except OSError as exc:
        log.warning("align: could not start the aligner: %s", exc)
        return None
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout_s)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        log.warning("align: timed out after %.0f s on %s", timeout_s, audio.name)
        return None
    except asyncio.CancelledError:
        proc.kill()
        await proc.wait()
        raise
    if proc.returncode != 0:
        tail = err.decode(errors="replace").strip().splitlines()[-1:] or ["?"]
        log.warning("align: aligner exited %s on %s: %s", proc.returncode, audio.name, tail[0])
        return None
    try:
        return json.loads(out)
    except ValueError:
        log.warning("align: aligner output was not JSON for %s", audio.name)
        return None


async def align(audio: Path, text: str, *, base_s: float = 0.0,
                base_char: int = 0) -> list[list[float]] | None:
    """Transcribe ``audio`` and match it to ``text``: the word points, or None."""
    words = await transcribe(audio)
    if not words:
        return None
    return await asyncio.to_thread(points, text, words, base_s=base_s, base_char=base_char)

