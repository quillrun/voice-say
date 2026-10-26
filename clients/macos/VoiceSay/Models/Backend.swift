// Backend descriptors. The authoritative list lives in the daemon
// (engine.BACKENDS) and is exposed via GET /config. VoiceSay pulls it on
// startup via AppConfig.refresh(). The view layer reads through
// `AppConfig.shared.backends`; for a typed lookup use
// `AppConfig.shared.backend(id:)`.

import Foundation

struct Backend: Identifiable, Hashable, Sendable, Decodable {
    let id: String
    let label: String
    let port: Int
    let defaultVoice: String
    let voices: [String]
    let supportsSpeed: Bool
    let accent: String
    /// How this backend's OS service is started/stopped. nil = not
    /// client-managed (the user brings it up themselves).
    let service: BackendService?

    // Daemon emits snake_case (default_voice, supports_speed); map here
    // so the rest of the codebase uses Swift naming.
    enum CodingKeys: String, CodingKey {
        case id, label, port, voices, accent, service
        case defaultVoice = "default_voice"
        case supportsSpeed = "supports_speed"
    }

    /// `label` with a trailing " (local)" stripped, so backend chips / picker
    /// triggers / queue rows stay compact. Single source for the strip (was
    /// duplicated inline in BackendSelector, VoicePickerSheet, RenderQueueView).
    var compactLabel: String {
        label.replacingOccurrences(of: " (local)", with: "")
    }
}

/// Service-management descriptor reported by the daemon per backend. The app
/// reads `kind` to decide how to drive on/off: launchd backends go through
/// `launchctl bootstrap/bootout gui/$UID/<label>`; docker backends through
/// `docker compose start/stop <composeService>`.
struct BackendService: Hashable, Sendable, Decodable {
    let kind: String                  // "launchd" | "docker" | "none"
    let label: String?                // launchd label (→ ~/Library/LaunchAgents/<label>.plist)
    let composeService: String?       // docker compose service name
    let container: String?            // docker container name (fallback control)

    enum CodingKeys: String, CodingKey {
        case kind, label, container
        case composeService = "compose_service"
    }

    /// `~/Library/LaunchAgents/<label>.plist` — only meaningful for launchd.
    var plistPath: String? {
        guard let label else { return nil }
        return NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }
}

/// Convenience facade for backend lookups. Kept thin so call sites read
/// like `Backends.find(id: …)` rather than spelling out the
/// `AppConfig.shared` traversal each time.
enum Backends {
    static var all: [Backend] { AppConfig.shared.backends }
    static func find(id: String) -> Backend? { AppConfig.shared.backend(id: id) }
}

// Shared filesystem constants — kept here so every Service references one
// source instead of hard-coding paths.
enum AppPaths {
    /// Audio archive root. Reported by the daemon (`GET /config` →
    /// archive_root); same host, so the absolute path resolves locally.
    /// Falls back to a neutral local dir before /config returns.
    static var voiceArchive: URL {
        if let a = AppConfig.shared.archiveRoot, !a.isEmpty {
            return URL(fileURLWithPath: (a as NSString).expandingTildeInPath)
        }
        return home(".local/share/voice-say/voice-archive")
    }

    private static func home(_ rel: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(rel)
    }
}
