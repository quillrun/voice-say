// UIRouter — centralizes the full-screen routing so deep views (a
// CommitRow's "View transcript" button) can drive a window-level overlay
// without prop-drilling bindings through every parent.
//
// Scope: the mutually-exclusive full-screen surfaces (list / compose /
// settings / transcript) plus the tag dialog (a centered scrim over the
// list). The voice picker is presented locally by Compose + Settings —
// it writes back into each view's own selection state — so it isn't
// routed here.

import SwiftUI

@MainActor
@Observable
final class UIRouter {
    enum Screen: Equatable {
        case list
        case compose
        case settings
        case transcript(String)   // entry id
    }

    private(set) var screen: Screen = .list
    /// Entry id whose tag/category dialog is open; nil = closed.
    private(set) var tagDialogEntryID: String? = nil
    /// Taxonomy manager (add/delete/search categories + tag-types, no
    /// per-entry selection) — opened from the sidebar Manage button.
    private(set) var taxonomyManagerOpen: Bool = false
    /// Help ▸ Keyboard Shortcuts (⌘/) — a card over whatever is in front.
    private(set) var shortcutsOpen: Bool = false
    /// Mirror of ContentView's sidebar visibility (which also depends on the
    /// window width), so the View menu and the header button can say Show or
    /// Hide. ContentView owns the state and is the only writer.
    var sidebarShown: Bool = true

    func open(_ s: Screen) {
        withAnimation(Motion.standard) { screen = s }
    }

    func closeToList() {
        withAnimation(Motion.standard) { screen = .list }
    }

    /// The list itself is in front: no full-screen route and no dialog over
    /// it. The list (and an expanded row's PlayerPanel) stays mounted under
    /// Compose, Settings and the reader, so its key equivalents (⌘Y, a note
    /// editor's Esc, ⌘⌫) are live only while this holds.
    var listInFront: Bool { Self.listInFront(screen: screen, overlayOpen: overlayOpen) }

    /// A dialog or the shortcuts card sits over the screen in front: the
    /// player keys and the list's key equivalents stay with it.
    var overlayOpen: Bool { tagDialogEntryID != nil || taxonomyManagerOpen || shortcutsOpen }

    nonisolated static func listInFront(screen: Screen, overlayOpen: Bool) -> Bool {
        screen == .list && !overlayOpen
    }

    func openTagDialog(for entryID: String) { tagDialogEntryID = entryID }
    func closeTagDialog() { tagDialogEntryID = nil }
    func openTaxonomyManager() { taxonomyManagerOpen = true }
    func closeTaxonomyManager() { taxonomyManagerOpen = false }
    func toggleShortcuts() { shortcutsOpen.toggle() }
    func closeShortcuts() { shortcutsOpen = false }

    /// ⌘⌫ on the list (PlaybackKeys): the expanded row's PlayerPanel opens its
    /// Move-to-Trash confirmation. A fresh token per press, so pressing again
    /// for the same row is still a change.
    struct TrashRequest: Equatable {
        let entryID: String
        let token = UUID()
    }
    private(set) var trashRequest: TrashRequest? = nil
    func requestTrash(_ entryID: String) { trashRequest = TrashRequest(entryID: entryID) }

    /// ⌘F (Find in Library): the list comes in front, ContentView shows the
    /// sidebar, the Sidebar's search field takes focus. A fresh token per
    /// press, like TrashRequest.
    struct SearchRequest: Equatable {
        let token = UUID()
    }
    private(set) var searchRequest: SearchRequest? = nil
    func requestSearch() {
        if screen != .list { closeToList() }
        searchRequest = SearchRequest()
    }
}
