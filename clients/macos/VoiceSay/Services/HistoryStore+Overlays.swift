// HistoryStore+Overlays — entry semantics (complete/played) and every
// overlay write: tags, stars, bookmarks, titles, restore/trash. All daemon
// writes here go through sendOverlay -> POST /overlays/<ts>; mirrors are
// updated optimistically and confirmed by the SSE echo.
// Split from HistoryStore.swift.

import Foundation

extension HistoryStore {

    /// True when this render is fully RENDERED — i.e. NOT a resumable
    /// save-and-stop draft. The render-completion signal: drives the green
    /// progress visualizer, New-inbox eligibility, and the header/stat totals.
    /// (Every history row is a finished render except resumable drafts, which
    /// still have un-rendered text.) The virtual "#completed" tag is gated on
    /// PLAYBACK completion instead — see `hasFinishedPlayback`.
    func isComplete(_ e: VoiceEntry) -> Bool { !e.isResumableDraft }

    /// True when the user has played this render through to the end — the
    /// daemon's `progress.completed` (played_s >= duration). DISTINCT from
    /// `isComplete` (fully RENDERED): a freshly-rendered, unplayed clip is
    /// `isComplete` but not `hasFinishedPlayback`. Gates ONLY the virtual
    /// "#completed" tag (see `tagsFor`), so the tag means "listened to the
    /// end," not "finished rendering." The render→New/History transition still
    /// keys off `isComplete`, so an unplayed render still leaves the Rendering
    /// bucket and lands in New the instant it finishes rendering.
    func hasFinishedPlayback(_ e: VoiceEntry) -> Bool { e.progress?.completed ?? false }

    /// The virtual, undeletable "#completed" tag auto-applied once a render has
    /// been PLAYED to the end (see `tagsFor` / `hasFinishedPlayback`). Re-derived
    /// each call, so it can't be removed. The value is "completed" (single
    /// canonical spelling) — it matches Tokens.tagColor's "completed" case so the
    /// chip renders green.
    static let completedTag = "completed"

    func tagsFor(_ e: VoiceEntry) -> [String] {
        let key = tagKey(for: e)
        let server = e.tags ?? []
        let user = clientTags[key] ?? []
        // Suppressed (deleted) tags — subtracted so "delete tag" hides even
        // server/render-time tags an overlay can't rewrite.
        let removed = Set(clientRemovedTags[key] ?? e.overlay?.removedTags ?? [])
        // Union preserving server order first, then user-added; minus removed.
        var seen = Set<String>()
        var out: [String] = []
        for t in server + user where !removed.contains(t) && seen.insert(t).inserted { out.append(t) }
        // Virtual, undeletable "#completed": present iff the render has been
        // played to completion. Appended AFTER the removed-subtraction so it
        // can't be suppressed. Auto-applies the moment playback reaches the end.
        if hasFinishedPlayback(e), !seen.contains(Self.completedTag) { out.append(Self.completedTag) }
        return out
    }

    /// Delete a tag from every entry that carries it — across both the
    /// additive overlay tags and (via the suppression list) immutable
    /// server tags. Used by the sidebar's "Delete tag" action.
    func deleteTagEverywhere(_ tag: String) {
        guard tag != Self.completedTag else { return }   // virtual, undeletable
        for e in entries where tagsFor(e).contains(tag) {
            let key = tagKey(for: e)
            let cur = currentOverlay(for: e)
            var removed = cur.removedTags
            if !removed.contains(tag) { removed.append(tag) }
            var tags = cur.tags
            tags.removeAll { $0 == tag }
            // Update the mirrors OPTIMISTICALLY so the tag vanishes immediately
            // instead of only after the SSE echo lands — without this a type
            // delete looked like it did nothing (same fix as the bookmark
            // delete, "#4 bookmarks cannot be deleted").
            clientTags[key] = tags.isEmpty ? nil : tags
            clientRemovedTags[key] = removed.isEmpty ? nil : removed
            sendOverlay(ts: e.ts, OverlayRequest(tags: tags, removedTags: removed))
        }
    }

    func userTags(_ e: VoiceEntry) -> Set<String> {
        Set(clientTags[tagKey(for: e)] ?? [])
    }

    // Mutations — POST to daemon /overlays.

    /// Snapshot of the entry's overlay built from the @Observable mirrors.
    /// We prefer mirrors over `e.overlay` because mirrors are updated
    /// optimistically (and confirmed by SSE) — `e.overlay` lags by one
    /// round-trip, so two rapid clicks would compute against the stale
    /// value and the second click would clobber the first.
    private func currentOverlay(for e: VoiceEntry) -> Overlay {
        let key = tagKey(for: e)
        let base = e.overlay ?? .empty
        return Overlay(
            starred: starred.contains(key),
            deleted: deletedKeys.contains(key),
            tags: clientTags[key] ?? base.tags,
            removedTags: clientRemovedTags[key] ?? base.removedTags,
            bookmarks: bookmarks[key] ?? base.bookmarks
        )
    }

    /// Fire-and-forget, but in order: each write waits for the one before, so
    /// two clicks inside one round trip cannot land reversed at the daemon
    /// (unstructured Tasks start in any order; the daemon keeps the last).
    private func sendOverlay(ts: String, _ request: OverlayRequest) {
        let write = overlayWriter
        let previous = overlayWriteTail
        overlayWriteTail = Task {
            await previous?.value
            do {
                try await write(ts, request)
                // Daemon broadcasts an `overlay` SSE event; the apply path
                // updates entries[idx].overlay + the mirrors.
            } catch {
                // A user-intent write (star/tag/bookmark) failed: the
                // optimistic mirror no longer matches the daemon. Put the
                // mirrors back to the last overlay the daemon confirmed and
                // say so, instead of showing a change nobody else has.
                Log.daemon.error("overlay write failed for \(ts, privacy: .public): \(error.localizedDescription, privacy: .public)")
                rollBackMirrors(ts: ts)
                reportError("overlay write failed, change undone: \(error.localizedDescription)")
            }
        }
    }

    /// Re-derive the mirrors for `ts` from the entry's confirmed overlay
    /// (what the last /history, snapshot or overlay SSE said).
    func rollBackMirrors(ts: String) {
        guard let e = entries.first(where: { $0.ts == ts }) else { return }
        applyOverlayToMirrors(ts: ts, overlay: e.overlay ?? .empty)
    }

    func toggleStar(_ e: VoiceEntry) {
        let key = tagKey(for: e)
        let star = !currentOverlay(for: e).starred
        // Optimistic, like tags and bookmarks: a second click inside one round
        // trip then toggles back instead of sending `starred: true` twice.
        if star { starred.insert(key) } else { starred.remove(key) }
        recomputeLiveCounts()
        sendOverlay(ts: e.ts, OverlayRequest(starred: star))
    }

    // Bookmark mutations update the local `bookmarks` mirror OPTIMISTICALLY
    // before POSTing — the display path (bookmarksFor / visibleBookmarks) reads only
    // that mirror, and sendOverlay is fire-and-forget (it waits for the overlay
    // SSE echo). Without the optimistic write the list doesn't change until the
    // round-trip lands, so a delete looked like it did nothing (#4 "bookmarks
    // cannot be deleted"). The echo re-applies the same array, so it's
    // idempotent. Setting the mirror even when empty (`[]`, not nil) is required
    // so an all-removed entry overrides `base.bookmarks` instead of falling back
    // to it in currentOverlay.
    func addBookmark(_ e: VoiceEntry, position: Double, note: String) {
        var bms = currentOverlay(for: e).bookmarks
        bms.append(Bookmark(id: UUID().uuidString, position: position, note: note))
        bookmarks[tagKey(for: e)] = bms
        sendOverlay(ts: e.ts, OverlayRequest(bookmarks: bms))
    }

    func updateBookmark(_ e: VoiceEntry, id: String, note: String) {
        var bms = currentOverlay(for: e).bookmarks
        guard let idx = bms.firstIndex(where: { $0.id == id }) else { return }
        bms[idx] = Bookmark(id: id, position: bms[idx].position, note: note)
        bookmarks[tagKey(for: e)] = bms
        sendOverlay(ts: e.ts, OverlayRequest(bookmarks: bms))
    }

    func deleteBookmark(_ e: VoiceEntry, id: String) {
        var bms = currentOverlay(for: e).bookmarks
        bms.removeAll { $0.id == id }
        bookmarks[tagKey(for: e)] = bms
        sendOverlay(ts: e.ts, OverlayRequest(bookmarks: bms))
    }

    /// Add or remove one tag through setEffectiveTags, so it updates the card
    /// at once, survives a second quick edit, and can hide a render-time tag.
    func addTag(_ e: VoiceEntry, _ raw: String) {
        let clean = TagText.sanitized(raw)
        guard !clean.isEmpty else { return }
        var desired = Set(tagsFor(e))
        if desired.insert(clean).inserted { setEffectiveTags(e, desired: desired) }
    }

    func removeTag(_ e: VoiceEntry, _ tag: String) {
        guard tag != Self.completedTag else { return }   // virtual, undeletable
        var desired = Set(tagsFor(e))
        if desired.remove(tag) != nil { setEffectiveTags(e, desired: desired) }
    }

    /// Set the entry's COMPLETE desired effective tag set in ONE overlay write.
    /// The Tags & Category editor stages the desired *effective* set (server +
    /// user tags); this splits it into the overlay-added tags (desired − server)
    /// and the suppressed server tags (server − desired), updates the local
    /// mirrors optimistically (so the card reflects it immediately, not only
    /// after the SSE echo), and writes once.
    ///
    /// Replaces the earlier looping addTag/removeTag AND the overlay-space
    /// applyTagEdits — both raced or dropped tags: they read the
    /// stale optimistic mirror, so two quick saves clobbered each other and a
    /// server-tag remove silently no-op'd. This computes from `desired` + the
    /// entry's server tags only — never the mirror — so it's race-free, and one
    /// post carries every change atomically.
    func setEffectiveTags(_ e: VoiceEntry, desired: Set<String>) {
        let key = tagKey(for: e)
        // #completed is virtual (derived from progress): never store it.
        let desired = desired.subtracting([Self.completedTag])
        let server = Set(e.tags ?? [])
        let overlayTags = desired.subtracting(server).sorted()
        let removed = server.subtracting(desired).sorted()
        // Optimistic local update — the card shows the new tags immediately.
        clientTags[key] = overlayTags.isEmpty ? nil : overlayTags
        clientRemovedTags[key] = removed.isEmpty ? nil : removed
        recomputeLiveCounts()
        sendOverlay(ts: e.ts, OverlayRequest(tags: overlayTags, removedTags: removed))
    }

    /// Set (or, with an empty string, clear) the card's display title. The
    /// daemon stores it on the overlay; derivedTitle() prefers it over the
    /// first-sentence guess. The overlay SSE round-trip refreshes the row.
    /// Saving the title that is already shown writes nothing: the editors
    /// pre-fill the derived title and commit on focus loss, so an untouched
    /// edit would otherwise pin the auto title and stop it following the text.
    func setTitle(_ e: VoiceEntry, _ raw: String) {
        guard let title = Self.titleWrite(raw, shown: e.derivedTitle()) else { return }
        sendOverlay(ts: e.ts, OverlayRequest(title: title))
    }

    /// The title to POST for an edit, or nil when it equals the shown title.
    /// An emptied field returns "" (clears a set title, back to the auto one).
    nonisolated static func titleWrite(_ raw: String, shown: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return t == shown.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : t
    }

    func restore(_ e: VoiceEntry) {
        sendOverlay(ts: e.ts, OverlayRequest(deleted: false))
    }

    /// Hard delete — mark the overlay deleted=true so the row hides, then move
    /// the audio file to the Trash. The history row is preserved in the
    /// daemon's db (the entry is just unreachable now). Callers stop playback
    /// of this entry first (PlayerPanel, the reader).
    ///
    /// Overlay first: if the daemon can't take the write, nothing has moved
    /// and the row stays live. If the Trash then refuses the file, the overlay
    /// is put back so the row isn't hidden with its audio still on disk. Either
    /// failure is reported.
    func trashEntry(_ e: VoiceEntry) async {
        let key = tagKey(for: e)
        deletingKeys.insert(key)
        defer { deletingKeys.remove(key) }

        // 1. Hide via overlay. Awaited (not sendOverlay's fire-and-forget) so
        //    the row vanishes in the same tick as the loader clearing.
        do {
            try await overlayWriter(e.ts, OverlayRequest(deleted: true))
        } catch {
            reportError("trash: could not hide the render, nothing was moved (\(error.localizedDescription))")
            return
        }
        // The SSE echo re-applies the same end state.
        deletedKeys.insert(key)
        recomputeLiveCounts()
        recomputeTotals()

        // 2. Move the audio to the Trash. A file already gone (deleted by
        //    hand) leaves nothing to move; the row stays hidden.
        guard let audio = e.resolvedAudioURL(),
              FileManager.default.fileExists(atPath: audio.path) else { return }
        do {
            try await recycler(audio)
        } catch {
            let why = error.localizedDescription
            do {
                try await overlayWriter(e.ts, OverlayRequest(deleted: false))
                deletedKeys.remove(key)
                recomputeLiveCounts()
                recomputeTotals()
                reportError("trash: could not move the audio to the Trash (\(why)); the render is back in the list")
            } catch {
                reportError("trash: could not move the audio to the Trash (\(why)) and could not un-hide the row; the file is still at \(audio.path)")
            }
        }
    }


    func tagKey(for e: VoiceEntry) -> String { e.archiveName ?? e.ts }

    /// Bookmarks for an entry — hides the tagKey indirection (mirrors tagsFor).
    func bookmarksFor(_ e: VoiceEntry) -> [Bookmark] { bookmarks[tagKey(for: e)] ?? [] }

    /// Bookmarks for an entry, ordered by position.
    func bookmarksSortedFor(_ e: VoiceEntry) -> [Bookmark] {
        bookmarksFor(e).sorted { $0.position < $1.position }
    }

    /// Flat bookmark-item list (the Bookmarks view, via `visibleBookmarks`):
    /// each bookmark paired with its source entry. Entries keep their order;
    /// bookmarks within an entry come as `bookmarksFor` gives them. Liveness +
    /// lookup injected, so it tests without a daemon or the private mirrors.
    static func flattenBookmarks(entries: [VoiceEntry],
                                 isLive: (VoiceEntry) -> Bool,
                                 bookmarksFor: (VoiceEntry) -> [Bookmark])
        -> [(entry: VoiceEntry, bookmark: Bookmark)] {
        entries.filter(isLive).flatMap { e in bookmarksFor(e).map { (entry: e, bookmark: $0) } }
    }
}
