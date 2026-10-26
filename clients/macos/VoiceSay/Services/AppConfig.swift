// AppConfig — single in-process holder for tunables the daemon owns.
// Fetched from `GET /config` on first HistoryStore load. Until /config
// returns, lists are empty and `loadedFromDaemon == false` — the UI
// reads through this and renders neutral empty states (no chips, no
// backends) rather than risk routing to a stale hardcoded port.
//
// SAY_THRESHOLD_CHARS comes through the same channel — only the
// daemon ever sets it; the VoiceSay side stores 280 as a cold-start
// fallback that's never authoritative. Renders ≤ this many chars are
// classified by the daemon as kind == "say".
//
// Thread-safety: `@Observable` simple-value reads are safe from any
// thread (VoiceEntry derivation runs during Codable on background
// threads). Writes go through `refresh()` which is `@MainActor`-
// isolated so SwiftUI observation is well-formed.

import Foundation
import Observation

@Observable
final class AppConfig: @unchecked Sendable {
    static let shared = AppConfig()

    private(set) var sayThresholdChars: Int = 280
    private(set) var backends: [Backend] = []
    private(set) var loadedFromDaemon: Bool = false
    // Daemon-owned defaults (GET /config). The picker in Settings writes
    // these via POST /config; nil until /config returns. defaultVoice nil =
    // the backend picks its own.
    private(set) var defaultBackend: String?
    private(set) var defaultVoice: String?
    // Absolute filesystem roots reported by the daemon (it's the same host).
    // nil until /config returns; AppPaths falls back to a neutral local dir.
    private(set) var archiveRoot: String?

    private init() {}

    /// Best-effort fetch. If the daemon is down, fields stay at their
    /// cold-start values and `loadedFromDaemon` stays false.
    @MainActor
    func refresh() async {
        guard let cfg = try? await DaemonClient.shared.config() else { return }
        apply(cfg)
    }

    /// Push new defaults to the daemon (POST /config) then adopt the
    /// authoritative response. Pass "" for voice to clear it. Throws on a
    /// daemon error so the caller can surface it; on success the published
    /// fields reflect what the daemon actually persisted (which may differ
    /// from the request if an env var shadows it — see `warnings`).
    @MainActor
    @discardableResult
    func setDefaults(backend: String? = nil, voice: String? = nil) async throws -> [String] {
        let cfg = try await DaemonClient.shared.setConfig(defaultBackend: backend,
                                                          defaultVoice: voice)
        apply(cfg)
        return cfg.warnings ?? []
    }

    /// Push a new say-threshold to the daemon (POST /config) and adopt the
    /// authoritative response. Carries only `say_threshold_chars`; other keys
    /// stay nil → omitted → untouched. Returns any daemon warnings (e.g. an
    /// env var shadowing the written value).
    @MainActor
    @discardableResult
    func setSayThreshold(_ chars: Int) async throws -> [String] {
        let cfg = try await DaemonClient.shared.setConfig(sayThresholdChars: max(0, chars))
        apply(cfg)
        return cfg.warnings ?? []
    }

    @MainActor
    private func apply(_ cfg: ConfigResponse) {
        if let t = cfg.sayThresholdChars { sayThresholdChars = t }
        if let b = cfg.backends, !b.isEmpty { backends = b }
        if let a = cfg.archiveRoot, !a.isEmpty { archiveRoot = a }
        defaultBackend = cfg.defaultBackend
        defaultVoice = cfg.defaultVoice
        loadedFromDaemon = true
    }

    /// Typed lookup by id. Returns nil for unknown — callers driving a
    /// render must handle nil so a stale persisted id never silently
    /// routes to a different backend.
    func backend(id: String) -> Backend? {
        backends.first { $0.id == id }
    }
}
