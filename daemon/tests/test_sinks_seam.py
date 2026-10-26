"""Seam pause in the longform concat: each join is padded with room tone up to
a paragraph pause (_SEAM_PAUSE_S), a hard-stopping chunk gets a short fade, and
a seam that is already long enough is left alone."""
from __future__ import annotations

import math
import random
import shutil
from array import array
from pathlib import Path

import pytest

from voice_say import _sinks

RATE = 24000
FLOOR = 8          # room-tone amplitude, ~-72 dBFS: under the -55 dB threshold


def _chunk(path: Path, lead_s: float, tone_s: float, tail_s: float) -> None:
    rnd = random.Random(0)
    floor = lambda n: [rnd.randint(-FLOOR, FLOOR) for _ in range(n)]  # noqa: E731
    tone = [int(9000 * math.sin(2 * math.pi * 220 * i / RATE)) for i in range(int(RATE * tone_s))]
    _sinks._write_pcm(path, array("h", floor(int(RATE * lead_s)) + tone
                                  + floor(int(RATE * tail_s))), RATE)


def _len_s(path: Path) -> float:
    return len(_sinks._read_pcm(path)[0]) / RATE


def test_short_seam_padded_to_paragraph_pause_with_room_tone(tmp_path: Path):
    a, b, pad = tmp_path / "a.wav", tmp_path / "b.wav", tmp_path / "pad.wav"
    _chunk(a, 0.0, 0.5, 0.18)
    _chunk(b, 0.03, 0.5, 0.0)
    assert _sinks._seam_pad(a, b, pad, fade_prev=True) == pad
    assert _len_s(pad) == pytest.approx(_sinks._SEAM_PAUSE_S - 0.21, abs=0.02)
    pcm = _sinks._read_pcm(pad)[0]
    assert max(abs(s) for s in pcm) <= FLOOR          # room tone, not the voice
    assert any(pcm)                                    # and not digital zero


def test_long_seam_left_alone(tmp_path: Path):
    a, b, pad = tmp_path / "a.wav", tmp_path / "b.wav", tmp_path / "pad.wav"
    _chunk(a, 0.0, 0.5, 0.4)
    _chunk(b, 0.2, 0.5, 0.0)
    assert _sinks._seam_pad(a, b, pad, fade_prev=True) is None


def test_hard_stop_is_faded_only_when_ours(tmp_path: Path):
    a, b, pad = tmp_path / "a.wav", tmp_path / "b.wav", tmp_path / "pad.wav"
    _chunk(a, 0.0, 0.5, 0.0)                           # stops at full level
    _chunk(b, 0.0, 0.5, 0.0)
    before = _sinks._read_pcm(a)[0]
    _sinks._seam_pad(a, b, pad, fade_prev=False)
    assert _sinks._read_pcm(a)[0] == before            # a caller's file: untouched
    _sinks._seam_pad(a, b, pad, fade_prev=True)
    after = _sinks._read_pcm(a)[0]
    assert len(after) == len(before)
    assert abs(after[-1]) <= 1 and after[:-RATE // 10] == before[:-RATE // 10]
    assert _len_s(pad) == pytest.approx(_sinks._SEAM_PAUSE_S, abs=0.03)


def test_unreadable_wav_leaves_seam_as_is(tmp_path: Path):
    a, b, pad = tmp_path / "a.wav", tmp_path / "b.wav", tmp_path / "pad.wav"
    a.write_bytes(b"not a wav")
    _chunk(b, 0.0, 0.5, 0.0)
    assert _sinks._seam_pad(a, b, pad, fade_prev=True) is None


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed")
def test_concat_adds_the_pad(tmp_path: Path, isolated_paths):
    a, b = tmp_path / "a.wav", tmp_path / "b.wav"
    _chunk(a, 0.0, 1.0, 0.1)
    _chunk(b, 0.0, 1.0, 0.1)
    arch = _sinks.concat_wavs_to_mp3([a, b], "vs-test-seam-pad")
    # 1.0 + ~0.1 kept tail + pad up to 0.53 + 1.0 + 0.1 final tail ≈ 2.63 s
    assert _sinks.probe_duration_s(arch, "mp3") == pytest.approx(2.63, abs=0.08)
