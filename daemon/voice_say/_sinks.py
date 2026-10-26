"""Filesystem sinks for the render pipeline.

Audio is the only artefact written to the filesystem now — the render
record (incl. full transcript), progress, and overlays all live in the
SQLite store (`_db.py`). The contract is:

  archive (mp3/wav)  →  db row (renders, full text)

Atomic-write discipline (tmp + rename) keeps a SIGKILL from leaving a
partial audio file on disk. `build_entry` shapes the canonical dict that
`_db.insert_render` persists and the render SSE event carries.
"""
from __future__ import annotations

import json
import math
import shutil
import os
import re
import secrets
import subprocess
import sys
import tempfile
import time
import wave
from array import array
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import config


def _tool(name: str) -> str:
    """PATH first, then the Homebrew prefixes: launchd starts the daemon with a
    minimal PATH that holds neither."""
    for path in (shutil.which(name), f"/opt/homebrew/bin/{name}", f"/usr/local/bin/{name}"):
        if path and Path(path).exists():
            return path
    return name


FFMPEG = _tool("ffmpeg")
FFPROBE = _tool("ffprobe")


class ConcatError(Exception):
    """WAV concat → single mp3 encode failed. Carried up as a RenderError
    'archive' stage by the longform engine path."""


ARCHIVE_ROOT = config.ARCHIVE_ROOT


def locate_audio(path: str | Path) -> Path | None:
    """A row's audio on disk: its archive path, else where retention moved it
    (ARCHIVE_ROOT/.cold/<same relative path>; the row keeps the old path)."""
    p = Path(path)
    if p.exists():
        return p
    try:
        rel = p.resolve().relative_to(ARCHIVE_ROOT.resolve())
    except ValueError:
        return None
    cold = ARCHIVE_ROOT / ".cold" / rel
    return cold if cold.exists() else None


def keep_wavs(paths: list[Path], name: str) -> Path:
    """Move a failed episode's chunk wavs out of the temp dir into
    ARCHIVE_ROOT/.failed/<name>/ (numbered in order) so finished audio
    survives when even the draft save failed. Returns the directory."""
    dst = ARCHIVE_ROOT / ".failed" / name
    dst.mkdir(parents=True, exist_ok=True)
    for i, src in enumerate(paths):
        try:
            shutil.move(str(src), dst / f"{i:04d}.wav")
        except OSError:
            pass
    return dst


# Every transient file the pipeline makes is a "vs-" mkstemp in its own
# folder under the temp dir (chunk wavs, trims, pads, resume leads, concat
# lists). A render cleans its own in a finally; a daemon killed mid-render
# can't, so startup sweeps any older than this (a live render's files are
# minutes old at most). The folder keeps the sweep off other programs' files.
STALE_TEMP_S = 24 * 3600


def temp_dir() -> Path:
    d = Path(tempfile.gettempdir()) / "voice-say"
    d.mkdir(mode=0o700, exist_ok=True)
    return d


def sweep_stale_temps(max_age_s: float = STALE_TEMP_S, root: Path | None = None) -> int:
    """Delete "vs-*" temp files older than max_age_s. Returns how many."""
    root = Path(root or temp_dir())
    cutoff = time.time() - max_age_s
    n = 0
    for p in root.glob("vs-*"):
        try:
            if p.is_file() and p.stat().st_mtime < cutoff:
                p.unlink()
                n += 1
        except OSError:
            pass
    return n


def unlink_quiet(*paths: Path) -> None:
    """Best-effort delete: a missing or undeletable file is ignored."""
    for p in paths:
        try:
            p.unlink()
        except OSError:
            pass


def _temp_path(prefix: str, suffix: str = ".wav") -> Path:
    """Reserve an empty temp file (mkstemp, fd closed) and return its path."""
    fd, name = tempfile.mkstemp(suffix=suffix, prefix=prefix, dir=temp_dir())
    os.close(fd)
    return Path(name)


def archive_write(audio: bytes, stem: str, fmt: str = "mp3") -> Path:
    """Write audio atomically into the dated archive tree using the
    backend's container format as the extension (mp3, or wav for backends
    that return PCM WAV). Returns the final path."""
    now = datetime.now(timezone.utc)
    dir_ = ARCHIVE_ROOT / f"{now.year:04d}" / f"{now.month:02d}"
    dir_.mkdir(parents=True, exist_ok=True)
    path = dir_ / f"{stem}.{fmt}"
    tmp = path.with_suffix(f".{fmt}.tmp")
    tmp.write_bytes(audio)
    tmp.replace(path)
    return path


def build_entry(text: str, kind: str, backend: str, voice: str, speed: float,
                archive_path: Path, audio: bytes, ts: str,
                tags: list[str], duration_s: float,
                fmt: str = "mp3",
                resume_full_text: str | None = None,
                resume_char_offset: int | None = None,
                render_elapsed_s: float | None = None,
                seam_map: list | None = None) -> dict[str, Any]:
    """The same dict that's inserted into the `renders` table and
    broadcast as the render SSE event. Stores the full transcript.

    ``resume_full_text`` / ``resume_char_offset`` are set ONLY for a
    save-and-stop partial (a "draft"): the joined full text it was chunked
    from + the clean chunk-boundary offset it reached. Both None for every
    normal render → the renders row carries NULL (no behaviour change).

    ``render_elapsed_s`` is the wall-clock seconds the render took (TTS +
    archive + probe). None for callers that don't measure it → the row carries
    NULL and the client shows "Unknown" rather than a synthesized value."""
    chars = len(text)
    # Real whitespace-token word count (was the estimate round(chars / 5)). `text`
    # is the stored transcript, so split() is exact — this makes the WORDS tile,
    # wordsPerMinute, and read-time MEASURED, not estimated. Strip inline
    # [emotion]/<angle> markup first: it survives on rows from a backend with
    # supports_emotion_tags (the daemon doesn't strip them from the stored text
    # there) and would otherwise inflate the count. The angle arm is constrained to
    # tag-like tokens (NOT a loose `<[^>]*>`) so prose comparisons like "a < b"
    # survive — this pattern is a COUPLED PAIR with the Swift word-count /
    # derivedTitle strip in the macOS client; keep the two byte-equivalent.
    words = max(1, len(re.sub(r"\[[^\]]*\]|</?[a-zA-Z][a-zA-Z0-9_]*\s*/?>", " ", text).split()))
    return {
        "ts": ts,
        "kind": kind,
        "backend": backend,
        "voice": voice,
        "speed": float(speed),
        "format": fmt,
        "chars": chars,
        "words": words,
        "duration_s": float(duration_s),
        "bytes": len(audio),
        "archive_name": archive_path.name,
        "archive_path": str(archive_path),
        "text": text,
        "tags": tags,
        "resume_full_text": resume_full_text,
        "resume_char_offset": resume_char_offset,
        "render_elapsed_s": (float(render_elapsed_s)
                             if render_elapsed_s is not None else None),
        # Per-chunk read-along seams [[audio_s, char_off], ...] (longform/stream
        # only); None for a single render where uniform mapping is already exact.
        "seam_map": seam_map,
    }


def stem(text: str) -> str:
    """`voice-<slug>-<utc-stamp>-<hex>` filename stem. The 4-hex suffix
    guarantees no collisions even when two renders land in the same
    UTC second."""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    suffix = secrets.token_hex(2)
    words = re.findall(r"[a-z0-9]+", text.lower())[:4]
    slug = "-".join(words)[:32]
    return f"voice-{slug}-{stamp}-{suffix}" if slug else f"voice-{stamp}-{suffix}"


def probe_duration_s(path: Path, fmt: str = "mp3") -> float:
    """Mutagen-based duration probe. WAV reads via
    `mutagen.wave.WAVE`; everything else via `mutagen.mp3.MP3`. Returns
    0.0 on any failure; VoiceSay's `POST /progress/<ts>` with explicit
    duration is the fallback for unprobeable files."""
    try:
        if fmt == "wav":
            from mutagen.wave import WAVE
            return float(WAVE(str(path)).info.length)
        from mutagen.mp3 import MP3
        return float(MP3(str(path)).info.length)
    except Exception:
        return 0.0


# Resume: decode an archived mp3 back to a leading WAV.

def decode_mp3_to_wav(src: Path) -> Path:
    """Decode an archived mp3 to a temp s16le WAV so it can be the LEADING
    segment of a concat_wavs_to_mp3 resume (continue-a-draft). The mp3 kept
    the sample rate and channels of the backend that rendered the draft, and
    the resume renders on that same backend, so decoding at the native rate
    matches the new chunks and concat's sample-rate assertion passes (a fixed
    24 kHz broke resume on a 22.05 or 48 kHz backend). Caller owns cleanup
    (the resume path drops it with the other transient wavs).

    NOTE: re-decoding the draft mp3 and re-encoding it inside the resume concat
    is a SECOND libmp3lame generation for the draft prefix. For speech at
    -q:a 2 this is expected to be inaudible, but it is not measured here.

    This COMPOUNDS on recursive drafts: a resumed render can be Stop&kept again,
    and the next resume decodes THIS (already gen-2) mp3 and re-encodes it — so
    after N stop/resume cycles the original prefix is gen-(N+1), and every
    earlier tail gains a generation each cycle. Still unmeasured; for a long
    narration resumed many times the cumulative loss could eventually be
    audible. If it ever matters, keep the draft's per-chunk WAVs (or a lossless
    sidecar) so resume concatenates from original PCM instead of re-decoding."""
    out = _temp_path("vs-resume-lead-")
    try:
        subprocess.run(
            [FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", str(src),
             "-c:a", "pcm_s16le", str(out)],
            capture_output=True, text=True, timeout=300, check=True,
        )
        if not out.exists() or out.stat().st_size == 0:
            raise ConcatError("ffmpeg produced an empty leading wav")
        return out
    except subprocess.CalledProcessError as exc:
        out.unlink(missing_ok=True)
        raise ConcatError(
            f"ffmpeg decode mp3→wav failed (rc={exc.returncode}): "
            f"{(exc.stderr or '')[:300]}") from exc
    except (OSError, subprocess.SubprocessError) as exc:
        out.unlink(missing_ok=True)
        raise ConcatError(f"ffmpeg decode invocation failed: {exc}") from exc
    except BaseException:
        # Empty-wav ConcatError, timeout, or cancellation — drop the temp the
        # caller never received, then re-raise unchanged (no leaked vs-resume-lead-*).
        out.unlink(missing_ok=True)
        raise


# Longform: gapless WAV concat → single mp3 encode.

def _probe_sample_rate(path: Path) -> int | None:
    """ffprobe the first audio stream's sample rate (Hz). Returns None if
    the probe fails or the file has no audio stream."""
    try:
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-select_streams", "a:0",
             "-show_entries", "stream=sample_rate",
             "-of", "json", str(path)],
            capture_output=True, text=True, timeout=60, check=True,
        ).stdout
        streams = json.loads(out).get("streams") or []
        if not streams:
            return None
        return int(streams[0]["sample_rate"])
    except Exception:
        return None


# Inter-chunk seam control. Each long-form chunk is generated independently and
# carries its own leading silence (~160 ms) AND a long trailing silence
# (~480 ms on some models, which emit a long tail). Concatenated raw, every
# seam is (prev chunk's trailing + next chunk's leading) ≈ 400-640 ms of
# dead-air. Before the concat we trim BOTH ends of each chunk down to a short
# lead-in and a natural sentence-pause tail, so the seam is a uniform ~210 ms
# pause instead of a gap (the archive concat then pads it to a paragraph pause,
# see _seam_pad). Degenerate all-silence chunks (which trimming would empty)
# pass through untrimmed.
_SILENCE_THRESHOLD = "-55dB"
_LEAD_KEEP_S = 0.03   # leading silence retained per chunk (prompt but not abrupt)
_TRAIL_KEEP_S = 0.18  # trailing silence retained = the inter-chunk sentence pause
# A trimmed chunk smaller than this is treated as "emptied" (all-silence) →
# keep the original. 24 kHz mono s16le ≈ 48000 B/s, so ~60 ms of audio above
# the 44-byte WAV header.
_TRIM_MIN_BYTES = 3000


def _trim_chunk_silence(src: Path, dst: Path, trailing: bool = True) -> Path:
    """Trim leading (and, by default, trailing) silence from one chunk WAV into
    ``dst``, keeping a short lead-in and a natural trailing pause. Returns
    ``dst`` on a clean trim, or ``src`` unchanged if ffmpeg fails or the trim
    emptied the chunk (an all-silence chunk — trimming it would drop real
    duration). Trailing is trimmed via the standard areverse / silenceremove /
    areverse idiom.

    ``trailing=False`` trims ONLY the leading silence and preserves the chunk's
    natural tail. Use it for the FINAL chunk of a render: it has no following
    seam, so trimming its trailing silence eats into the last word's soft decay
    (a quiet final consonant/vowel under the threshold) and clips it — the "last
    word cut abruptly" bug. The trailing trim exists for inter-chunk seam
    uniformity, which the last chunk doesn't need."""
    lead = (f"silenceremove=start_periods=1:start_threshold={_SILENCE_THRESHOLD}"
            f":start_silence={_LEAD_KEEP_S}")
    if trailing:
        trail = (f"silenceremove=start_periods=1:start_threshold={_SILENCE_THRESHOLD}"
                 f":start_silence={_TRAIL_KEEP_S}")
        af = f"{lead},areverse,{trail},areverse"
    else:
        af = lead
    try:
        subprocess.run(
            [FFMPEG, "-hide_banner", "-loglevel", "error", "-y", "-i", str(src),
             "-af", af,
             "-c:a", "pcm_s16le", str(dst)],
            capture_output=True, text=True, timeout=120, check=True,
        )
    except (subprocess.SubprocessError, OSError):
        return src
    try:
        if dst.stat().st_size < _TRIM_MIN_BYTES:
            return src
    except OSError:
        return src
    return dst


def trim_chunk_silence_inplace(path: Path, trailing: bool = True) -> Path:
    """Trim ``path``'s leading + trailing silence IN PLACE, to the same uniform
    seam pause the archive concat applies (delegates to _trim_chunk_silence).

    ffmpeg cannot read and write one file in a single pass, so the trim writes
    a temp and then atomically replaces ``path``. Used by the streaming render
    so play-while-rendering plays the SAME seam-tightened chunks the final
    archive is built from — without this the live stream plays each chunk's raw
    ~480 ms trailing silence as a gap at every seam while only the archive
    sounded tight. On ANY ffmpeg failure / emptied trim the file is left
    byte-for-byte unchanged (seam stays loose, playback never breaks). Always
    returns ``path`` — the canonical chunk path is stable for the caller.

    ``trailing=False`` preserves the natural tail (leading-only trim) — pass it
    for the FINAL planned chunk so live playback and the transient wav the
    concat joins both keep the last word's decay (see _trim_chunk_silence)."""
    tmp = _temp_path("vs-trim-inplace-")
    # _trim_chunk_silence returns `tmp` only on a clean, non-emptied trim;
    # otherwise it returns the src (`path`) and `tmp` is unusable.
    if _trim_chunk_silence(path, tmp, trailing=trailing) == tmp:
        try:
            os.replace(tmp, path)  # atomic; tmp no longer exists afterwards
            return path
        except OSError:
            pass
    unlink_quiet(tmp)
    return path


# Seam pause. The trim leaves ~0.21 s at a seam (0.18 tail + 0.03 lead), less
# when a chunk stops hot. Longform seams fall on paragraph breaks, where the
# voice's own pause runs ~0.53 s; measured joins ran
# 0-320 ms, 3 of 4 with no end decay — the "jagged" ones. So each seam is
# padded up to _SEAM_PAUSE_S with room tone tiled from the previous chunk's
# quietest stretch (never digital zero: dead air reads as a dropout), and a
# chunk that stops at full level gets a short fade so the edge doesn't click.
_SEAM_PAUSE_S = 0.53
_FRAME_S = 0.01
_SLAM_S = 0.06       # a tail quieter than this is a hard stop → fade it
_TAPER_S = 0.02
_TILE_S = 0.09
_SCAN_S = 3.0        # room tone is sought in the previous chunk's last seconds
_QUIET_RMS = 32768 * 10 ** (int(_SILENCE_THRESHOLD.removesuffix("dB")) / 20)


def _read_pcm(path: Path) -> tuple[array, int] | None:
    """(samples, rate) of a mono s16le WAV, or None for any other layout."""
    with wave.open(str(path), "rb") as w:
        if w.getsampwidth() != 2 or w.getnchannels() != 1:
            return None
        pcm = array("h", w.readframes(w.getnframes()))
        rate = w.getframerate()
    if sys.byteorder != "little":
        pcm.byteswap()
    return pcm, rate


def _write_pcm(path: Path, pcm: array, rate: int) -> None:
    out = array("h", pcm)
    if sys.byteorder != "little":
        out.byteswap()
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(out.tobytes())


def _rms(pcm: array, start: int, n: int) -> float:
    seg = pcm[start:start + n]
    return math.sqrt(sum(s * s for s in seg) / len(seg)) if seg else 0.0


def _quiet_frames(pcm: array, rate: int, lead: bool) -> int:
    """Samples of sub-threshold audio at the lead or tail edge, in 10 ms frames."""
    fr = int(rate * _FRAME_S)
    n = 0
    while (n + 1) * fr <= len(pcm):
        start = n * fr if lead else len(pcm) - (n + 1) * fr
        if _rms(pcm, start, fr) >= _QUIET_RMS:
            break
        n += 1
    return n * fr


def _room_tone(pcm: array, rate: int, n: int) -> array:
    """n samples tiled from the quietest _TILE_S window of pcm's last _SCAN_S,
    alternating forward/reversed so every weld is sample-continuous."""
    fr, want = int(rate * _FRAME_S), int(rate * _TILE_S)
    lo = max(0, len(pcm) - int(rate * _SCAN_S))
    starts = range(lo, max(lo + 1, len(pcm) - want + 1), fr)
    at = min(starts, key=lambda s: _rms(pcm, s, want))
    tile = pcm[at:at + want] or array("h", [0])
    out, flip = array("h"), False
    while len(out) < n:
        out.extend(tile[::-1] if flip else tile)
        flip = not flip
    return out[:n]


def _seam_pad(prev: Path, nxt: Path, dst: Path, fade_prev: bool) -> Path | None:
    """Write the room-tone pad that brings the prev→nxt pause up to
    _SEAM_PAUSE_S into ``dst``; None when the pause is already long enough or
    either WAV can't be read (the seam then stays as trimmed). With
    ``fade_prev`` (prev is our own temp), a hard-stopping prev gets a _TAPER_S
    cos² fade in place."""
    try:
        a, b = _read_pcm(prev), _read_pcm(nxt)
        if a is None or b is None or a[1] != b[1] or not a[0]:
            return None
        (pa, rate), (pb, _) = a, b
        tail = _quiet_frames(pa, rate, lead=False)
        if fade_prev and tail < rate * _SLAM_S:
            k = min(int(rate * _TAPER_S), len(pa))
            for i in range(k):
                g = math.cos(math.pi / 2 * (i + 1) / k) ** 2
                pa[len(pa) - k + i] = int(pa[len(pa) - k + i] * g)
            _write_pcm(prev, pa, rate)
            tail = _quiet_frames(pa, rate, lead=False)
        need = int(rate * _SEAM_PAUSE_S) - tail - _quiet_frames(pb, rate, lead=True)
        if need <= 0:
            return None
        _write_pcm(dst, _room_tone(pa, rate, need), rate)
        return dst
    except (OSError, EOFError, wave.Error):
        return None


def concat_wavs_to_mp3(wav_paths: list[Path], out_stem: str) -> Path:
    """Seam-tightened concat of per-chunk WAVs into ONE archive mp3.

    Why WAV→PCM concat then a single encode (not `mp3 -c copy`): each
    per-chunk mp3 carries LAME encoder priming + end padding, so naive
    mp3 concatenation leaves audible ~50-100 ms clicks at every seam.
    Decoding each chunk to PCM, concatenating at the sample level, and
    doing a SINGLE libmp3lame encode yields one seam-free track.

    Before concatenating, each chunk's leading + trailing silence is trimmed
    (see _trim_chunk_silence) so per-chunk dead-air doesn't stack at the seam,
    then each seam is padded with room tone to a ~530 ms paragraph pause
    (see _seam_pad).

    Kokoro emits 24 kHz mono and other backends may differ; assert the
    chunks' sample rates agree so a backend/voice mismatch surfaces as a clear error instead of
    silent pitch/speed corruption from ffmpeg's implicit resample.

    Returns the final mp3 path in the dated archive tree.
    """
    if not wav_paths:
        raise ConcatError("no chunk WAVs to concat")

    # 1. Probe + assert a consistent sample rate across all chunks.
    rates: list[int] = []
    for p in wav_paths:
        sr = _probe_sample_rate(p)
        if sr is None:
            raise ConcatError(f"could not probe sample rate of {p.name}")
        rates.append(sr)
    if len(set(rates)) != 1:
        raise ConcatError(
            f"inconsistent sample rates across chunks: {sorted(set(rates))}")

    now = datetime.now(timezone.utc)
    dir_ = ARCHIVE_ROOT / f"{now.year:04d}" / f"{now.month:02d}"
    dir_.mkdir(parents=True, exist_ok=True)
    out_path = dir_ / f"{out_stem}.mp3"
    tmp_out = out_path.with_suffix(".mp3.tmp")

    # 1.5 Trim each chunk's leading + trailing silence into a temp WAV (or
    # fall back to the original for all-silence chunks). The concat then joins
    # the trimmed chunks, collapsing the stacked-silence seam gaps to a uniform
    # natural pause. The FINAL chunk keeps its natural tail (trailing=False): it
    # has no following seam, so trailing-trimming it would clip the last word's
    # soft decay (the "last word cut abruptly" bug).
    trim_temps: list[Path] = []
    concat_paths: list[Path] = []
    last_idx = len(wav_paths) - 1
    for i, p in enumerate(wav_paths):
        t = _temp_path("vs-trim-")
        trim_temps.append(t)
        concat_paths.append(_trim_chunk_silence(p, t, trailing=(i != last_idx)))

    # 1.6 Pad each seam to a paragraph pause with room tone (see _seam_pad).
    # Only our own trimmed temps are faded in place, never a caller's file.
    own = set(trim_temps)
    joined: list[Path] = []
    for i, p in enumerate(concat_paths):
        joined.append(p)
        if i < last_idx:
            pad = _temp_path("vs-pad-")
            trim_temps.append(pad)
            if _seam_pad(p, concat_paths[i + 1], pad, fade_prev=p in own):
                joined.append(pad)
    concat_paths = joined

    # 2. ffmpeg concat demuxer reads a list file of the WAVs; -c:a
    # libmp3lame forces a single re-encode of the concatenated PCM.
    # The concat demuxer decodes each WAV to PCM and joins at the sample
    # boundary — no mp3-frame copy, so no priming/padding clicks.
    list_fd, list_name = tempfile.mkstemp(suffix=".txt", prefix="vs-concat-", dir=temp_dir())
    list_path = Path(list_name)
    try:
        with open(list_fd, "w") as fh:
            for p in concat_paths:
                # ffmpeg concat list syntax: single-quote the path, escape
                # any embedded single quotes per ffmpeg's own escaping rules.
                esc = str(p.resolve()).replace("'", r"'\''")
                fh.write(f"file '{esc}'\n")

        try:
            subprocess.run(
                # `-f mp3` on the OUTPUT side is required: the temp filename
                # ends in `.mp3.tmp`, so ffmpeg can't infer the muxer from
                # the extension and would error "Unable to choose an output
                # format". `-f concat` on the input demuxes the WAV list.
                [FFMPEG, "-hide_banner", "-loglevel", "error", "-y",
                 "-f", "concat", "-safe", "0", "-i", str(list_path),
                 "-c:a", "libmp3lame", "-q:a", "2",
                 "-f", "mp3", str(tmp_out)],
                capture_output=True, text=True, timeout=900, check=True,
            )
        except subprocess.CalledProcessError as exc:
            raise ConcatError(
                f"ffmpeg concat→mp3 failed (rc={exc.returncode}): "
                f"{(exc.stderr or '')[:300]}") from exc
        except (OSError, subprocess.SubprocessError) as exc:
            raise ConcatError(f"ffmpeg invocation failed: {exc}") from exc

        if not tmp_out.exists() or tmp_out.stat().st_size == 0:
            raise ConcatError("ffmpeg produced an empty mp3")
        tmp_out.replace(out_path)
        return out_path
    finally:
        unlink_quiet(list_path, *trim_temps, tmp_out)
