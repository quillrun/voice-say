"""Daemon configuration — layered: env > config.local.toml > config.example.toml.

Centralizing config in one module means engine.py and friends import
constants from here instead of computing them at import time. That keeps
the test suite hermetic (set env vars, reload config) and lets you
override anything without editing source.

Resolution order, highest precedence first:

  1. Environment variables (the ``VOICE_SAY_*`` names below).
  2. ``config.local.toml``  — gitignored; pointed at by ``VOICE_SAY_CONFIG``
     or found next to ``config.example.toml``. Your local settings live here.
  3. ``config.example.toml`` — the committed generic baseline.
  4. In-code defaults (this file) — last resort if no TOML ships.

Env vars (all optional; they win over the TOML files):

  VOICE_SAY_PORT            HTTP daemon port. Default 8890.
  VOICE_SAY_DAEMON_URL      URL the voice-say CLI uses to reach the daemon.
  VOICE_SAY_DATA_ROOT       Parent dir for the archive + the SQLite db.
                            Layout: voice-archive/YYYY/MM/<stem>.mp3,
                            voice.db (renders + progress + overlays).
  VOICE_SAY_SAY_THRESHOLD_CHARS  Renders whose text is <= this land in the
                            "say" kind (short utterances); longer ones are
                            "render". Default 280.
  VOICE_SAY_DEFAULT_BACKEND Backend used when the caller omits one.
  VOICE_SAY_DEFAULT_VOICE   Voice used when the caller omits one (overrides
                            the per-backend default).
  VOICE_SAY_BACKENDS_CONFIG Path to a JSON file overriding the backend
                            catalog. Schema: {id: {label, url, model,
                            default_voice, voices, supports_speed,
                            supports_emotion_tags, accent, timeout_s,
                            output_format}}. output_format ("mp3"|"wav",
                            default "mp3") drives the archive extension +
                            duration probe.
  VOICE_SAY_LONGFORM_MAX_CHUNKS  Upper bound on chunks per single longform
                            render (self-DoS / client-timeout guard).
                            Default 40 (~48k chars / ~45 min audio).
  VOICE_SAY_CONFIG          Path to a config.local.toml overlay.
  VOICE_SAY_CORS            Access-Control-Allow-Origin value for browser
                            clients on another origin. Unset = no CORS.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any


def env(name: str) -> str | None:
    """One ``VOICE_SAY_<X>`` environment variable, or None when unset."""
    return os.environ.get(name)

try:  # stdlib on 3.11+, tomli shim on 3.10
    import tomllib as _toml
except ModuleNotFoundError:  # pragma: no cover
    import tomli as _toml  # type: ignore[no-redef]


HOME = Path.home()

# config.example.toml + config.local.toml sit in the daemon dir (the parent
# of this package). Resolve relative to the file so it works installed too.
DAEMON_DIR = Path(__file__).resolve().parent.parent


class ConfigError(ValueError):
    """A config file exists but can't be parsed. Raised rather than read as
    empty: an empty read would start the daemon on the defaults (an empty
    library) and let the next Settings save overwrite the file."""


def _toml_load(path: Path) -> dict[str, Any]:
    try:
        with path.open("rb") as fh:
            data = _toml.load(fh)
    except FileNotFoundError:
        return {}
    except ValueError as e:   # tomllib.TOMLDecodeError
        raise ConfigError(f"cannot parse {path}: {e}") from None
    return data if isinstance(data, dict) else {}


def _local_config_path() -> Path:
    """Absolute path to the machine-local override file. Honors
    VOICE_SAY_CONFIG; otherwise sits next to config.example.toml."""
    raw = env("VOICE_SAY_CONFIG") or str(DAEMON_DIR / "config.local.toml")
    return Path(os.path.expanduser(raw))


def _load_files() -> dict[str, Any]:
    """Merge example (baseline) under local (overrides). Re-callable so
    reload() can pick up edits to config.local.toml without a restart."""
    example = _toml_load(DAEMON_DIR / "config.example.toml")
    local = _toml_load(_local_config_path())
    # local overrides example; env overrides both (handled per-key in _val).
    return {**example, **local}


_FILE: dict[str, Any] = _load_files()


def _val(key: str, env_var: str | None, default: Any) -> Any:
    """env_var (if set) > TOML key (if present) > default."""
    if env_var and (value := env(env_var)) is not None:
        return value
    if key in _FILE:
        return _FILE[key]
    return default


def _path(key: str, env_var: str, default: Path | None) -> Path | None:
    raw = _val(key, env_var, None)
    if raw is None or raw == "":
        return default
    p = Path(os.path.expanduser(str(raw)))
    # Relative to where it was written: the shell's directory for an env var, the
    # config file's directory for a TOML key. Absolute from here on, because the
    # archive paths the daemon hands out are read by clients in other directories.
    if not p.is_absolute():
        if env(env_var) is not None:
            base = Path.cwd()
        elif key in _toml_load(_local_config_path()):
            base = _local_config_path().parent
        else:
            base = DAEMON_DIR
        p = (base / p).resolve()
    return p


PORT: int = int(_val("daemon_port", "VOICE_SAY_PORT", 8890))

DATA_ROOT: Path = _path("data_root", "VOICE_SAY_DATA_ROOT",
                        HOME / ".local/share/voice-say") or (HOME / ".local/share/voice-say")
ARCHIVE_ROOT: Path = DATA_ROOT / "voice-archive"
# Single durable store: renders (incl. full transcript) + progress + overlays.
DB_PATH: Path = DATA_ROOT / "voice.db"

def _resolve_defaults() -> tuple[str, str | None]:
    """Compute (default_backend, default_voice) from env > TOML > in-code
    fallback. Pure: reads the live `_FILE` / environment on every call and
    does NOT cache — so reload() (which refreshes `_FILE` first) sees new
    values. The "kokoro" fallback matches DEFAULT_BACKENDS."""
    default_backend = str(_val("default_backend", "VOICE_SAY_DEFAULT_BACKEND", "kokoro"))
    # None = let each backend use its own default_voice.
    _dv = _val("default_voice", "VOICE_SAY_DEFAULT_VOICE", None)
    default_voice = str(_dv) if _dv not in (None, "") else None
    return default_backend, default_voice


DEFAULT_BACKEND: str
DEFAULT_VOICE: str | None
DEFAULT_BACKEND, DEFAULT_VOICE = _resolve_defaults()

# Renders with <= this many chars are classified kind="say" (short
# utterances / status pings); longer renders are kind="render". Surfaced
# as a built-in category in the app.
# The default mirrors config.example.toml's say_threshold_chars (the in-code
# last-resort fallback if no TOML ships); keep the two in sync. Defined once
# here so init and reload() below cannot drift.
_SAY_THRESHOLD_DEFAULT = 280
SAY_THRESHOLD_CHARS: int = int(
    _val("say_threshold_chars", "VOICE_SAY_SAY_THRESHOLD_CHARS", _SAY_THRESHOLD_DEFAULT))
MAX_RENDER_CHARS: int = int(_val("max_render_chars", None, 200_000))
# Upper bound on chunks per single longform render (enforced in engine.render_longform).
# Default 40 (~48k chars / ~45 min audio) is a client-timeout / self-DoS guard for
# the public HTTP surface; a trusted local box rendering long episodes server-side
# can raise it via TOML `longform_max_chunks` or VOICE_SAY_LONGFORM_MAX_CHUNKS.
LONGFORM_MAX_CHUNKS: int = int(_val("longform_max_chunks", "VOICE_SAY_LONGFORM_MAX_CHUNKS", 40))

# Read-along alignment (align.py): word timings measured from each render's
# audio by macOS's on-device recognizer, so the reader's highlight follows the
# voice. Off when `align = false` or the helper is not built (`make setup`);
# renders shorter than align_min_s keep the even pace, within a word there.
ALIGN_ENABLED: bool = str(_val("align", "VOICE_SAY_ALIGN", True)).lower() not in ("0", "false", "no", "off")
ALIGN_LOCALE: str = str(_val("align_locale", None, "en-US"))
ALIGN_MIN_S: float = float(_val("align_min_s", None, 15.0))

def _resolve_allowed_tags() -> list[str]:
    raw = _val("allowed_tags", None, [])
    return list(raw) if isinstance(raw, (list, tuple)) else []


ALLOWED_TAGS: list[str] = _resolve_allowed_tags()


def _resolve_pronounce() -> dict[str, str]:
    """TOML `[pronounce]` table: written word → how the voice should say it
    (e.g. a name the model mispronounces). Applied to the text sent to the
    backend only; the stored transcript keeps the written form."""
    raw = _val("pronounce", None, {})
    if not isinstance(raw, dict):
        return {}
    return {str(k): str(v) for k, v in raw.items() if str(k).strip() and str(v).strip()}


PRONOUNCE: dict[str, str] = _resolve_pronounce()

def _resolve_cors_origin(raw: Any) -> str | None:
    """One exact origin, echoed as Access-Control-Allow-Origin. "*" would let
    every open web page read the library, and a list would echo as its repr
    and match nothing, so both stop the daemon instead."""
    if raw in (None, ""):
        return None
    if not isinstance(raw, str) or raw.strip() == "*" or "," in raw:
        raise ConfigError(f"cors_origins must be one origin like "
                          f"'http://localhost:5173', got {raw!r}")
    return raw.strip()


CORS_ORIGIN: str | None = _resolve_cors_origin(_val("cors_origins", "VOICE_SAY_CORS", None))


#
# Out-of-the-box backend: Kokoro-82M (Apache-2.0) on mlx-audio's
# OpenAI-compatible server, started by hand or by launchd:
#   pip install "mlx-audio[server]" "misaki[en]"; python -m mlx_audio.server --port 8000
# (macOS: see docs/setup/backends.md for the espeak-ng step).
# Any server that answers POST /v1/audio/speech fits: an entry needs `url` and
# `model`, the rest has defaults (engine._build_backends); leave `voices` out and
# the daemon asks the server (GET /v1/audio/voices?model=). WAV, because
# mlx-audio encodes mp3 through ffmpeg. VOICE_SAY_BACKENDS_CONFIG (a JSON file)
# replaces this dict wholesale — see load_backends().
DEFAULT_BACKENDS: dict[str, dict[str, Any]] = {
    "kokoro": {
        "label": "Kokoro",
        "url": "http://127.0.0.1:8000",
        "model": "mlx-community/Kokoro-82M-bf16",
        "default_voice": "af_heart",
        "supports_speed": True,
        "accent": "#6ea8ff",
        "output_format": "wav",
    },
}



# --- Model-bypass mock (dev/test) -------------------------------------------
# NOT a backend. When a POST /render_longform carries mock=true,
# the engine SKIPS the model call and replays PRE-EXISTING chunk WAVs from
# MOCK_CHUNK_DIR on a timer — the normal render path, gapless concat, voice.db
# row, and episode_start/chunk_ready/episode_complete SSE all stay real; only
# the per-chunk audio bytes come from disk instead of the model. The fixtures
# are LOCAL-ONLY (gitignored), never shipped. See engine._mock_synth /
# render_longform(mock=...).
#   VOICE_SAY_MOCK_CHUNK_DIR   dir of pre-existing chunk WAVs (default daemon/mock-fixtures).
#   VOICE_SAY_MOCK_CHUNK_MS    per-chunk minimum pause ms — the floor for odd/0-duration
#                        fixtures (default 600).
#   VOICE_SAY_MOCK_RTF         per-chunk pause as a multiple of the fixture's OWN audio
#                        seconds (real-time factor; default 1.0 ≈ renders in the
#                        time it plays). A flat per-chunk timer made an N-chunk
#                        mock "finish" in N×0.6s while the audio played for far
#                        longer, so the render frontier raced to 100% almost
#                        instantly. 0 = no audio-scaled pause (used by tests).
#   VOICE_SAY_MOCK_CHUNK_MULT  how many times to cycle the fixture set, multiplying the
#                        chunk count (and total audio + render time). Default 2 —
#                        a longer, more granular mock render. 1 = one chunk per
#                        fixture (used by tests).
MOCK_CHUNK_DIR: Path = _path(
    "mock_chunk_dir", "VOICE_SAY_MOCK_CHUNK_DIR", DAEMON_DIR / "mock-fixtures"
) or (DAEMON_DIR / "mock-fixtures")
MOCK_CHUNK_MS: int = int(_val("mock_chunk_ms", "VOICE_SAY_MOCK_CHUNK_MS", 600))
MOCK_RTF: float = float(_val("mock_rtf", "VOICE_SAY_MOCK_RTF", 1.0))
MOCK_CHUNK_MULT: int = max(1, int(_val("mock_chunk_mult", "VOICE_SAY_MOCK_CHUNK_MULT", 2)))


def load_backends() -> dict[str, dict[str, Any]]:
    """Return the backend catalog, honoring VOICE_SAY_BACKENDS_CONFIG."""
    raw = env("VOICE_SAY_BACKENDS_CONFIG")
    if not raw:
        return DEFAULT_BACKENDS
    path = Path(os.path.expanduser(raw))
    if not path.exists():
        return DEFAULT_BACKENDS
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return DEFAULT_BACKENDS
    return data if isinstance(data, dict) else DEFAULT_BACKENDS


# Runtime-mutable settings — writable via POST /config.
#
# The macOS client (and any surface) can change the *default backend/voice*
# at runtime. Those persist to config.local.toml and reload() refreshes the
# in-process globals — every call site reads `config.DEFAULT_BACKEND` /
# `config.DEFAULT_VOICE` as live module attributes, so no restart is needed.
#
# Structural settings (paths, ports, the backend catalog) stay import-time
# only; changing them needs a daemon restart.

def reload() -> None:
    """Re-read the TOML files and refresh the runtime-mutable settings."""
    global _FILE, DEFAULT_BACKEND, DEFAULT_VOICE, SAY_THRESHOLD_CHARS, PRONOUNCE
    global ALLOWED_TAGS, LONGFORM_MAX_CHUNKS
    _FILE = _load_files()
    DEFAULT_BACKEND, DEFAULT_VOICE = _resolve_defaults()
    SAY_THRESHOLD_CHARS = int(
        _val("say_threshold_chars", "VOICE_SAY_SAY_THRESHOLD_CHARS", _SAY_THRESHOLD_DEFAULT))
    PRONOUNCE = _resolve_pronounce()
    ALLOWED_TAGS = _resolve_allowed_tags()
    LONGFORM_MAX_CHUNKS = int(_val("longform_max_chunks", "VOICE_SAY_LONGFORM_MAX_CHUNKS", 40))


def env_overrides_default_backend() -> bool:
    """True when VOICE_SAY_DEFAULT_BACKEND is set in the environment — in
    which case a written config.local.toml value is shadowed by the env
    var. Lets the POST /config handler warn honestly rather than claim a
    write took effect when env precedence silently won."""
    return env("VOICE_SAY_DEFAULT_BACKEND") is not None


def env_overrides_default_voice() -> bool:
    return env("VOICE_SAY_DEFAULT_VOICE") is not None


def env_overrides_say_threshold_chars() -> bool:
    return env("VOICE_SAY_SAY_THRESHOLD_CHARS") is not None


def write_local(updates: dict[str, Any]) -> Path:
    """Merge `updates` into config.local.toml and rewrite it.

    None-valued keys are skipped (to clear default_voice, pass an empty
    string — that round-trips back to DEFAULT_VOICE = None via _val). The
    file is gitignored (`*.local.toml`); comments are not preserved since
    tomli_w reserializes the data only.
    """
    import tomli_w  # write-only dep; read path uses stdlib tomllib

    path = _local_config_path()
    current = _toml_load(path)  # {} when the file does not exist yet
    current.update({k: v for k, v in updates.items() if v is not None})
    path.parent.mkdir(parents=True, exist_ok=True)
    # Write a sibling temp file and rename it over: a crash or full disk
    # mid-write leaves the old file, never an empty one.
    tmp = path.with_name(path.name + ".tmp")
    with tmp.open("wb") as fh:
        tomli_w.dump(current, fh)
    os.replace(tmp, path)
    return path
