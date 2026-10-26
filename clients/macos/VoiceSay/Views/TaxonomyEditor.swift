// TaxonomyEditor — the compose screen's tag + category picker: stages the
// tags a new render will get (search → create rows → CATEGORIES → TAGS →
// Save). It assigns and creates only; deleting a category or a tag from the
// library lives in TaxonomyManager alone.

import SwiftUI

struct TaxonomyEditor: View {
    @Environment(HistoryStore.self) var store
    @Environment(CategoryStore.self) var categories
    @Environment(DeclaredTagsStore.self) var declaredTags
    @Environment(TagColorStore.self) var tagColors
    @Environment(UIRouter.self) var router

    let staging: Binding<Set<String>>
    var onClose: (() -> Void)? = nil

    @State private var search = ""
    // Staged entry membership; `original` is the snapshot on
    // open so Save can commit the diff and the button enables only when changed.
    @State private var staged: Set<String> = []
    @State private var original: Set<String> = []
    /// snapshotKey of the last applied baseline. nil until the first real
    /// snapshot lands — selections made before then (entry still resolving)
    /// are merged under the late baseline instead of being wiped.
    @State private var baselineKey: String? = nil

    private var edited: Bool { staged != original }
    /// Key for the baseline snapshot task, so `original` snapshots once per
    /// open instead of latching on the first appear.
    private let snapshotKey = "staging"

    var body: some View {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let normQ = normalized(search)
        let cats = categories.categories
            .filter { $0.tag != nil }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || ($0.tag ?? "").contains(q) }
        // ONE universe scan per body eval, shared by allTags and the create
        // checks (a whole-history aggregation; per-row scans were the slow open).
        let universe = store.tagUniverse
        let allTags = Array(Set(universe.map { $0.0 } + declaredTags.declared)).sorted()
            .filter { q.isEmpty || $0.contains(q) }
        let canCreateTag = !normQ.isEmpty && !allTags.contains(normQ)
            && !categories.categories.contains { ($0.tag ?? "") == normQ }
        let canCreateCat = !normQ.isEmpty && !allTags.contains(normQ)
            && !categories.categories.contains {
                ($0.tag ?? "") == normQ || $0.id == normQ || TagText.sanitized($0.name) == normQ
            }

        return TaxonomyDialog(icon: "tag", title: "Tags & categories",
                              subtitle: "New render — tags apply when you render",
                              width: 460, maxBodyHeight: 400,
                              search: $search, searchPrompt: "search or create…", onClose: close) {
            if canCreateTag {
                TaxonomyCreateRow(label: "Create #\(normQ)", icon: "plus", tone: Tokens.accent) { createTag(normQ) }
            }
            if canCreateCat {
                TaxonomyCreateRow(label: "Create category “\(search.trimmingCharacters(in: .whitespaces))”",
                                  icon: "folder.badge.plus", tone: Tokens.add) { createCategory() }
            }
            TaxonomySectionLabel(label: "CATEGORIES", count: cats.count)
            if cats.isEmpty { TaxonomyEmptyHint("no categories") }
            ForEach(cats) { c in
                TaxonomyCategoryRow(category: c, selected: staged.contains(c.tag ?? "")) { toggle(c.tag ?? "") }
            }
            TaxonomySectionLabel(label: "TAGS", count: allTags.count).padding(.top, Spacing.sm)
            if allTags.isEmpty { TaxonomyEmptyHint("no tags") }
            ForEach(allTags, id: \.self) { t in
                TaxonomyTagRow(tag: t, color: tagColors.color(for: t), selected: staged.contains(t)) { toggle(t) }
            }
        } footer: {
            footer
        }
        // Snapshot the staged tag set on open (keyed, not once-on-appear) so
        // Save always diffs against the right baseline.
        .task(id: snapshotKey) {
            let base = staging.wrappedValue
            original = base
            // First baseline: merge under any selections already made instead
            // of wiping them.
            staged = baselineKey == nil ? staged.union(base) : base
            baselineKey = snapshotKey
        }
    }

    private var footer: some View {
        HStack {
            Text("\(staged.count) applied").font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.ultraDim)
            Spacer()
            // Always enabled — save() applies the staged/original diff (a
            // no-op when unchanged) and closes. The greyed .disabled gate
            // previously stranded a valid edit when the baseline snapshot raced
            // (item 7). The half-opacity "unchanged" dim read as a DISABLED save
            // button — the label now switches Save/Done instead, at full accent
            // either way.
            Button(action: { save() }) {
                Text(edited ? "Save" : "Done")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .accentPill(horizontal: Spacing.lg, vertical: Spacing.sm)
            }
            .buttonStyle(.plain)
            .help(edited ? "Apply changes" : "Close (no changes)")
        }
    }

    private func toggle(_ tag: String) {
        guard !tag.isEmpty else { return }
        if staged.contains(tag) { staged.remove(tag) } else { staged.insert(tag) }
    }

    private func createTag(_ t: String) {
        guard !t.isEmpty else { return }
        _ = declaredTags.add(t)
        staged.insert(t)
        search = ""
    }

    private func createCategory() {
        let name = search.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let cat = categories.addCategory(name: name), let tag = cat.tag { staged.insert(tag) }
        search = ""
    }

    private func save() {
        staging.wrappedValue = staged
        close()
    }

    private func normalized(_ s: String) -> String { TagText.sanitized(s) }

    private func close() {
        if let onClose { onClose() } else { router.closeTagDialog() }
    }
}
