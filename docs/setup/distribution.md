# Build & local deploy

**voice-say runs from this repository, in place.** There is no prebuilt binary and
**no Apple Developer ID is required** — you build and run on the same machine:

```sh
make setup && make run        # daemon on PATH and healthy (start a backend separately)
# optional: build the macOS app from source
make app && open clients/macos/build/VoiceSay.app
```

The app is only one surface over the system: the box also needs the Python daemon and
a running TTS backend (a separate service — see [backends.md](./backends.md)). `make setup`
provisions the daemon side; a lone `.app` would be inert (see [install.md](./install.md)).

## The macOS app: built locally, runs with no Apple account

`make app` (which runs `clients/macos/build-app.sh`) compiles the app and signs it with a **self-signed**
identity (`VoiceSay Self-Sign`, ad-hoc fallback). That signature exists only to keep
the code-signing identity — and therefore the macOS TCC permission grants — stable
across rebuilds on this machine. Because the app is **built locally** (not downloaded),
it never gets the `com.apple.quarantine` attribute, so Gatekeeper lets it run
**without notarization and without an Apple ID**:

```sh
codesign -dvv clients/macos/build/VoiceSay.app    # adhoc / self-signed, TeamIdentifier not set — expected
open clients/macos/build/VoiceSay.app             # runs (locally built → no quarantine)
```

## If you ever copy the `.app` to another Mac

Not part of the normal in-place flow — noted only for completeness. If you copy a
compiled `.app` to a Mac that did **not** build it (AirDrop, zip, scp), macOS attaches
`com.apple.quarantine` and Gatekeeper rejects ad-hoc/self-signed code
(*"VoiceSay is damaged"* / *"unidentified developer"*). The simplest fix on the
destination Mac is to strip the quarantine attribute (or right-click → Open):

```sh
xattr -dr com.apple.quarantine /path/to/VoiceSay.app
```

The robust alternative is an Apple **Developer ID** identity + notarization, but that
is unnecessary for in-place use on the machine that built the app.
