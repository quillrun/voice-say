// TagColorStore — app-side per-tag color overrides.
//
// Tokens.tagColor() assigns every tag a stable auto-hue via a djb2 hash.
// TagColorStore holds USER-CHOSEN overrides only — when a tag has an entry
// here its color is used everywhere chips appear (TagChip, tagRow, etc.)
// instead of the hash-slot. Keyed by canonical tag string (TagText.sanitized
// form); persisted to UserDefaults.
//
// Color is stored as a 6-digit "rrggbb" hex string chosen from the system color
// picker — a FREE color, not a fixed palette.

import SwiftUI
import Observation

@MainActor
@Observable
final class TagColorStore {
    // MARK: - Storage

    private static let defaultsName = "voicesay.tagColors.v2"   // tag → "rrggbb"
    private let defaults: UserDefaults

    /// tag → "rrggbb" hex. Absent = no override (use the auto hash).
    private var overrides: [String: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        overrides = CodableDefaults.load([String: String].self, key: Self.defaultsName, from: defaults) ?? [:]
    }

    private func persist() {
        CodableDefaults.save(overrides, key: Self.defaultsName, to: defaults)
    }

    // MARK: - API

    /// Resolved color for `tag`: the chosen override hex if set, else the auto
    /// hash from Tokens.tagColor. Always returns a color — never nil.
    func color(for tag: String) -> Color {
        if let hex = overrides[tag] { return Color(hex: hex, fallback: Tokens.tagColor(tag)) }
        return Tokens.tagColor(tag)
    }

    /// The stored override hex ("rrggbb") for `tag`, or nil if auto.
    func customHex(for tag: String) -> String? { overrides[tag] }


    /// Set a custom color for `tag` from a "rrggbb"/"#rrggbb" string. A
    /// malformed value is rejected (no override change). Persisted.
    func setColor(for tag: String, hex: String) {
        guard let norm = Self.normalizedHex(hex) else { return }
        overrides[tag] = norm
        persist()
    }

    /// Clear the custom color (revert to the auto hash). Persisted. No-op (no
    /// write) when the tag had no override.
    func clearColor(for tag: String) {
        guard overrides.removeValue(forKey: tag) != nil else { return }
        persist()
    }

    /// Validate + canonicalize a color string to a lowercase 6-digit hex
    /// ("#rrggbb" or "rrggbb" → "rrggbb"); nil if malformed.
    static func normalizedHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, UInt32(s, radix: 16) != nil else { return nil }
        return s
    }
}
