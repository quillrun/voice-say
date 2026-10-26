#!/usr/bin/env bash
# doctor.sh — preflight: report which optional deps are present or missing, with
# the install command for each. Informational only; never fails the build.
set -uo pipefail

ok()   { printf '  [ok] %s\n' "$1"; }
miss() { printf '  [--] %s -- %s\n' "$1" "$2"; }

echo ""
echo "voice-say doctor -- environment check"
echo ""

# --- daemon (required): the Python make setup builds the venv with ---
py=""
for c in python3.12 python3.11 python3.10; do command -v "$c" >/dev/null 2>&1 && { py="$c"; break; }; done
if [ -n "$py" ]; then
  ok "$py ($("$py" --version 2>&1 | awk '{print $2}'))  [the daemon venv, make setup]"
else
  miss "python3.12" "REQUIRED for the daemon -- 'brew install python@3.12' (3.10-3.12 work)"
fi

# --- CLI playback ---
command -v mpv   >/dev/null 2>&1 && ok "mpv  [CLI headless playback]"   || miss "mpv"   "CLI playback -- 'brew install mpv' (not needed for --no-play or the macOS app)"
command -v socat >/dev/null 2>&1 && ok "socat  [CLI player IPC socket]" || miss "socat" "CLI player control -- 'brew install socat'"

# --- longform audio (ffmpeg) ---
command -v ffmpeg  >/dev/null 2>&1 && ok "ffmpeg  [longform concat/trim]" || miss "ffmpeg"  "needed for longform rendering (chunk concat/trim) -- 'brew install ffmpeg'"

# --- read-along helper and macOS app (macOS 26 + Xcode / Command Line Tools) ---
macos_major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
if [ "${macos_major:-0}" -ge 26 ] 2>/dev/null; then
  ok "macOS $(sw_vers -productVersion)  [read-along helper, macOS app]"
else
  miss "macOS 26" "read-along word timings and the macOS app need macOS 26; renders work without"
fi
command -v swiftc >/dev/null 2>&1 && ok "swiftc  [builds the read-along helper]" || miss "swiftc" "read-along helper -- 'xcode-select --install'"

# --- default backend (Kokoro on mlx-audio) ---
if command -v brew >/dev/null 2>&1 && [ -f "$(brew --prefix)/lib/libespeak-ng.dylib" ]; then
  ok "espeak-ng  [Kokoro's phonemizer, make kokoro]"
else
  miss "espeak-ng" "the default Kokoro backend -- 'brew install espeak-ng'"
fi

echo ""
echo "Legend: [ok] present   [--] missing/optional (with how to get it)."
echo ""
