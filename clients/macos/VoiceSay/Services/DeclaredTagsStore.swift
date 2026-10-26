// DeclaredTagsStore — user-declared tags that should appear in the sidebar
// even before any entry uses them, mirroring how empty categories persist.
//
// Tags are otherwise an *open vocabulary* derived from entries (see
// HistoryStore.tagUniverse), so a freshly "added" tag with no entries yet
// would be invisible. This tiny UserDefaults-backed registry keeps the
// "+ add tag" affordance symmetric with "+ add category". Membership of an
// entry in a tag is still the daemon-persisted overlay tag — this only holds
// the *names* the user has declared.

import Foundation
import Observation

@MainActor
@Observable
final class DeclaredTagsStore {
    private(set) var declared: [String] = []

    private let defaultsName = "voicesay.declaredTags.v1"
    private let defaults: UserDefaults

    /// `defaults` is injectable so tests can pass a throwaway suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let decoded = CodableDefaults.load([String].self, key: defaultsName, from: defaults) {
            declared = decoded
        }
    }

    private func persist() {
        CodableDefaults.save(declared, key: defaultsName, to: defaults)
    }

    /// Canonical tag form — shared sanitizer (trim/lower/hyphenate + strip
    /// punctuation + collapse hyphens). One source so dedupe is consistent.
    static func normalized(_ raw: String) -> String { TagText.sanitized(raw) }

    /// Declare a tag. Returns the normalized tag, or nil if empty/dupe-noop.
    @discardableResult
    func add(_ raw: String) -> String? {
        let tag = Self.normalized(raw)
        guard !tag.isEmpty else { return nil }
        if !declared.contains(tag) {
            declared.append(tag)
            persist()
        }
        return tag
    }

    /// Forget a declared tag (does not touch entries — the caller deletes
    /// the tag from entries separately via HistoryStore.deleteTagEverywhere).
    func remove(_ tag: String) {
        guard declared.contains(tag) else { return }
        declared.removeAll { $0 == tag }
        persist()
    }
}
