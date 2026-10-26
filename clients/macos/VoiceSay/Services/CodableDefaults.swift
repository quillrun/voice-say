// CodableDefaults — THE JSON⇄UserDefaults recipe. CategoryStore,
// TagColorStore, and DeclaredTagsStore each hand-rolled the identical
// data(forKey:) → JSONDecoder / JSONEncoder → set(_:forKey:) pair; this is
// that pair, once. Failures stay silent-by-value (nil / no-op) — same
// behavior the stores always had: a corrupt blob degrades to defaults
// instead of crashing, and the next persist overwrites it.

import Foundation

enum CodableDefaults {
    static func load<T: Decodable>(_ type: T.Type, key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String, to defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}

/// Single home for UserDefaults keys that are touched from more than one
/// place or carry an external contract. Store-private versioned keys
/// (`voicesay.<domain>.vN`) stay next to their store.
enum DefaultsKeys {
    /// Legacy-named (pre-namespacing) — renaming would orphan users' saved
    /// values for zero functional gain, so these keep their original names.
    static let playbackRate = "playbackRate"
    static let liveReadFollow = "transcriptLiveReadFollow"
    /// External contract with the voice-say CLI (base-URL override for
    /// the daemon) — shared across tools, never rename.
    static let baseURLOverride = "say.mcp.base.url"
}
