// Sidebar — vertical filter rail. Search field + a LIBRARY section
// (single-select views: History · New · Rendering · Bookmarks · Starred) +
// CATEGORIES (Says = kind-backed, + user-added tag-backed
// buckets — History/New/Rendering live under LIBRARY, not here) + the TAGS
// list (open vocabulary). Categories and Tags are SEPARATE filter axes:
// a category drives the COLLECTION (`store.kindFilter` / `store.categoryTag`),
// the TAGS list drives the refinement (`store.tagFilter`), and they COMBINE
// (AND) — selecting a tag narrows within the current collection rather than
// replacing it; `query` greps within that.

import AppKit
import SwiftUI

struct Sidebar: View {
    @Environment(HistoryStore.self) var store
    @Environment(RenderQueue.self) var renderQueue
    @Environment(CategoryStore.self) var categories
    @Environment(DeclaredTagsStore.self) var declaredTags
    // Opens the Taxonomy Manager (add/delete/search categories + tags).
    @Environment(UIRouter.self) var router
    @Environment(AudioPlayer.self) var player
    @Environment(TagColorStore.self) var tagColors

    /// Tag awaiting the "Delete tag everywhere" confirmation (and how many
    /// renders carry it); nil = no dialog.
    @State private var pendingTagDelete: PendingTagDelete? = nil
    /// The search field's focus. ⌘F (router.searchRequest) takes it, Esc gives
    /// it back; at launch AppKit hands the window's first text field the
    /// focus, which made every single key (Space, B, [) type into the search
    /// instead of driving the player — the deferred reset in `.task` undoes
    /// that once the window is key.
    @FocusState private var searchFocused: Bool
    struct PendingTagDelete: Equatable {
        let tag: String
        let count: Int
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                searchField
                if let entry = store.continueEntry, player.activeEntry?.id != entry.id {
                    continueRow(entry)
                }
                Divider().background(Tokens.border)
                librarySection
                Divider().background(Tokens.border)
                if !store.seriesCounts.isEmpty {
                    seriesSection
                    Divider().background(Tokens.border)
                }
                categoriesSection
                Divider().background(Tokens.border)
                tagsSection
            }
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.xl)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity)
        // No undo: server tags are suppressed through removed_tags on every
        // render, so the one-click context menu now asks first.
        .confirmationDialog(
            pendingTagDelete.map { Self.deleteTagTitle(tag: $0.tag, count: $0.count) } ?? "",
            isPresented: Binding(get: { pendingTagDelete != nil },
                                 set: { if !$0 { pendingTagDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingTagDelete
        ) { pending in
            Button("Delete #\(pending.tag)", role: .destructive) { deleteTag(pending.tag) }
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.cancelAction)
        } message: { _ in
            Text("This can't be undone.")
        }
    }

    /// "Delete #tag from N renders?" — the confirmation names what goes.
    static func deleteTagTitle(tag: String, count: Int) -> String {
        count == 0 ? "Delete #\(tag)? No render carries it."
                   : "Delete #\(tag) from \(count) render\(count == 1 ? "" : "s")?"
    }

    // Bookmarks + Starred, moved off the header stat bar. Each opens the
    // same popover the header used (jump-to-bookmark / jump-to-starred).
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                sectionHeader("LIBRARY")
                // The fixed library views: History · New · Rendering · Bookmarks · Starred.
                sectionCount(5)
                Spacer()
            }
            // Mutually-exclusive single-select views (one at a time — NOT tags):
            // History (all), New (finished-but-unopened), Rendering (the live
            // work-in-progress bucket: active + queued + paused drafts),
            // Bookmarks, Starred. Each selection clears the others so exactly
            // one LIBRARY row is ever active.
            categoryRow(CategoryStore.history)
            // History is the master "all" view — set apart with a divider before
            // the filtered buckets below.
            Divider().background(Tokens.border).padding(.vertical, Spacing.xxs)
            categoryRow(CategoryStore.new)
            categoryRow(CategoryStore.rendering)
            // Badge counts bookmark ITEMS (the rows the Bookmarks view shows),
            // not the episodes that contain them.
            libraryRow(icon: "bookmark.fill", label: "Bookmarks",
                       count: store.liveBookmarkCount,
                       active: store.bookmarksFilter) { selectBookmarks() }
            libraryRow(icon: "star.fill", label: "Starred",
                       count: store.liveStarredCount,
                       active: store.starredFilter) { selectStarred() }
        }
    }

    /// Clear the mutually-exclusive COLLECTION axes (the selected row then sets
    /// its own). Leaves the TAGS refinement intact so Bookmarks/Starred combine
    /// with an active tag filter (#3 — orthogonal axes).
    private func clearLibrarySelection() {
        store.clearCollectionAxes()
    }

    private func selectBookmarks() { clearLibrarySelection(); store.bookmarksFilter = true }
    private func selectStarred() { clearLibrarySelection(); store.starredFilter = true }

    private func libraryRow(icon: String, label: String, count: Int,
                            active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Tokens.warn)
                Text(label).font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Spacing.xs)
                Text(count.formatted())
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, Spacing.xs).padding(.vertical, Spacing.xxs)
                    .background(Tokens.warn.opacity(0.16))
                    .foregroundStyle(Tokens.warn)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    .layoutPriority(1)
            }
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
            .background(active ? Tokens.accent.opacity(0.18) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(active ? Tokens.accent.opacity(0.65) : Color.clear))
            .foregroundStyle(active ? Tokens.accent : Tokens.text.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.quick, value: active)
        // The highlight alone doesn't reach VoiceOver (hig/voiceover.md ›
        // Descriptions).
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Continue listening: the last entry started but not finished. Click
    /// plays it from where it stopped and shows its row, expanded, in the list.
    private func continueRow(_ e: VoiceEntry) -> some View {
        let left = max(0, Int((e.progress?.durationS ?? e.bestDurationS()) - (e.progress?.playedS ?? 0)))
        return Button {
            player.play(e)
            router.closeToList()
            store.revealInList(e.id)
        } label: {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "play.circle.fill").font(.system(size: 14))
                    .foregroundStyle(Tokens.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CONTINUE").font(TypeScale.eyebrow).kerning(TypeScale.eyebrowKerning)
                        .foregroundStyle(Tokens.dim)
                    Text(e.seriesLabelIfNotInTitle.map { "\($0) — \(e.derivedTitle())" } ?? e.derivedTitle())
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(2).truncationMode(.tail)
                        .foregroundStyle(Tokens.text)
                    Text("\(fmtDuration(left)) left")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.sm)
            .background(Tokens.accent.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.accent.opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Resume where you stopped")
    }

    /// SERIES — one row per series in use; selecting one lists it in
    /// episode order (a collection axis, like a category).
    private var seriesSection: some View {
        let all = store.seriesCounts
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                sectionHeader("SERIES")
                sectionCount(all.count)
                Spacer()
            }
            ForEach(all, id: \.name) { s in
                libraryRow(icon: "books.vertical", label: s.name, count: s.count,
                           active: store.seriesFilter == s.name) {
                    clearLibrarySelection()
                    store.seriesFilter = s.name
                }
            }
        }
    }

    private var categoriesSection: some View {
        // History / New / Rendering live under LIBRARY — show only the user
        // buckets here (Says + tag-backed user categories).
        let cats = categories.categories.filter {
            $0.id != CategoryStore.history.id
                && $0.id != CategoryStore.new.id
                && $0.id != CategoryStore.rendering.id
        }
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                sectionHeader("CATEGORIES")
                sectionCount(cats.count)
                Spacer()
                manageButton
            }
            ForEach(cats) { cat in categoryRow(cat) }
        }
    }

    /// Replaces the per-section "+" — opens the Taxonomy Manager dialog
    /// (add / delete / search categories + tag-types).
    private var manageButton: some View {
        Button(action: { router.openTaxonomyManager() }) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                Text("manage").font(.system(size: 11, design: .monospaced))
            }
            // Trailing inset matches the row count-chip inset (rows pad
            // .horizontal Spacing.sm) so the link's right edge lines up with
            // the count badges it heads.
            .padding(.trailing, Spacing.sm)
            .foregroundStyle(Tokens.dim)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add or remove categories & tags")
    }

    private func categoryRow(_ cat: Category) -> some View {
        // Active reflects the COLLECTION axis only — the TAGS refinement is
        // orthogonal, so a category stays highlighted while you narrow by a
        // tag. History = no collection selected (any tag refinement aside); a
        // kind-backed category when kindFilter matches; a tag-backed category
        // when categoryTag matches.
        let isActive: Bool = {
            if cat.isAll {
                return store.kindFilter == nil && store.categoryTag == nil
                    && !store.starredFilter && !store.bookmarksFilter
                    && store.seriesFilter == nil
            }
            if let kind = cat.kind { return store.kindFilter == kind }
            if let t = cat.tag { return store.categoryTag == t }
            return false
        }()
        let isNewCat = cat.kind == CategoryStore.newKind
        let isRenderingCat = cat.kind == CategoryStore.renderingKind
        let isSpecial = cat.isAll                       // History — the master view
        // Rendering = the whole work-in-progress bucket (queued + active + paused
        // drafts), counting UNIQUE items: a draft being continued is BOTH a
        // resume job (in jobs) and a still-undeleted draft, so exclude resuming
        // drafts to avoid double-counting it. Others use the store's count.
        let count = isRenderingCat
            ? renderQueue.jobs.count + renderQueue.failed.count
                + store.resumableDrafts.filter { !renderQueue.resumingTSs.contains($0.ts) }.count
            : store.count(for: cat)
        // Live states: amber animated icon while a render is in flight; dim when
        // a Rendering/New bucket has nothing to act on.
        let renderingLive = isRenderingCat && renderQueue.isRendering
        let idleDim = (isRenderingCat && !renderingLive && count == 0)
                    || (isNewCat && count == 0)
        // Notification accent: amber for an active render, accent for unopened New.
        let liveColor: Color? = renderingLive ? Tokens.warn
                              : (isNewCat && count > 0 ? Tokens.accent : nil)
        return Button(action: { selectCategory(cat) }) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: renderingLive ? "waveform" : categoryIcon(cat))
                    .font(.system(size: 11))
                    .foregroundStyle(liveColor ?? (isActive ? Tokens.accent
                                                   : idleDim ? Tokens.dim : Tokens.text.opacity(0.85)))
                    .symbolEffect(.variableColor.iterative, isActive: renderingLive)
                Text(cat.name)
                    .font(.system(size: 11.5, weight: isSpecial ? .bold : .regular, design: .monospaced))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: Spacing.xs)
                // Badge: notification dot + count for live states (New unopened,
                // Rendering active); a plain count chip otherwise; hidden when an
                // idle New/Rendering bucket is empty.
                if !idleDim {
                    HStack(spacing: Spacing.xxs) {
                        if let liveColor { Circle().fill(liveColor).frame(width: 5, height: 5) }
                        Text(count.formatted())
                            .font(.system(size: 11, design: .monospaced))
                            .opacity(liveColor == nil ? 0.75 : 1)
                    }
                    .padding(.horizontal, Spacing.xs).padding(.vertical, Spacing.xxs)
                    .background((liveColor ?? Tokens.accent).opacity(liveColor == nil ? 0.14 : 0.18))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    .foregroundStyle(liveColor ?? Tokens.text)
                    .layoutPriority(1)
                }
            }
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
            .background(isActive ? Tokens.accent.opacity(0.18)
                        : renderingLive ? Tokens.warn.opacity(0.12)
                        : isSpecial ? Tokens.bg2.opacity(0.5)          // History anchor tint
                        : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(
                isActive ? Tokens.accent.opacity(0.65)
                : renderingLive ? Tokens.warn.opacity(0.55)
                : isSpecial ? Tokens.borderStrong
                : Color.clear))
            // Idle (empty New/Rendering) reads quieter through Tokens.dim, not
            // a row-wide opacity: 0.55 took the label to 4.31:1 and the
            // selected label to 3.15:1, under the 4.5:1 text minimum
            // (hig/accessibility.md › Vision). Tokens.dim on bg is 8.0:1.
            .foregroundStyle(isActive ? Tokens.accent
                             : renderingLive ? Tokens.warn
                             : idleDim ? Tokens.dim : Tokens.text.opacity(0.85))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(Motion.quick, value: isActive)
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .contextMenu {
            // Only user (tag-backed) categories are removable; the built-ins are not.
            if cat.tag != nil {
                Button(role: .destructive) {
                    if let t = cat.tag { store.clearCategoryTagIfActive(t) }
                    categories.removeCategory(cat.id)
                } label: { Label("Remove category", systemImage: "trash") }
            }
        }
    }

    /// Route a category click to its COLLECTION axis. The collection axes
    /// (kind / categoryTag / starred / bookmarks) are mutually exclusive, but
    /// the TAGS refinement is left intact so a category + a tag combine.
    /// History is the master view → a full reset (collection + tag refinement).
    private func selectCategory(_ cat: Category) {
        if cat.isAll {
            store.clearLibraryFilters()      // History — clean slate
            return
        }
        store.clearCollectionAxes()          // other collections keep the tag refinement
        if let kind = cat.kind {
            store.kindFilter = kind
        } else {
            store.categoryTag = cat.tag
        }
    }

    private func categoryIcon(_ cat: Category) -> String {
        if cat.isAll { return "clock.arrow.circlepath" }
        if cat.kind == CategoryStore.newKind { return "tray.full" }
        if cat.kind == CategoryStore.renderingKind { return "waveform.circle" }
        if cat.kind != nil { return "text.bubble" }
        return "folder"
    }

    private var searchField: some View {
        // @Environment(@Observable) doesn't project bindings via `$`, so wrap the
        // store in a local @Bindable to bind the search field to store.query.
        @Bindable var store = store
        return HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Tokens.dim).font(.system(size: 11))
            TextField("grep transcripts…", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Tokens.text)
                .focused($searchFocused)
                .onExitCommand { store.query = ""; leaveSearch() }
                .task(id: router.searchRequest) {
                    if router.searchRequest != nil { searchFocused = true }
                }
                .task {
                    try? await Task.sleep(for: .milliseconds(200))
                    if router.searchRequest == nil { leaveSearch() }
                }
            if !store.query.isEmpty {
                Button(action: { store.query = "" }) {
                    Image(systemName: "xmark").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Tokens.dim)
            }
        }
        .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
        .background(Tokens.bg2.opacity(0.5))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.border))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    /// Give the keyboard back to the window. Setting the focus state alone
    /// does not make the AppKit field editor resign (his live check: Esc left
    /// the search focused), so the window is told directly; with the window
    /// as first responder PlaybackKeys no longer yields.
    private func leaveSearch() {
        searchFocused = false
        for w in NSApp.windows where w.firstResponder is NSText { w.makeFirstResponder(nil) }
    }

    private func sectionHeader(_ s: String) -> some View {
        // No leading inset: headers align to the same left rail as the search
        // field, dividers, and the rows' selected-highlight box edge (which
        // starts at the row's leading, inset 0). Row *content* is padded
        // inside each row by Spacing.sm.
        Text(s)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.8)
            .foregroundStyle(Tokens.ultraDim)
    }

    /// Small dim count rendered right after a section title (CATEGORIES /
    /// TAGS) so the user sees how many buckets / distinct tags exist
    /// without scrolling the list.
    private func sectionCount(_ n: Int) -> some View {
        Text("(\(n))")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Tokens.ultraDim)
    }

    // Parity with CATEGORIES: a "+" to add (declare) a tag and a right-click
    // "Delete tag" that removes it everywhere (incl. immutable server tags,
    // via the overlay suppression list).
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                sectionHeader("TAGS")
                sectionCount(mergedTagRows().count)
                Spacer()
                manageButton
            }
            if store.tagFilter != nil {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    // Full tag-row width (the gallery is single-column rows with
                    // no grid cell to match).
                    Button(action: { store.tagFilter = nil }) {
                        Text("clear tag")
                            .font(.system(size: 11, design: .monospaced))
                            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(Tokens.del)
                            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.del.opacity(0.35)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Spacing.xs)
            }
            tagRows
        }
    }

    /// Declared tags ∪ tags in use, frequency-sorted (declared-but-unused
    /// show with count 0). Plain function so the type-checker doesn't choke
    /// on a big inline ViewBuilder expression.
    private func mergedTagRows() -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for (tag, n) in store.tagUniverse { counts[tag] = n }
        for tag in declaredTags.declared where counts[tag] == nil { counts[tag] = 0 }
        // A tag that backs a category already has its row under CATEGORIES
        // (e.g. a "Recipes" category on #recipes): don't list it twice.
        for cat in categories.categories { if let t = cat.tag { counts[t] = nil } }
        return counts
            .map { (tag: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count || ($0.count == $1.count && $0.tag < $1.tag) }
    }

    /// Each row filters on click and offers delete.
    @ViewBuilder
    private var tagRows: some View {
        let rows = mergedTagRows()
        if rows.isEmpty {
            Text("no tags yet — add one with +, or from a row")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.ultraDim)
                .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
        }
        ForEach(rows, id: \.tag) { row in
            // Same lookup as the chips (TagChip): a colour you picked wins.
            let c = tagColors.color(for: row.tag)
            let isActive = store.tagFilter == row.tag
            Button(action: { store.toggleTagFilter(row.tag) }) {
                HStack(spacing: Spacing.sm) {
                    Text("#\(row.tag)").font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: Spacing.xs)
                    Text(row.count.formatted())
                        .font(.system(size: 11, design: .monospaced))
                        .opacity(0.75)
                        .padding(.horizontal, Spacing.xs).padding(.vertical, Spacing.xxs)
                        .background(c.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        .layoutPriority(1)
                }
                .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                .background(isActive ? c.opacity(0.18) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(
                    isActive ? c.opacity(0.65) : Color.clear))
                .foregroundStyle(isActive ? c : c.opacity(0.85))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button(role: .destructive) {
                    pendingTagDelete = PendingTagDelete(tag: row.tag, count: row.count)
                } label: {
                    Label("Delete tag everywhere…", systemImage: "trash")
                }
            }
        }
    }

    private func deleteTag(_ tag: String) {
        store.clearTagFilterIfActive(tag)
        store.deleteTagEverywhere(tag)   // strips overlay + suppresses server tags
        declaredTags.remove(tag)
        tagColors.clearColor(for: tag)   // same cleanup as TaxonomyManageView.removeTagType
    }
}
