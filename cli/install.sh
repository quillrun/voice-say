#!/usr/bin/env bash
# install.sh — symlink `voice-say` and `voice-ctl` into ~/.local/bin so they
# work from any shell (`voice-say render` makes audio). Idempotent.
#
# Usage:
#   bash install.sh
#   bash install.sh --prefix=/opt/voice-say   # custom target dir

set -euo pipefail

PREFIX="$HOME/.local/bin"
for arg in "$@"; do
  case "$arg" in
    --prefix=*) PREFIX="${arg#*=}" ;;
    --help|-h)  echo "usage: install.sh [--prefix=<dir>]"; exit 0 ;;
    *)          echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$PREFIX"

HERE="$(cd "$(dirname "$0")" && pwd -P)"

for tool in voice-say voice-ctl; do
  src="$HERE/$tool"
  dst="$PREFIX/$tool"
  if [ ! -f "$src" ]; then
    echo "ERR: missing $src" >&2
    exit 1
  fi
  chmod +x "$src"
  # Don't clobber a real `voice-say` file the operator placed here — if the
  # target exists, is a regular file (not our symlink), and differs from ours,
  # it's a local wrapper (personal defaults). Leave it. voice-ctl is unaffected.
  if [ "$tool" = "voice-say" ] && [ -f "$dst" ] && [ ! -L "$dst" ] && ! cmp -s "$src" "$dst"; then
    echo "NOTE: $dst is a regular file that differs from $src — leaving it (operator wrapper). Skipping relink." >&2
    continue
  fi
  ln -sfn "$src" "$dst"
  echo "linked: $dst -> $src"
done

# Earlier versions linked a `say` here, which shadowed macOS /usr/bin/say.
# Remove that link if it points into this repo; a file of your own stays.
old="$PREFIX/say"
if [ -L "$old" ] && [ "$(readlink "$old")" = "$HERE/say" ]; then
  rm "$old"
  echo "removed: $old (was voice-say's old name; /usr/bin/say is visible again)"
fi

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) echo
     echo "NOTE: $PREFIX is not on your PATH. Add this to your shell rc:"
     echo "    export PATH=\"$PREFIX:\$PATH\""
     ;;
esac

echo
echo "next steps:"
echo "  1. the default backend (from the repo root): make kokoro, then make kokoro-run"
echo "       (any other backend: docs/setup/backends.md)"
echo "     the daemon, in another terminal:          make run"
echo "  2. render something:                 voice-say render \"hello world\"   (library: voice-say history)"
