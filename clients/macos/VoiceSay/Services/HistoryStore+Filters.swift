// HistoryStore+Filters — search/filter axes and the derived collections
// (filtered, playable neighbors, tag universe, category counts).
// Split from HistoryStore.swift: same type, one
// responsibility per file. Stored state stays in HistoryStore.swift — as do
// the New-inbox mutators, so newIDs/stickyNewView keep private(set)/private
// and the write → persistNewIDs() pairing stays compiler-enforced.

import Foundation

extension HistoryStore {
    /// Toggle the TAGS-section refinement. Tags are an INDEPENDENT axis from the
    /// collection (LIBRARY/CATEGORIES): selecting a tag refines WITHIN the
    /// current collection (it no longer clears the collection), and `query`
    /// greps within that — "search with tag filters searches in history".
    func toggleTagFilter(_ tag: String) {
        if tagFilter == tag { tagFilter = nil } else { tagFilter = tag }
    }

    /// Clear the mutually-exclusive COLLECTION axes (kind / category-tag /
    /// starred / bookmarks) — exactly one collection is active at a time. Leaves
    /// the TAGS refinement (`tagFilter`) intact so it survives a collection
    /// switch (the axes are orthogonal, #3). For a full reset incl. the tag
    /// refinement use `clearLibraryFilters()`.
    func clearCollectionAxes() {
        kindFilter = nil
        categoryTag = nil
        starredFilter = false
        bookmarksFilter = false
        seriesFilter = nil
    }

    /// Series in use (sidebar SERIES), by name, with live episode counts.
    var seriesCounts: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for e in entries where !deletedKeys.contains(tagKey(for: e)) && isComplete(e) {
            if let s = e.overlay?.series, !s.isEmpty { counts[s, default: 0] += 1 }
        }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Episode order for a series view: numbered episodes ascending, then
    /// unnumbered ones oldest-first. Pure, so it tests without a store.
    nonisolated static func seriesOrder(_ a: VoiceEntry, _ b: VoiceEntry) -> Bool {
        switch (a.overlay?.episode, b.overlay?.episode) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.ts < b.ts
        }
    }

    /// Count of resumable (paused) drafts — part of the Rendering bucket now.
    /// Live resumable-draft entries (paused renders). The PAUSED section + the
    /// Rendering count both derive from this; the caller dedupes against any
    /// queued resume so a draft being continued isn't counted/shown twice.
    var resumableDrafts: [VoiceEntry] {
        entries.filter { !deletedKeys.contains(tagKey(for: $0)) && $0.isResumableDraft }
    }
    var resumableDraftCount: Int { resumableDrafts.count }

    /// Full reset — every collection axis (kind / category-tag / starred /
    /// bookmarks) AND the tag refinement. The caller then sets the one axis it
    /// wants, or leaves all clear for History. Centralizes the reset that
    /// Sidebar's History row and the render / save-and-stop transitions each
    /// open-coded.
    func clearLibraryFilters() {
        clearCollectionAxes()
        tagFilter = nil
    }

    /// Clear the tag refinement iff it currently points at `tag` — called from
    /// the tag delete path so the active filter doesn't dangle on a now-deleted
    /// tag.
    func clearTagFilterIfActive(_ tag: String) {
        if tagFilter == tag { tagFilter = nil }
    }

    /// Clear the category-collection axis iff it points at `tag` — called when a
    /// tag-backed category is removed so the active collection doesn't dangle.
    func clearCategoryTagIfActive(_ tag: String) {
        if categoryTag == tag { categoryTag = nil }
    }


    var filtered: [VoiceEntry] {
        // Not-fully-rendered drafts never appear in history / list views — they
        // live only in the Rendering bucket (PAUSED). isComplete = not a
        // resumable draft.
        let liveEntries = entries.filter { !deletedKeys.contains(tagKey(for: $0)) && isComplete($0) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let series = seriesFilter?.lowercased()
        let hits = liveEntries.filter { entry in
            if let series, entry.overlay?.series?.lowercased() != series { return false }
            if starredFilter, !starred.contains(tagKey(for: entry)) { return false }
            if bookmarksFilter, bookmarksFor(entry).isEmpty { return false }
            // Tag refinement and category-collection are INDEPENDENT axes:
            // both must match, so a category + a tag narrow the set together.
            if let t = tagFilter, !tagsFor(entry).contains(t) { return false }
            if let ct = categoryTag, !tagsFor(entry).contains(ct) { return false }
            if let k = kindFilter {
                // The "New" inbox filters by the unopened set, not by entry.kind
                // (no stored entry carries the sentinel kind).
                if k == CategoryStore.newKind {
                    if !isNewVisible(entry) { return false }
                } else if entry.kind != k {
                    return false
                }
            }
            if q.isEmpty { return true }
            return matchesQuery(entry, q, includeNotes: true)
        }
        return series == nil ? hits : hits.sorted(by: Self.seriesOrder)
    }

    /// Search over one entry; `q` is already trimmed + lowercased.
    private func matchesQuery(_ entry: VoiceEntry, _ q: String, includeNotes: Bool) -> Bool {
        if entry.derivedTitle().lowercased().contains(q) { return true }
        // Grep matches against the full transcript (served inline by the
        // daemon as entry.text), not a preview.
        if (entry.text ?? "").lowercased().contains(q) { return true }
        if (entry.voice ?? "").lowercased().contains(q) { return true }
        if tagsFor(entry).contains(where: { $0.lowercased().contains(q) }) { return true }
        if includeNotes, bookmarksFor(entry).contains(where: { $0.note.lowercased().contains(q) }) { return true }
        return false
    }

    /// The Bookmarks view's rows: bookmarks of the entries `filtered` keeps
    /// (so the tag filter and search apply, as the sidebar promises). With a
    /// search, a bookmark shows when its own note matches or its episode
    /// matches by title, text, voice or tag; another note of the same
    /// episode matching doesn't bring it along.
    var visibleBookmarks: [(entry: VoiceEntry, bookmark: Bookmark)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.flattenBookmarks(entries: filtered, isLive: { _ in true },
                                     bookmarksFor: { bookmarksSortedFor($0) })
            .filter { q.isEmpty || $0.bookmark.note.lowercased().contains(q)
                      || matchesQuery($0.entry, q, includeNotes: false) }
    }

    /// Voice of the most-recently-played entry, by `progress.lastPlayed`
    /// (the daemon's ISO-8601 `last_played`). nil when nothing has been
    /// played. Drives the voice picker's "float the recent voice to the top"
    /// behaviour when no track is actively loaded.
    var lastPlayedVoice: String? {
        VoiceOrdering.mostRecentlyPlayedVoice(entries.map { ($0.voice, $0.progress?.lastPlayed) })
    }

    /// Visible-order neighbor for the player's prev/next transport: the
    /// adjacent entry in `filtered` (direction -1 = up the list / newer,
    /// +1 = down / older), skipping rows whose audio is missing on disk.
    /// nil at either end or when `id` isn't in the current filter.
    func playableNeighbor(of id: String, direction: Int) -> VoiceEntry? {
        let list = filtered
        guard let idx = Self.neighborIndex(ids: list.map(\.id), of: id, direction: direction,
                                           playable: { list[$0].resolvedAudioURL() != nil })
        else { return nil }
        return list[idx]
    }

    /// Pure core of `playableNeighbor` — the index walk with playability
    /// injected, so it tests without touching the filesystem.
    nonisolated static func neighborIndex(ids: [String], of id: String, direction: Int,
                                          playable: (Int) -> Bool) -> Int? {
        guard direction != 0, let start = ids.firstIndex(of: id) else { return nil }
        var i = start + direction
        while i >= 0 && i < ids.count {
            if playable(i) { return i }
            i += direction
        }
        return nil
    }

    /// Sidebar universe — every tag in use across live complete entries (what
    /// a tag filter can show), sorted by frequency. Open vocabulary: any tag a render or overlay
    /// applies shows up here, so this rail IS the tag namespace.
    var tagUniverse: [(String, Int)] {
        var counts: [String: Int] = [:]
        for e in entries where !deletedKeys.contains(tagKey(for: e)) && isComplete(e) {
            for t in tagsFor(e) {
                counts[t, default: 0] += 1
            }
        }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
    }

    /// Count of live (non-deleted) entries in a category.
    ///   • History (isAll) counts every live COMPLETE entry (resumable drafts
    ///     are counted in the Rendering bucket, not here — matches `filtered`).
    ///   • a kind-backed category counts entries whose `kind` matches.
    ///   • a tag-backed category counts entries whose effective tags contain
    ///     its backing tag.
    func count(for category: Category) -> Int {
        let live = entries.filter { !deletedKeys.contains(tagKey(for: $0)) && isComplete($0) }
        if category.isAll { return live.count }
        // The "New" inbox counts unopened live completed renders (a deleted
        // one keeps its id in newIDs but is no longer listed).
        if category.kind == CategoryStore.newKind { return live.filter { newIDs.contains($0.ts) }.count }
        // Live "Rendering" bucket = active render + paused drafts. (The Sidebar
        // adds the queued count, which lives on RenderQueue, not this store.)
        if category.kind == CategoryStore.renderingKind {
            return (streamingEpisode != nil ? 1 : 0) + resumableDraftCount
        }
        if let kind = category.kind {
            return live.filter { $0.kind == kind }.count
        }
        guard let tag = category.tag else { return live.count }
        return live.filter { tagsFor($0).contains(tag) }.count
    }
}
