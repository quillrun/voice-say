"""Idempotence of the per-chunk silence trim.

The streaming render trims each chunk in place (trim_chunk_silence_inplace) so
play-while-rendering matches the archive, then the final concat trims every
input AGAIN (_trim_chunk_silence). engine.py relies on that second pass being a
no-op ("The final concat re-trims idempotently") — if it shaved more off an
already-trimmed chunk, the live-streamed chunk and the archived chunk would
diverge, which is exactly what trim_chunk_silence_inplace was added to prevent.
This asserts the invariant on a real ffmpeg round-trip.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

from voice_say import _sinks

_FFMPEG = shutil.which("ffmpeg")
pytestmark = pytest.mark.skipif(_FFMPEG is None, reason="ffmpeg not installed")


def _make_padded_tone(path: Path) -> None:
    """~0.5 s silence + 1.0 s 220 Hz tone + ~0.5 s silence, 24 kHz mono s16le —
    the chunk format the backends emit. adelay/apad pad with true
    zeros so silenceremove detects the lead/trail silence cleanly."""
    subprocess.run(
        [_FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
         "-f", "lavfi", "-i", "sine=frequency=220:duration=1.0:sample_rate=24000",
         "-af", "adelay=500,apad=pad_dur=0.5",
         "-ar", "24000", "-ac", "1", "-c:a", "pcm_s16le", str(path)],
        capture_output=True, text=True, timeout=60, check=True,
    )


def test_trim_chunk_silence_is_idempotent(tmp_path: Path):
    wav = tmp_path / "chunk.wav"
    _make_padded_tone(wav)
    raw = _sinks.probe_duration_s(wav, "wav")

    _sinks.trim_chunk_silence_inplace(wav)
    once = _sinks.probe_duration_s(wav, "wav")
    # The first trim removes real leading/trailing silence (keeps only a short
    # lead + the inter-chunk pause), so it must actually shorten the ~2.0 s source.
    assert once < raw - 0.3, f"first trim barely changed the chunk: raw={raw:.3f} once={once:.3f}"

    _sinks.trim_chunk_silence_inplace(wav)
    twice = _sinks.probe_duration_s(wav, "wav")
    # The second trim on the already-trimmed chunk must be ~idempotent — the
    # streaming/archive parity engine.py relies on. A small ffmpeg rounding
    # epsilon is fine; a real re-trim would lop off the kept lead / pause.
    assert abs(twice - once) < 0.06, f"re-trim not idempotent: once={once:.3f} twice={twice:.3f}"


def _make_padded_tone_trail(path: Path, trail_s: float) -> None:
    """~0.5 s lead silence + 1.0 s 220 Hz tone + ``trail_s`` trailing silence,
    24 kHz mono s16le. The trailing pad is parameterized so the final-chunk
    tests can give the last chunk a distinctly long, unambiguous tail."""
    subprocess.run(
        [_FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
         "-f", "lavfi", "-i", "sine=frequency=220:duration=1.0:sample_rate=24000",
         "-af", f"adelay=500,apad=pad_dur={trail_s}",
         "-ar", "24000", "-ac", "1", "-c:a", "pcm_s16le", str(path)],
        capture_output=True, text=True, timeout=60, check=True,
    )


def test_trim_trailing_false_preserves_tail(tmp_path: Path):
    """`trailing=False` trims ONLY the leading silence and keeps the chunk's
    natural tail — the per-chunk primitive behind the final-chunk exception that
    fixes the 'last word cut abruptly' bug. The default (trailing=True) shaves
    the tail to the ~0.18 s inter-chunk seam pause; trailing=False must not."""
    tone = tmp_path / "tone.wav"
    _make_padded_tone_trail(tone, 0.6)

    seam = tmp_path / "seam.wav"   # interior chunk: trailing trimmed
    tail = tmp_path / "tail.wav"   # final chunk: trailing kept
    assert _sinks._trim_chunk_silence(tone, seam, trailing=True) == seam
    assert _sinks._trim_chunk_silence(tone, tail, trailing=False) == tail
    seam_dur = _sinks.probe_duration_s(seam, "wav")
    tail_dur = _sinks.probe_duration_s(tail, "wav")
    # Keeping the tail leaves materially more audio than shaving it to the seam.
    assert tail_dur > seam_dur + 0.25, (
        f"trailing=False did not preserve the tail: seam={seam_dur:.3f} tail={tail_dur:.3f}")


def test_final_chunk_tail_survives_concat(tmp_path: Path, isolated_paths):
    """The LAST chunk of a longform concat keeps its natural tail; only the
    interior chunks are trailing-trimmed for seam uniformity. Regression guard
    for the 'last word gets cut abruptly' bug — the final trailing trim used to
    eat into the last word's soft decay. `isolated_paths` redirects the archive
    write into tmp so this never touches the real archive tree."""
    interior = tmp_path / "interior.wav"
    final = tmp_path / "final.wav"
    _make_padded_tone_trail(interior, 0.5)
    _make_padded_tone_trail(final, 1.0)   # a distinctly long tail → unambiguous signal

    # Reference durations: interior trailing-trimmed (seam); final keeps its tail.
    seam_ref = tmp_path / "seam_ref.wav"
    kept_ref = tmp_path / "kept_ref.wav"
    _sinks._trim_chunk_silence(interior, seam_ref, trailing=True)
    _sinks._trim_chunk_silence(final, kept_ref, trailing=False)
    seam_dur = _sinks.probe_duration_s(seam_ref, "wav")
    kept_dur = _sinks.probe_duration_s(kept_ref, "wav")

    archive = _sinks.concat_wavs_to_mp3([interior, final], "vs-test-final-tail")
    arch_dur = _sinks.probe_duration_s(archive, "mp3")

    # The archive must contain the final chunk's FULL kept tail (≈ seam + kept).
    # Had concat trailing-trimmed the final chunk too (the old bug), it would be
    # ≈ 2*seam — far short of this bound (kept is ~0.8 s longer than seam here).
    assert arch_dur > seam_dur + kept_dur - 0.25, (
        f"final chunk tail clipped in concat: archive={arch_dur:.3f} "
        f"expected≈{seam_dur + kept_dur:.3f} (seam={seam_dur:.3f} kept={kept_dur:.3f})")
