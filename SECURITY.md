# Security Note

Report a vulnerability privately through GitHub: this repository's **Security** tab → **Report a
vulnerability**. Please don't open a public issue for it. This note records the trust model so the
security posture stays intact as the code changes.

## Threat model (summary)

voice-say runs **locally** — loopback-only (`127.0.0.1:8890`), no authentication, no telemetry, no
cloud calls. State is a permanent audio archive plus a single SQLite store (`voice.db`, WAL). The
full trust model and hardening posture live in
[`docs/internals/security.md`](docs/internals/security.md).

The boundaries that matter most are: a path-traversal escape from the archive root, a way for a web
origin to reach the daemon without explicit CORS opt-in, or any code path that sends data off the
machine. Treat a regression in any of these as a bug to fix immediately.

## Hardening checklist

- [ ] Daemon bound to `127.0.0.1` (default) or behind an auth proxy
- [ ] `VOICE_SAY_CORS` left unset (default) or pinned to specific origins
- [ ] `data_root` on encrypted disk if transcripts contain secrets
- [ ] Periodic backups of `voice.db` (the canonical record)
- [ ] Retention job scheduled so disk usage doesn't grow unbounded
