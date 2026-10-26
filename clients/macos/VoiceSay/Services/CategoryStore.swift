// CategoryStore — named collections layered over the existing tag facet.
//
// A *category* is a human-named bucket of renders. There are three kinds:
//   • "History" — the special all-items view (tag == nil AND kind == nil).
//     Always present, first in the list, the default selection, not removable.
//   • "Says" — a KIND-backed category (kind == "say"). An entry is "in" it
//     when `entry.kind == "say"` (short utterances ≤ the daemon's say
//     threshold). Built-in, second in the list, not removable. No backing tag.
//   • a tag-backed category — `tag` is a normalized tag (e.g. "series-a").
//     An entry is "in" the category when its tags contain that tag, so
//     membership reuses the daemon-persisted overlay tags (POST /overlays);
//     "add card to category" just adds the tag. No new daemon storage for
//     membership — only the category *registry* (names + order) lives here,
//     persisted to UserDefaults, since that's a pure app-presentation concern.
//
// A fresh install starts with the built-ins only (History · New · Rendering ·
// Says); tag-backed categories are the user's own.

import Foundation
import Observation

struct Category: Identifiable, Codable, Hashable, Sendable {
    let id: String        // "history" for the all-view; "says" for the kind-view; otherwise == tag
    var name: String      // display name
    var tag: String?      // backing tag (tag-backed categories); nil otherwise
    var kind: String?     // backing entry.kind (kind-backed categories, e.g. "say"); nil otherwise

    /// Only the all-items view (History) is the all-view: neither a tag nor a
    /// kind constrains it. Says (kind != nil) and tag-backed categories are not.
    var isAll: Bool { tag == nil && kind == nil }
}

@MainActor
@Observable
final class CategoryStore {
    private(set) var categories: [Category] = []

    static let defaultsName = "voicesay.categories.v2"
    private let defaults: UserDefaults

    /// The special all-items category. Stable id so selection survives
    /// relaunch and it can never collide with a tag/kind-backed category.
    static let history = Category(id: "history", name: "History", tag: nil, kind: nil)

    /// Built-in kind-backed category for short "say" utterances.
    static let says = Category(id: "says", name: "Says", tag: nil, kind: "say")

    /// Sentinel `kind` for the live "Rendering" category. No stored entry
    /// carries this kind, so the kind-filter yields an empty list; the
    /// in-progress render surfaces via the provisional streaming card, and
    /// HistoryStore.count(for:) reports the active-episode count instead.
    static let renderingKind = "__rendering__"

    /// Built-in "live" category: renders currently in progress. Routed
    /// through kindFilter via the sentinel so Sidebar selection needs no
    /// special-casing. Membership = the active streaming episode.
    static let rendering = Category(id: "rendering", name: "Rendering",
                                    tag: nil, kind: renderingKind)

    /// Sentinel `kind` for the "New" inbox category: completed-but-unopened
    /// renders. No stored entry carries this kind — HistoryStore filters by its
    /// persisted `newIDs` set when kindFilter == newKind, and count(for:)
    /// reports the unopened count. A sentinel (not isAll) so it never aliases
    /// History (tag == nil && kind == nil).
    static let newKind = "__new__"

    /// Built-in "New" inbox: renders that finished but haven't been opened yet.
    static let new = Category(id: "new", name: "New", tag: nil, kind: newKind)

    /// Built-in tag-backed category for save-and-stop partials. The daemon
    /// tags a finalized-early render "draft"; this bucket collects them.
    static let drafts = Category(id: "draft", name: "Drafts",
                                 tag: "draft", kind: nil)

    /// The built-ins in canonical leading order (History · New · Rendering · Says).
    /// Drafts was retired — paused drafts now live INSIDE the Rendering bucket.
    static let builtins: [Category] = [history, new, rendering, says]

    /// Retired built-ins, stripped from any persisted store on load (their data
    /// concept moved — drafts fold into Rendering). Keeps `draft` reserved too.
    static let retired: [Category] = [drafts]

    /// Every token by which a persisted/user category can be recognized as
    /// colliding with a built-in: each built-in's id, its backing tag (if any),
    /// and the normalized form of its display name. Used to strip a persisted
    /// category that aliases a built-in (the retired Drafts included), and to
    /// reject a user re-creating a built-in by name.
    static let builtinReservedTokens: Set<String> = {
        var tokens: Set<String> = []
        // Include `retired` so a stale persisted Drafts category is recognized
        // as a built-in alias and stripped by load()'s collidesWithBuiltin pass
        // (and `draft` stays reserved against re-creation).
        for b in builtins + retired {
            tokens.insert(b.id)
            if let t = b.tag { tokens.insert(t) }
            tokens.insert(normalizedTag(b.name))
        }
        return tokens
    }()

    /// True if `category` is (or aliases) a built-in: matches by id, backing
    /// tag, or normalized display name against any built-in's reserved tokens.
    private static func collidesWithBuiltin(_ category: Category) -> Bool {
        if builtinReservedTokens.contains(category.id) { return true }
        if let t = category.tag, builtinReservedTokens.contains(t) { return true }
        return builtinReservedTokens.contains(normalizedTag(category.name))
    }

    /// `defaults` is injectable so tests can pass a throwaway suite; the app
    /// always uses `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }


    private func load() {
        if let decoded = CodableDefaults.load([Category].self, key: Self.defaultsName, from: defaults),
           !decoded.isEmpty {
            categories = decoded
        } else {
            categories = []
        }
        // Guarantee the built-ins exist and lead the list in canonical order
        // (History · New · Rendering · Says) — defends against a
        // hand-edited store or one persisted before these were added. Strip
        // then re-insert so an old store gains the new built-ins without
        // dropping the user's own tag-backed categories.
        //
        // Strip not just exact-id matches but anything that *aliases* a
        // built-in by id, backing tag, or normalized name, so a persisted
        // "drafts"/"Drafts" category (from before Drafts was retired) goes
        // instead of showing beside the Rendering bucket that replaced it.
        categories.removeAll { Self.collidesWithBuiltin($0) }
        categories.insert(contentsOf: Self.builtins, at: 0)
        persist()
    }

    private func persist() {
        CodableDefaults.save(categories, key: Self.defaultsName, to: defaults)
    }


    /// Normalize a display name to the canonical backing-tag form via the
    /// shared sanitizer (so a category's tag dedupes the same way tags do).
    static func normalizedTag(_ name: String) -> String { TagText.sanitized(name) }

    /// Create a category from a display name. Returns the existing one if a
    /// category with the same backing tag is already present (idempotent),
    /// or nil if the name is empty. A name that normalizes to a reserved
    /// token is never appended as a new row: a LIVE built-in token resolves
    /// to that built-in, while a RETIRED token (e.g. "draft", which has no
    /// live built-in) returns nil so it can't be resurrected as a tag row.
    @discardableResult
    func addCategory(name: String) -> Category? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tag = Self.normalizedTag(trimmed)
        guard !tag.isEmpty else { return nil }
        // Reserved-token collision: never append. A reserved token is either a
        // live built-in's id/tag/normalized-name OR a retired token (e.g.
        // "draft"). Hand back the matching LIVE built-in, or nil to REJECT a
        // retired token that has no live built-in — otherwise the optional bind
        // would fail and fall through to spawn a phantom "draft" row.
        if Self.builtinReservedTokens.contains(tag) {
            return Self.builtins.first(where: {
                $0.id == tag || $0.tag == tag || Self.normalizedTag($0.name) == tag
            })
        }
        if let existing = categories.first(where: { $0.tag == tag }) { return existing }
        let cat = Category(id: tag, name: trimmed, tag: tag, kind: nil)
        categories.append(cat)
        persist()
        return cat
    }

    /// Remove a category from the registry. The built-ins (History, New,
    /// Rendering, Says) are never removable. Note: this only forgets the named
    /// bucket — the underlying tag stays on any entries that carry it (use the
    /// row's tag editor to untag).
    func removeCategory(_ id: String) {
        // The built-ins (History, New, Rendering, Says) are not removable.
        guard !Self.builtins.contains(where: { $0.id == id }) else { return }
        categories.removeAll { $0.id == id }
        persist()
    }

    /// Rename a category's DISPLAY NAME (id and backing tag stay unchanged —
    /// rename is free, no entry touches needed). Rejects:
    ///   • empty / whitespace-only names
    ///   • names that normalize to a reserved/built-in token (would alias a
    ///     built-in or a retired token)
    ///   • attempts to rename a built-in (their display names are app-strings)
    /// Returns true on success, false on any rejection.
    @discardableResult
    func renameCategory(id: String, newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Protect built-ins — their names are owned by the app.
        guard !Self.builtins.contains(where: { $0.id == id }) else { return false }
        // Reject a name that normalizes to any reserved/built-in token.
        let normalized = Self.normalizedTag(trimmed)
        guard !normalized.isEmpty else { return false }
        guard !Self.builtinReservedTokens.contains(normalized) else { return false }
        // Apply.
        guard let idx = categories.firstIndex(where: { $0.id == id }) else { return false }
        categories[idx].name = trimmed
        persist()
        return true
    }
}
