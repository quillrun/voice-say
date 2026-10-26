.PHONY: help setup install-cli doctor run test publishable-check app kokoro kokoro-run

# Default target — list available targets.
help:
	@echo ""
	@echo "voice-say — available make targets"
	@echo ""
	@echo "  setup              Create venv + deps + config + CLI on PATH."
	@echo "  doctor             Preflight: report which optional deps are present/missing."
	@echo "  install-cli        Symlink the voice-say / voice-ctl CLI into ~/.local/bin."
	@echo "  run                Start the HTTP daemon (reads port from config/env)"
	@echo "  kokoro             Install the default backend (Kokoro on mlx-audio) in its own venv."
	@echo "  kokoro-run         Start the default backend on 127.0.0.1:8000."
	@echo "  app                Build the macOS app (clients/macos/build/VoiceSay.app)."
	@echo "  test               Run the test suite"
	@echo "  publishable-check  Run the publishable-check script"
	@echo ""

# One-command setup: venv + deps, CLI on PATH, config.local.toml seeded from
# the example. TTS backends (e.g. mlx-audio's server) are separate services.
# The venv is built with a tested Python (3.12, else 3.11, else 3.10), not
# whatever bare python3 is: Homebrew's mpv pulls a newer python3 onto PATH, and
# the system one is too old. SETUP_PYTHON=<path> picks another.
SETUP_PYTHON ?=
setup:
	@py="$(SETUP_PYTHON)"; \
	if [ -z "$$py" ]; then \
	    for c in python3.12 python3.11 python3.10; do command -v $$c >/dev/null && { py=$$c; break; }; done; \
	fi; \
	if [ -z "$$py" ] || ! "$$py" -c 'import sys; sys.exit(sys.version_info[:2] < (3, 10))' 2>/dev/null; then \
	    echo "make setup needs Python 3.10–3.12: brew install python@3.12 (or SETUP_PYTHON=<path>)."; exit 1; \
	fi; \
	echo "==> Daemon venv with $$py ($$("$$py" -c 'import platform; print(platform.python_version())'))"; \
	"$$py" -m venv daemon/.venv
	daemon/.venv/bin/pip install -e 'daemon[dev]'
	@# The read-along helper uses macOS 26's SpeechAnalyzer; without it the daemon
	@# runs with read-along off (align.available()).
	@if command -v swiftc >/dev/null && [ "$$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)" -ge 26 ] 2>/dev/null; then \
	    echo "==> Building the read-along helper (macOS Speech) …"; \
	    mkdir -p daemon/.build; \
	    swiftc -parse-as-library -O daemon/align/words.swift -o daemon/.build/voice-say-words \
	      || echo "Read-along helper did not build: renders work, read-along stays off."; \
	else \
	    echo "Skipping the read-along helper (needs macOS 26 + Xcode Command Line Tools): renders work, read-along stays off."; \
	fi
	@echo ""
	@echo "==> Installing the voice-say / voice-ctl CLI onto your PATH (~/.local/bin) …"
	@bash cli/install.sh
	@if [ ! -f daemon/config.local.toml ]; then \
	    cp daemon/config.example.toml daemon/config.local.toml; \
	    echo "Created daemon/config.local.toml from example — edit as needed."; \
	else \
	    echo "daemon/config.local.toml already exists — skipping copy."; \
	fi
	@echo ""
	@echo "Optional: start the daemon at login with launchd; see docs/setup/install.md."
	@echo ""
	@# Last, so it is not lost above: macOS's default PATH has no ~/.local/bin.
	@case ":$$PATH:" in *":$$HOME/.local/bin:"*) ;; *) \
	    echo "==> ~/.local/bin is not on your PATH, so the shell cannot find voice-say yet. Run:"; \
	    echo "      export PATH=\"\$$HOME/.local/bin:\$$PATH\""; \
	    echo "    and add the same line to ~/.zshrc to keep it."; \
	    echo "";; \
	esac

# The default backend: Kokoro-82M on mlx-audio's server, in its own venv (versions
# measured together). misaki is Kokoro's text-to-phoneme step; mlx-audio[server]
# doesn't pull it in. On macOS the espeak-ng library bundled by espeakng-loader
# exits the server on the first render (it looks for its data at the wheel's
# build path), so this venv's copy is pointed at Homebrew's espeak-ng. misaki
# needs Python < 3.13.
KOKORO_VENV ?= $(HOME)/.venvs/mlx-audio
KOKORO_PYTHON ?= python3.12
kokoro:
	@command -v $(KOKORO_PYTHON) >/dev/null || { echo "Kokoro's misaki needs Python 3.12 or older: brew install python@3.12 (or KOKORO_PYTHON=<path>)."; exit 1; }
	$(KOKORO_PYTHON) -m venv $(KOKORO_VENV)
	$(KOKORO_VENV)/bin/pip install "mlx-audio[server]==0.6.1" "misaki[en]==0.9.4"
	@if [ "$$(uname)" = "Darwin" ]; then \
	    if ! command -v brew >/dev/null || [ ! -f "$$(brew --prefix)/lib/libespeak-ng.dylib" ]; then \
	        echo "Kokoro needs Homebrew's espeak-ng on macOS: brew install espeak-ng, then make kokoro again."; exit 1; \
	    fi; \
	    ln -sf "$$(brew --prefix)/lib/libespeak-ng.dylib" \
	      "$$($(KOKORO_VENV)/bin/python -c 'import espeakng_loader as e; print(e.get_library_path())')"; \
	    echo "espeak-ng: this venv uses $$(brew --prefix)/lib/libespeak-ng.dylib"; \
	fi

# First render downloads the model (~690 MB) and loads it (~8 s); then sub-second.
kokoro-run:
	$(KOKORO_VENV)/bin/python -m mlx_audio.server --host 127.0.0.1 --port 8000

# Build the macOS app (ad-hoc signed unless a "VoiceSay Self-Sign" identity exists).
# The icon is drawn by build-icon.py, which needs Pillow: installed into the
# daemon venv (from make setup) rather than the system Python.
app:
	daemon/.venv/bin/pip install -q pillow
	ICON_PYTHON="$(CURDIR)/daemon/.venv/bin/python" bash clients/macos/build-app.sh

# Start the HTTP daemon.  Port comes from config or VOICE_SAY_PORT env var.
run:
	daemon/.venv/bin/python -m voice_say.http_server

# Preflight — report which optional deps are present or missing.
doctor:
	bash scripts/doctor.sh

# Symlink the voice-say / voice-ctl CLI into ~/.local/bin (also run by `make setup`).
install-cli:
	bash cli/install.sh

# Run tests.
test:
	cd daemon && .venv/bin/python -m pytest -q

# Run the publishability gate script.
publishable-check:
	bash scripts/publishable-check.sh
