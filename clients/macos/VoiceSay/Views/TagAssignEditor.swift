// TagAssignEditor — per-entry "Tags & Category" assign window.
//
// Opens with the entry's CURRENT assignments as baseline A; Save is DISABLED
// until the in-memory state differs from A (set equality). Any diff enables
// Save; reverting every change disables it again. Save applies all changes
// atomically via store.setEffectiveTags (tag adds/removes + category-backing
// tag changes in one write), then the saved state becomes the new baseline
// (window stays open, Save disabled again).
//
// Two sections:
//   CATEGORY — single-select (max ONE category per entry; selecting one
//     deselects the other; none is valid). Category-backing tags are shown
//     here and are EXCLUDED from the TAGS section below.
//   TAGS — multi-select checkboxes, searchable type-ahead filter. The list
//     is built lazily so ~300 tags stay fast.
//
// The diff/enable state machine lives in `TagAssignCore.saveEnabled(baseline:current:)`
// — a nonisolated static pure function with no SwiftUI/store dependencies, so
// it is covered by Swift Testing without a running UI.

import SwiftUI

// MARK: - Pure core (nonisolated static — tested without UI)

enum TagAssignCore {
    /// Whether Save should be enabled: the current state differs from baseline.
    ///
    /// - Parameters:
    ///   - baseline: tag set at the moment the window opened (or last Save).
    ///   - current: the staged tag set (includes both regular tags AND the
    ///     chosen category's backing tag when a category is selected).
    /// - Returns: true iff the sets are not equal.
    nonisolated static func saveEnabled(baseline: Set<String>, current: Set<String>) -> Bool {
        baseline != current
    }

    /// Enforce the single-category rule when the user picks a category:
    /// remove all OTHER category-backing tags from `staged`, then insert the
    /// new one. Returns the updated set.
    ///
    /// - Parameters:
    ///   - staged: current staged set.
    ///   - chosen: backing tag of the newly selected category.
    ///   - allCategoryTags: all category backing tags in the registry (used to
    ///     strip any existing category tags before inserting the new one).
    nonisolated static func applySingleCategory(staged: Set<String>,
                                                chosen: String,
                                                allCategoryTags: Set<String>) -> Set<String> {
        var s = staged.subtracting(allCategoryTags)
        s.insert(chosen)
        return s
    }

    /// Deselect a category (set none): strip its backing tag from staged.
    nonisolated static func clearCategory(staged: Set<String>,
                                          tag: String) -> Set<String> {
        staged.subtracting([tag])
    }

    /// The set of pure tags (not category-backing) to show in the TAGS section:
    /// all tags in the universe minus every category-backing tag.
    nonisolated static func tagListExcludingCategories(universe: [String],
                                                       declared: [String],
                                                       categoryTags: Set<String>) -> [String] {
        let all = Set(universe + declared).subtracting(categoryTags)
        return all.sorted()
    }

    /// Whether the typed (already-normalized) query is a brand-new tag the
    /// user can create from this window: non-empty, not already a tag (in use
    /// or declared), and not a category's backing tag. Mirrors TaxonomyEditor's
    /// create-eligibility so the per-render assign window is symmetric with the
    /// compose/manage surfaces. Tag creation is a USER affordance — the
    /// closed-vocabulary restriction is the MCP `set_overlays` path's concern,
    /// not the app's.
    nonisolated static func canCreateTag(normalizedQuery: String,
                                         universe: [String],
                                         declared: [String],
                                         categoryTags: Set<String>) -> Bool {
        guard !normalizedQuery.isEmpty else { return false }
        if categoryTags.contains(normalizedQuery) { return false }
        return !Set(universe + declared).contains(normalizedQuery)
    }

    /// Whether the typed (already-normalized) query is a brand-new CATEGORY the
    /// user can create from this window: non-empty, not colliding with an
    /// existing category (by id / backing tag / normalized name — all folded
    /// into `categoryTokens`), and not colliding with an existing tag. Mirrors
    /// TaxonomyEditor's `canCreateCat`.
    nonisolated static func canCreateCategory(normalizedQuery: String,
                                              existingTags: Set<String>,
                                              categoryTokens: Set<String>) -> Bool {
        guard !normalizedQuery.isEmpty else { return false }
        if categoryTokens.contains(normalizedQuery) { return false }
        return !existingTags.contains(normalizedQuery)
    }
}

// MARK: - View

struct TagAssignEditor: View {
    @Environment(HistoryStore.self) var store
    @Environment(CategoryStore.self) var categories
    @Environment(DeclaredTagsStore.self) var declaredTags
    @Environment(TagColorStore.self) var tagColors
    @Environment(UIRouter.self) var router

    let entryID: String?
    var onClose: (() -> Void)? = nil

    @State private var search: String = ""
    // Full staged tag set (regular tags + the active category's backing tag).
    @State private var staged: Set<String> = []
    @State private var baseline: Set<String> = []
    @State private var baselineKey: String? = nil

    private var entry: VoiceEntry? {
        entryID.flatMap { id in store.entries.first { $0.id == id } }
    }

    /// All category-backing tags (used to split CATEGORY vs TAGS sections and
    /// to enforce single-category collapse).
    private var allCategoryTags: Set<String> {
        Set(categories.categories.compactMap { $0.tag })
    }

    /// User-created tag-backed categories only (excludes built-in views).
    private var userCategories: [Category] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return categories.categories.filter { $0.tag != nil }.filter {
            q.isEmpty
                || $0.name.lowercased().contains(q)
                || ($0.tag ?? "").contains(q)
        }
    }

    /// The currently selected category (the one whose backing tag is in staged).
    private var activeCategory: Category? {
        userCategories.first { cat in
            guard let t = cat.tag else { return false }
            return staged.contains(t)
        }
    }

    /// Searchable, category-excluded tag list.
    private var tagList: [String] {
        let universe = store.tagUniverse.map { $0.0 }
        let all = TagAssignCore.tagListExcludingCategories(
            universe: universe,
            declared: declaredTags.declared,
            categoryTags: allCategoryTags
        )
        // Filter on the SAME normalized form used for create-eligibility, so a
        // query like "my tag" matches the stored "my-tag" (and correctly
        // suppresses the create-row) instead of falling through to "no matches".
        let q = normalizedQuery
        let filtered = q.isEmpty ? all : all.filter { $0.contains(q) }
        // On-episode (staged) tags first, then the rest — each group stays
        // alphabetical (`all` arrives sorted). Makes the entry's current tags
        // easy to find and unset.
        return filtered.filter { staged.contains($0) } + filtered.filter { !staged.contains($0) }
    }

    private var canSave: Bool {
        TagAssignCore.saveEnabled(baseline: baseline, current: staged)
    }

    /// Normalized form of the search box — the candidate new tag name.
    private var normalizedQuery: String { TagText.sanitized(search) }

    /// Whether the typed search names a brand-new tag the user can create.
    private var canCreateTag: Bool {
        TagAssignCore.canCreateTag(
            normalizedQuery: normalizedQuery,
            universe: store.tagUniverse.map { $0.0 },
            declared: declaredTags.declared,
            categoryTags: allCategoryTags
        )
    }

    /// Every token by which the typed name could collide with an existing
    /// category: its id, backing tag, and normalized display name — plus the
    /// reserved/retired built-in tokens (e.g. "draft"), which CategoryStore
    /// refuses to create. Including them keeps the "Create category" row from
    /// offering a name that addCategory would silently reject.
    private var categoryTokens: Set<String> {
        let live = Set(categories.categories.flatMap { cat -> [String] in
            var t = [cat.id, TagText.sanitized(cat.name)]
            if let tag = cat.tag { t.append(tag) }
            return t
        })
        return live.union(CategoryStore.builtinReservedTokens)
    }

    /// Whether the typed search names a brand-new category the user can create.
    private var canCreateCategory: Bool {
        TagAssignCore.canCreateCategory(
            normalizedQuery: normalizedQuery,
            existingTags: Set(store.tagUniverse.map { $0.0 } + declaredTags.declared),
            categoryTokens: categoryTokens
        )
    }

    /// Key for the baseline snapshot — changes when the target entry resolves.
    private var snapshotKey: String { "assign:\(entry?.id ?? "unresolved")" }

    var body: some View {
        TaxonomyDialog(icon: "tag", title: "Tags & Category",
                       subtitle: entry?.derivedTitle() ?? "",
                       search: $search, searchPrompt: "filter tags, or type a new one to create…",
                       showsCard: entry != nil, onClose: close) {
            categorySection
            Divider().background(Tokens.border).padding(.vertical, Spacing.xs)
            tagsSection
        } footer: {
            footer
        }
        .task(id: snapshotKey) {
            guard let e = entry else { return }
            let base = Set(store.tagsFor(e))
            baseline = base
            staged = baselineKey == nil ? staged.union(base) : base
            baselineKey = snapshotKey
        }
    }

    // MARK: - Category section

    @ViewBuilder
    private var categorySection: some View {
        TaxonomySectionLabel(label: "CATEGORY", count: userCategories.count + (canCreateCategory ? 1 : 0),
                             hint: "max one")
        // Type a name that isn't an existing tag or category → offer to create
        // it as a category (and select it — single-category rule applies).
        if canCreateCategory {
            TaxonomyCreateRow(label: "Create category “\(search.trimmingCharacters(in: .whitespaces))”",
                              icon: "folder.badge.plus", tone: Tokens.add) {
                createCategory()
            }
        }
        if userCategories.isEmpty && !canCreateCategory {
            TaxonomyEmptyHint("no categories — type a name to create one")
        } else {
            ForEach(userCategories) { cat in
                let isSelected = staged.contains(cat.tag ?? "")
                TaxonomyCategoryRow(category: cat, selected: isSelected) {
                    selectCategory(cat, currently: isSelected)
                }
            }
        }
    }

    private func selectCategory(_ cat: Category, currently isSelected: Bool) {
        guard let tag = cat.tag else { return }
        if isSelected {
            // Deselect — allow none
            staged = TagAssignCore.clearCategory(staged: staged, tag: tag)
        } else {
            // Single-select: collapse to this one category
            staged = TagAssignCore.applySingleCategory(
                staged: staged,
                chosen: tag,
                allCategoryTags: allCategoryTags
            )
        }
    }

    /// Create a category from the typed name (immediate, via CategoryStore) and
    /// select it under the single-category rule. `addCategory` appends
    /// synchronously on the main actor, so `allCategoryTags` already includes the
    /// new backing tag by the time the collapse runs.
    private func createCategory() {
        let name = search.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let cat = categories.addCategory(name: name), let tag = cat.tag {
            staged = TagAssignCore.applySingleCategory(
                staged: staged,
                chosen: tag,
                allCategoryTags: allCategoryTags
            )
        }
        search = ""
    }

    // MARK: - Tags section

    @ViewBuilder
    private var tagsSection: some View {
        TaxonomySectionLabel(label: "TAGS", count: tagList.count + (canCreateTag ? 1 : 0))
        // Type a name not already in the vocabulary → offer to create it. This
        // is what makes the assign window a tag-creation surface.
        if canCreateTag {
            TaxonomyCreateRow(label: "Create #\(normalizedQuery)", icon: "plus", tone: Tokens.accent) {
                createTag(normalizedQuery)
            }
        }
        if tagList.isEmpty && !canCreateTag {
            TaxonomyEmptyHint(search.isEmpty ? "no tags" : "no matches")
        } else {
            ForEach(tagList, id: \.self) { tag in
                TaxonomyTagRow(tag: tag, color: tagColors.color(for: tag), selected: staged.contains(tag)) {
                    toggleTag(tag)
                }
            }
        }
    }

    private func toggleTag(_ tag: String) {
        if staged.contains(tag) { staged.remove(tag) }
        else { staged.insert(tag) }
    }

    /// Declare a brand-new tag (already normalized by the caller) and stage it
    /// onto the entry. Declaring keeps the name visible (DeclaredTagsStore) even
    /// before any entry uses it; staging applies it on Save. Save enables
    /// because `staged` now differs from baseline. Taking the normalized value
    /// as a parameter keeps the displayed "Create #x" label and the stored tag
    /// guaranteed identical.
    private func createTag(_ tag: String) {
        guard !tag.isEmpty else { return }
        _ = declaredTags.add(tag)
        staged.insert(tag)
        search = ""
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            let catName = activeCategory?.name ?? "none"
            Text("category: \(catName)  ·  \(staged.subtracting(allCategoryTags).count) tag\(staged.subtracting(allCategoryTags).count == 1 ? "" : "s")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.ultraDim)
            Spacer()
            Button(action: { save() }) {
                Text("Save")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                    .background(canSave ? Tokens.accent : Tokens.accent.opacity(0.3))
                    .foregroundStyle(Tokens.bg)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            }
            .buttonStyle(.plain)
            .disabled(!canSave)
            .help(canSave ? "Apply changes" : "No changes to save")
            .animation(Motion.quick, value: canSave)
        }
    }

    // MARK: - Actions

    private func save() {
        guard let e = entry, canSave else { return }
        store.setEffectiveTags(e, desired: staged)
        // New baseline = just-saved state; Save button goes disabled again.
        baseline = staged
    }

    private func close() {
        if let onClose { onClose() }
        else { router.closeTagDialog() }
    }
}
