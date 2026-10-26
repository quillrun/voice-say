// ContentView — root window for VoiceSay. A sticky header (brand + daemon pill
// + speed/sleep + compose/settings toggles) over a left Sidebar (search
// + LIBRARY + CATEGORIES + TAGS) and a scrolling list of git-log commits. The
// New-render compose flow is a full-screen routed screen, not an inline
// collapsible section.

import SwiftUI

struct ContentView: View {
    @Environment(HistoryStore.self) var store
    @Environment(AudioPlayer.self) var player
    @Environment(UIRouter.self) var router
    @Environment(HealthMonitor.self) var health

    // Lazy "load more on scroll" window over store.filtered — render
    // 50, grow by 50 when the sentinel scrolls into view. Reset on filter
    // change. Keeps the first paint cheap when the history is large.
    @State private var visibleCount = 50
    /// Sidebar: hidden by choice (persisted) or automatically below
    /// `Self.narrowWidth`; ⌥⌘S / the header button toggles it.
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @State private var showWhenNarrow = false
    @State private var width: CGFloat = 1000
    nonisolated static let narrowWidth: CGFloat = 900

    nonisolated static func sidebarVisible(width: CGFloat, collapsed: Bool, showWhenNarrow: Bool) -> Bool {
        width < narrowWidth ? showWhenNarrow : !collapsed
    }

    private var sidebarShown: Bool {
        Self.sidebarVisible(width: width, collapsed: sidebarCollapsed, showWhenNarrow: showWhenNarrow)
    }

    private func toggleSidebar() {
        withAnimation(Motion.standard) {
            if width < Self.narrowWidth { showWhenNarrow.toggle() } else { sidebarCollapsed.toggle() }
        }
    }

    /// The entry pinned as a sticky card above the list: the track loaded in
    /// the player — tagged "Now Playing" while playing, "Last Played" while
    /// paused. Pinned only while a track is loaded; on Stop the player clears
    /// `activeEntry`. Filter-independent — reads the player, not the current
    /// view's filter. The entry also STAYS in the list (highlighted border via
    /// CommitRow.isActiveInPlayer); the sticky card is an indicator + shortcut,
    /// not the entry's new home.
    private var pinnedEntry: VoiceEntry? { player.activeEntry }


    var body: some View {
        ZStack(alignment: .top) {
            Tokens.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HeaderView()
                    // Window width drives the narrow-width sidebar auto-hide.
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                    .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
                        toggleSidebar()
                    }
                    .onChange(of: router.searchRequest) { _, req in
                        guard req != nil, !sidebarShown else { return }
                        withAnimation(Motion.standard) {
                            if width < Self.narrowWidth { showWhenNarrow = true } else { sidebarCollapsed = false }
                        }
                    }
                // Stays up while the daemon is down (polled every 10 s); the
                // error banner below stays until dismissed.
                if !health.healthOK {
                    daemonDownBanner
                }
                // A failed history fetch while the daemon is known down says
                // the same thing as the banner above: show one of them.
                if let err = store.lastError,
                   health.healthOK || !err.hasPrefix(HistoryStore.fetchErrorPrefix) {
                    errorBanner(err)
                }
                HStack(alignment: .top, spacing: 0) {
                    if sidebarShown {
                        Sidebar()
                            .frame(width: 220)
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(Tokens.border).frame(width: 1)
                            }
                            .transition(.move(edge: .leading))
                    }
                    Group {
                    if store.kindFilter == CategoryStore.renderingKind {
                        // The live Rendering category IS the work-in-progress
                        // bucket: the active render (its Pause/Stop/Delete controls
                        // now live ON the card), the queued "up next" list, and the
                        // PAUSED drafts. RenderQueueView owns its own scrolling.
                        RenderQueueView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if store.bookmarksFilter {
                        // The Bookmarks LIBRARY view lists bookmark ITEMS
                        // (timestamp + note + source episode), not the episodes
                        // that contain them. BookmarksListView owns its scrolling.
                        BookmarksListView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            // Provisional streaming-episode card — shown at
                            // the top while an episode renders+plays and has
                            // no canonical voice.db row yet. Replaced by the
                            // one canonical row on episode_complete.
                            if let ep = store.streamingEpisode, !ep.done {
                                StreamingEpisodeCard(episode: ep)
                                    .padding(.horizontal, sidePadding)
                                    .padding(.top, Spacing.md)
                                    .padding(.bottom, Spacing.sm)
                            }
                            if store.filtered.isEmpty && store.streamingEpisode == nil {
                                if store.isLoading && store.entries.isEmpty {
                                    ProgressView("loading history…")
                                        .controlSize(.small)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Tokens.dim)
                                        .frame(maxWidth: .infinity)
                                        .padding(.top, Spacing.xxl)
                                } else {
                                    EmptyState(query: store.query,
                                               inNew: store.kindFilter == CategoryStore.newKind,
                                               starred: store.starredFilter,
                                               libraryEmpty: store.entries.isEmpty)
                                        .padding(.top, Spacing.xxl)
                                }
                            } else if !store.filtered.isEmpty {
                                // LazyVStack so SwiftUI only materializes
                                // visible CommitRows (+ small buffer).
                                // Eager VStack rendered every PlayerPanel
                                // off-screen too, blowing layout time as
                                // the library grew. LazyVStack keeps the
                                // scroller smooth at hundreds of rows.
                                let shown = Array(store.filtered.prefix(visibleCount))
                                LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                                    ForEach(shown, id: \.id) { entry in
                                        CommitRow(entry: entry,
                                                  isExpanded: store.expandedEntryID == entry.id,
                                                  onToggle: { toggleRow(entry) })
                                            .id(entry.id)
                                    }
                                    // Lazy-load 50 more on scroll.
                                    LoadMoreSentinel(hasMore: visibleCount < store.filtered.count,
                                                     onLoadMore: { visibleCount += 50 })
                                }
                                // Animate row insertions (new render lands in the list).
                                // Value-driven — fires only when the list count changes.
                                .animation(Motion.standard, value: store.filtered.count)
                                .padding(.horizontal, sidePadding)
                                .padding(.bottom, Spacing.xxl)
                            }
                        }
                        .scrollIndicators(.visible)
                        // Reset the window to the top whenever the filter changes.
                        .onChange(of: store.query) { _, _ in visibleCount = 50 }
                        .onChange(of: store.tagFilter) { _, _ in visibleCount = 50 }
                        .onChange(of: store.categoryTag) { _, _ in visibleCount = 50 }
                        .onChange(of: store.kindFilter) { _, _ in visibleCount = 50 }
                        .onChange(of: store.starredFilter) { _, _ in visibleCount = 50 }
                        .onChange(of: store.bookmarksFilter) { _, _ in visibleCount = 50 }
                        .onChange(of: store.seriesFilter) { _, _ in visibleCount = 50 }
                        .onChange(of: store.pendingScrollID) { _, newID in
                            guard let id = newID else { return }
                            // A jump (bookmark/starred/prev-next/pinned card)
                            // can target an entry below the current window —
                            // grow it so scrollTo can find the row.
                            let grow = {
                                if let idx = store.filtered.firstIndex(where: { $0.id == id }), idx >= visibleCount {
                                    visibleCount = idx + 1
                                }
                            }
                            grow()
                            // Two-phase scroll: a freshly-grown LazyVStack may
                            // not have materialized the target row 0.05s in —
                            // an early scrollTo is then a silent no-op (the
                            // pinned-card jump bug). Re-grow first in case a
                            // concurrent filter reset shrank the window.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                grow()
                                withAnimation(Motion.standard) {
                                    proxy.scrollTo(id, anchor: .top)
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                                    withAnimation(Motion.standard) {
                                        proxy.scrollTo(id, anchor: .top)
                                    }
                                    store.acknowledgeScroll()
                                }
                            }
                        }
                    }
                    }   // end: Rendering-queue vs. history-list branch
                    }
                    // Sticky "Now Playing / Last Played" card above EVERY view
                    // (history, Rendering, Bookmarks, a series, mid-render). A
                    // safe-area bar, not a stacked row: the list scrolls UNDER
                    // the card's Liquid Glass (hig/materials.md › Liquid Glass —
                    // a control layer floating above content), and the bar gets
                    // the system scroll edge effect so rows never show sharp in
                    // the gap above it (hig/scroll-views.md › Scroll edge
                    // effects). The entry stays
                    // in the list too (highlighted border); clicking the card
                    // jumps to + expands the real list row.
                    .safeAreaBar(edge: .top, spacing: 0) {
                        if let pinned = pinnedEntry {
                            CommitRow(entry: pinned,
                                      isExpanded: false,
                                      onToggle: {
                                          // revealInList, not activate: the playing
                                          // entry may be hidden by the current filter
                                          // — clear it first or the jump no-ops.
                                          store.revealInList(pinned.id)
                                          store.markSeenIfNew(pinned.id)
                                      },
                                      pinLabel: player.isPlaying ? "Now Playing" : "Last Played")
                                .padding(.horizontal, sidePadding)
                                .padding(.top, Spacing.md)
                                .padding(.bottom, Spacing.sm)
                        }
                    }
                }
            }
            // The overlays below are drawn, not presented, so VoiceOver would
            // still reach the header, sidebar and list under them; the parent
            // of a modal is out of reach while it is up (hig/sheets.md ›
            // Platform considerations › macOS).
            .accessibilityHidden(router.screen != .list || router.overlayOpen)

            // Full-screen surfaces, driven by the router. New render +
            // Settings slide from the top; the Transcript reader slides from
            // the trailing edge; the tag dialog is a centered scrim. Each
            // covers the window above the list.
            if router.screen == .compose {
                ComposeScreen()
                    .transition(.move(edge: .top))
                    .zIndex(2)
            }
            if router.screen == .settings {
                SettingsScreen()
                    .transition(.move(edge: .top))
                    .zIndex(2)
            }
            if case .transcript(let id) = router.screen {
                TranscriptScreen(entryID: id)
                    .transition(.move(edge: .trailing))
                    .zIndex(3)
            }
            if let id = router.tagDialogEntryID {
                TagPicker(entryID: id)
                    .zIndex(4)
            }
            if router.taxonomyManagerOpen {
                TaxonomyManager()
                    .zIndex(4)
            }
            if router.shortcutsOpen {
                KeyboardShortcutsSheet()
                    .zIndex(5)
            }
        }
        .onChange(of: sidebarShown, initial: true) { _, shown in router.sidebarShown = shown }
        .animation(Motion.springy, value: store.streamingEpisode?.id)
        .animation(Motion.springy, value: pinnedEntry?.id)
        .animation(Motion.standard, value: router.screen)
        .foregroundStyle(Tokens.text)
        .font(.system(.body, design: .monospaced))
    }

    // Slightly generous horizontal gutter so content doesn't kiss the
    // window chrome — snapped to the Spacing.xl step for a calmer reading
    // frame that stays on the 4-pt grid.
    private var sidePadding: CGFloat { Spacing.xl }

    /// A render-row click expands/collapses it inline (the PlayerPanel with
    /// controls + visualizer). A separate "Read transcript" button inside the
    /// expanded panel opens the full reader. Expanding marks a New render seen.
    private func toggleRow(_ entry: VoiceEntry) {
        if store.expandedEntryID == entry.id {
            store.expandedEntryID = nil
        } else {
            store.expandedEntryID = entry.id
            store.markSeenIfNew(entry.id)
        }
    }

    @ViewBuilder
    private var daemonDownBanner: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tokens.del)
            Text("The voice-say daemon isn't answering — \(DaemonController.startHint). "
                 + "History, rendering and playback of new renders wait until it's back.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Tokens.del)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if DaemonController.agentInstalled {
                Button("Settings") { router.open(.settings) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tokens.accent)
                    .help("Start or restart the daemon")
            }
        }
        .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
        .background(Tokens.del.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.del.opacity(0.5)))
        .padding(.horizontal, sidePadding)
        .padding(.bottom, Spacing.sm)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text(msg)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Tokens.del)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            // Dismiss — the banner used to pin open with no way to close it.
            Button(action: { store.clearError() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Tokens.del)
                    .padding(4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
        .background(Tokens.del.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.del.opacity(0.5)))
        .padding(.horizontal, sidePadding)
        .padding(.bottom, Spacing.sm)
        // No auto-dismiss: a 10 s timeout took the error away before a slow
        // reader finished it (hig/accessibility.md › Cognitive, time-boxed
        // elements). The X clears it; a new error replaces the text.
    }
}

// Subviews have moved to their own files in this directory:
//   HeaderView.swift, Sidebar.swift, CommitRow.swift,
//   Popovers.swift, EmptyState.swift, ../Theme/Formatters.swift.
