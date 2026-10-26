#!/usr/bin/env bash
# Build VoiceSay.app from the SPM executable, bundled by hand because Command
# Line Tools don't ship Xcode's app-bundling pipeline.

set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="VoiceSay"
APP_BUNDLE="build/${APP_NAME}.app"

# Builds for this Mac's own architecture (Apple silicon or Intel).
echo "[1/4] swift build (${CONFIG})…"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
    echo "ERROR: built binary not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "[2/4] Assembling .app bundle…"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BIN_PATH}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "VoiceSay/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"

# Version: stamp the bundle from the product's single source of truth
# (daemon/voice_say/__init__.py __version__) so the About box can't drift
# from the daemon.
# CFBundleVersion = commit count: monotonic, no counter file to maintain.
VERSION="$(sed -n 's/^__version__ = "\(.*\)"/\1/p' ../../daemon/voice_say/__init__.py)"
BUILD_NUM="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
if [[ -n "${VERSION}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${APP_BUNDLE}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUM}" "${APP_BUNDLE}/Contents/Info.plist"
    echo "  stamped version ${VERSION} (build ${BUILD_NUM}) from daemon/voice_say/__init__.py"
else
    echo "  warning: could not read __version__ — bundle keeps the template version" >&2
fi

# Icon: VOICE_SAY_ICON=<png> builds a multi-resolution .icns from that image via
# sips + iconutil. Without it (or if the PNG is absent) the procedural
# build-icon.py draws the icon. Each has its own cache file, so a build of one
# never ships the other's cached icon.
ICON_SRC="${VOICE_SAY_ICON:-}"
if [[ -n "${ICON_SRC}" && -f "${ICON_SRC}" ]]; then
    ICON_PATH="build/AppIcon-custom.icns"
    if [[ ! -f "${ICON_PATH}" || "${ICON_SRC}" -nt "${ICON_PATH}" ]]; then
        echo "  building app icon from ${ICON_SRC}…"
        ICONSET="build/AppIcon-custom.iconset"
        rm -rf "${ICONSET}"; mkdir -p "${ICONSET}"
        for sz in 16 32 128 256 512; do
            sips -z "${sz}" "${sz}" "${ICON_SRC}" --out "${ICONSET}/icon_${sz}x${sz}.png" >/dev/null
            sips -z "$(( sz * 2 ))" "$(( sz * 2 ))" "${ICON_SRC}" --out "${ICONSET}/icon_${sz}x${sz}@2x.png" >/dev/null
        done
        iconutil -c icns "${ICONSET}" -o "${ICON_PATH}"
    fi
else
    ICON_PATH="build/AppIcon.icns"
    if [[ ! -f "${ICON_PATH}" || build-icon.py -nt "${ICON_PATH}" ]]; then
        # Regenerate when the cache is missing OR build-icon.py changed since it
        # was baked, so an edited icon source never ships a stale cached icon.
        echo "  rebuilding icon (procedural)…"
        "${ICON_PYTHON:-python3}" build-icon.py >/dev/null   # needs Pillow
    fi
fi
cp "${ICON_PATH}" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

printf 'APPL????' > "${APP_BUNDLE}/Contents/PkgInfo"

# Voice samples: bundle the per-voice preview clips INTO the .app so they
# survive render-archive churn and git-clean. They used to live in the
# gitignored render archive (<archive_root>/_samples) and kept vanishing.
# The clip set is supplied out-of-band via VOICE_SAY_SAMPLES (a directory of
# <voice>.mp3 clips kept outside the repo). No-op if the env is unset.
SAMPLES_SRC="${VOICE_SAY_SAMPLES:-}"
if [[ -n "${SAMPLES_SRC}" && -d "${SAMPLES_SRC}" ]]; then
    SAMPLES_DST="${APP_BUNDLE}/Contents/Resources/samples"
    mkdir -p "${SAMPLES_DST}"
    find "${SAMPLES_SRC}" -maxdepth 1 -name '*.mp3' -exec cp {} "${SAMPLES_DST}/" \;
    echo "  bundled $(find "${SAMPLES_DST}" -name '*.mp3' | wc -l | tr -d ' ') voice samples from ${SAMPLES_SRC}"
else
    echo "  no VOICE_SAY_SAMPLES set — app ships without bundled sample previews"
fi

echo "[3/4] Code signing…"
# Sign with a stable self-signed identity so the code-signing requirement
# stays the same across rebuilds. TCC keys grants on that requirement —
# with ad-hoc signing (--sign -) every rebuild produced a fresh CDHash,
# a fresh requirement, and a fresh "would like to access Desktop" prompt.
# Falls back to ad-hoc if the identity is missing (fresh checkout, etc.).
# Hardened runtime (--options runtime) is on: the app loads no plugins,
# does no JIT, and uses no DYLD_ tricks, so hardening costs nothing and
# puts the security posture on record. App Sandbox stays OFF by decision:
# the app's whole job is localhost daemon HTTP/SSE + a per-user unix socket +
# reading the voice-archive tree — sandboxing would need broad exceptions
# that defeat it. See README "Security posture".
SIGN_IDENTITY="VoiceSay Self-Sign"
if security find-certificate -c "${SIGN_IDENTITY}" >/dev/null 2>&1; then
    codesign --force --deep --options runtime --sign "${SIGN_IDENTITY}" "${APP_BUNDLE}"
else
    echo "  warning: '${SIGN_IDENTITY}' not in keychain — falling back to ad-hoc."
    echo "  to create it: Keychain Access → Certificate Assistant →"
    echo "  Create a Certificate… → name '${SIGN_IDENTITY}', Identity Type"
    echo "  'Self Signed Root', Certificate Type 'Code Signing' → Create."
    codesign --force --deep --options runtime --sign - "${APP_BUNDLE}"
fi
# A failed or partial signature stops the build here instead of shipping.
codesign --verify --deep --strict "${APP_BUNDLE}"

echo "[4/4] Done."
echo "  Bundle: $(pwd)/${APP_BUNDLE}"
echo "  Run:    open '$(pwd)/${APP_BUNDLE}'"

# VOICE_SAY_DESKTOP_LINK=1: place a Desktop symlink to the bundle so the app
# is reachable from the Desktop and Spotlight (which indexes ~/Desktop). The
# bundle still lives in the repo — the symlink just makes it discoverable.
# Re-pointed each build so a moved/renamed bundle never leaves a dead alias.
if [[ "${VOICE_SAY_DESKTOP_LINK:-0}" == "1" ]]; then
    ln -sfh "$(pwd)/${APP_BUNDLE}" "${HOME}/Desktop/${APP_NAME}.app"
fi
# Trigger a Spotlight reindex of the actual bundle path so the app shows
# up in system search.
/usr/bin/mdimport "$(pwd)/${APP_BUNDLE}" 2>/dev/null || true
