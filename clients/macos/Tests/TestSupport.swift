// TestSupport — shared fixtures/helpers previously hand-rolled per test file:
// the daemon-shaped VoiceEntry JSON fixture (3 copies) and the unique
// UserDefaults-suite helper (4 copies).

import Foundation
@testable import VoiceSay

enum TestSupport {
    /// A fresh, empty, uniquely-named defaults suite per test — isolated so
    /// tests never bleed into the app's real defaults. Named by a path under
    /// the per-user temp folder, so its plist lands there (cleaned by macOS),
    /// not in ~/Library/Preferences: a plain suite name leaves one plist per
    /// test there, and removing the domain still leaves the file.
    static func freshDefaults(_ label: String = "tests") -> UserDefaults {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voicesay-tests")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let suite = dir.appendingPathComponent("\(label).\(ProcessInfo.processInfo.globallyUniqueString)").path
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// A unique socket path under the per-user temp folder, so a test player
    /// never touches the running app's control socket.
    static func socketPath() -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("vs-test-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock")
    }

    /// Decode a minimal daemon-shaped VoiceEntry — the SAME decode path
    /// production uses (no memberwise shortcut), so Codable defaults stay
    /// covered. Pass `progress` to attach a progress payload.
    static func entry(ts: String = "t",
                      text: String = "hello world",
                      durationS: Double = 10,
                      progress: [String: Any]? = nil) throws -> VoiceEntry {
        var payload: [String: Any] = ["ts": ts, "backend": "qwen3",
                                      "duration_s": durationS, "text": text]
        if let progress { payload["progress"] = progress }
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(VoiceEntry.self, from: data)
    }
}
