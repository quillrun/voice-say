// BookmarksListView — the center pane for the sidebar's Bookmarks selection.
// A flat list of bookmark ITEMS (timestamp + note + source episode), not the
// episodes that contain them. Tap a row to EXPAND it in place (full note + a
// "Play from here" action) — a tap NEVER navigates away or stops what's
// currently playing. "Show episode" is the single navigation out: it clears the
// bookmarks filter and jumps to the episode's card in the history list.

import SwiftUI

struct BookmarksListView: View {
    @Environment(HistoryStore.self) var store
    @Environment(AudioPlayer.self) var player

    /// Which rows are expanded. Tap-to-expand reveals the full note + a
    /// play-from-here action in place; the cell no longer navigates or seeks the
    /// player on a bare tap. Keyed by the same composite id as Row.
    @State private var expanded: Set<String> = []

    /// Composite identity — bookmark ids are UUIDs minted per entry, but a
    /// copied overlay must never collapse two rows, so key on entry + bookmark.
    private struct Row: Identifiable {
        let entry: VoiceEntry
        let bookmark: Bookmark
        var id: String { "\(entry.ts)/\(bookmark.id)" }
    }

    var body: some View {
        let rows = store.visibleBookmarks.map { Row(entry: $0.entry, bookmark: $0.bookmark) }
        let narrowed = store.tagFilter != nil
            || !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.warn)
                    Text("BOOKMARKS (\(rows.count))")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .kerning(0.8).foregroundStyle(Tokens.warn)
                    Spacer(minLength: 0)
                }
                .padding(.top, Spacing.md)
                if rows.isEmpty {
                    Text(narrowed ? "no bookmarks match the search or tag filter"
                                  : "no bookmarks yet — add one from the player or the transcript reader")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Tokens.ultraDim)
                        .padding(.vertical, Spacing.lg)
                } else {
                    ForEach(rows) { row in
                        bookmarkCard(row.entry, row.bookmark, rowID: row.id)
                    }
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xxl)
        }
        .scrollIndicators(.visible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleExpand(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func bookmarkCard(_ entry: VoiceEntry, _ bm: Bookmark, rowID: String) -> some View {
        let isExpanded = expanded.contains(rowID)
        let ts = bookmarkTimestamp(bm, totalSeconds: Int(entry.bestDurationS()))
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            // Tap-to-expand content (full note). A tap only toggles the note — it
            // never navigates or changes playback. The actions live on their
            // OWN row below, not nested in this tap zone, so their clicks can't be
            // swallowed by the greedy (maxWidth: .infinity) expand button.
            Button(action: { toggleExpand(rowID) }) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(alignment: .top, spacing: Spacing.sm) {
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Tokens.warn)
                        Text(ts)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Tokens.warn)
                        Text(bm.note.isEmpty ? "(no note)" : bm.note)
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(bm.note.isEmpty ? Tokens.ultraDim : Tokens.text)
                            .italic(bm.note.isEmpty)
                            // Collapsed clamps to 2 lines; expanded shows the
                            // whole note (and lets you select it).
                            .lineLimit(isExpanded ? nil : 2)
                            .textSelection(.enabled)
                        Spacer(minLength: Spacing.xs)
                        // Chevron signals the row opens in place rather than
                        // navigating.
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Tokens.dim)
                    }
                    // Source episode — where this bookmark lives.
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11))
                            .foregroundStyle(Tokens.dim)
                        Text(entry.derivedTitle())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Tokens.dim)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Collapse" : "Tap to expand the full note")

            // Inline action row — ALWAYS visible, on its own row so the taps
            // never fight the expand zone above.
            HStack(spacing: Spacing.sm) {
                playFromHereButton(entry, bm)
                showEpisodeButton(entry)
                Spacer(minLength: 0)
                ArmedDeleteControl(onDelete: { store.deleteBookmark(entry, id: bm.id) },
                                   help: "Remove bookmark")
            }
        }
        .padding(Spacing.md)
        .background(RoundedRectangle(cornerRadius: Radius.md)
            .fill(isExpanded ? Tokens.surfActive : Tokens.bg2.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: Radius.md)
            .stroke(isExpanded ? Tokens.accent.opacity(0.35) : Tokens.border))
        .animation(Motion.springy, value: isExpanded)
    }

    /// Play the episode from the bookmark's position — explicit, so a tap never
    /// hijacks current playback by accident. playAndSeek loads the entry if it
    /// isn't already active, then seeks once it's ready.
    private func playFromHereButton(_ entry: VoiceEntry, _ bm: Bookmark) -> some View {
        Button(action: { player.playAndSeek(entry, toFraction: bm.position) }) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "play.fill").font(.system(size: 11))
                Text("Play from here").font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(Tokens.accent)
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.accent.opacity(0.5)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Play this episode from the bookmark position")
    }

    /// Jump to the episode's card in the history list (revealInList leaves the
    /// Bookmarks view and clears any filter that hides it).
    private func showEpisodeButton(_ entry: VoiceEntry) -> some View {
        Button(action: { store.revealInList(entry.id) }) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 11))
                Text("Show episode")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(Tokens.muted)
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.borderStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this episode in the list")
    }
}
