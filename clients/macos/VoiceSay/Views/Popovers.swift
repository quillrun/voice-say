// Popovers — the per-row bookmark popover: a bookmark list scoped to one
// entry, anchored on the row's bookmark badge. Click an item to expand the
// parent card and scroll to it (via store.activate(entry.id)).

import SwiftUI

/// "Load more on scroll" sentinel — placed after the last rendered row of a
/// windowed list. When it scrolls into view it bumps the window (`onLoadMore`)
/// and shows a loading indicator while items remain. Reused by the history list
/// (batch 50) and the bookmarks dialog (batch 25).
struct LoadMoreSentinel: View {
    let hasMore: Bool
    let onLoadMore: () -> Void

    var body: some View {
        if hasMore {
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("loading more…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.dim)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.md)
            .onAppear { onLoadMore() }
        }
    }
}

// Per-row bookmark popover — same data, scoped to one entry. Anchored
// on the bookmark badge in diffstatRow.

struct RowBookmarksPopover: View {
    @Environment(HistoryStore.self) var store
    let entry: VoiceEntry
    let bookmarks: [Bookmark]
    let totalSeconds: Int
    let onJump: (Bookmark) -> Void

    var body: some View {
        let sorted = bookmarks.sorted { $0.position < $1.position }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Tokens.warn)
                Text("BOOKMARKS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .kerning(0.8).foregroundStyle(Tokens.warn)
                Spacer()
                Text(sorted.count.formatted())
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.dim)
            }
            .padding(.horizontal, Spacing.md).padding(.top, Spacing.md).padding(.bottom, Spacing.sm)
            Divider().background(Tokens.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(sorted) { bm in
                        HStack(spacing: 0) {
                            Button(action: { onJump(bm) }) {
                                HStack(spacing: Spacing.sm) {
                                    Text(bookmarkTimestamp(bm, totalSeconds: totalSeconds))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Tokens.warn)
                                    Text(bm.note.isEmpty ? "(no note)" : bm.note)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(bm.note.isEmpty ? Tokens.ultraDim : Tokens.muted)
                                        .italic(bm.note.isEmpty)
                                        .lineLimit(2)
                                    Spacer()
                                }
                                .padding(.leading, Spacing.lg).padding(.vertical, Spacing.sm).padding(.trailing, Spacing.xs)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            ArmedDeleteControl(onDelete: { store.deleteBookmark(entry, id: bm.id) }, help: "Remove bookmark")
                                .padding(.trailing, Spacing.xs)
                        }
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Tokens.border).frame(height: 1)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
        .frame(width: 320)
        .background(Tokens.bg)
    }
}

// ArmedDeleteControl — trash → inline confirm (red Delete + ×) so a
// destructive action takes two deliberate clicks instead of one. Self-armed
// (@State), so each row is independent. The single shared armed-delete control:
// used for bookmarks (here, PlayerPanel, TranscriptScreen) and for tag/category
// deletion in TaxonomyManageView — was three near-identical copies.

struct ArmedDeleteControl: View {
    let onDelete: () -> Void
    var help: String = "Delete"
    /// When set, the disarmed state shows a labelled del-outlined pill (trash +
    /// this text) instead of the bare trash glyph — for prominent destructive
    /// actions like the live-render Delete. The armed confirm reuses the label.
    var label: String? = nil
    /// Armed-confirm text when it should name the target ("Delete Field
    /// Notes") without giving the disarmed glyph a label.
    var confirmLabel: String? = nil
    @State private var armed = false

    var body: some View {
        if armed {
            HStack(spacing: Spacing.xs) {
                Button(action: { onDelete(); armed = false }) {
                    Text(confirmLabel ?? label ?? "Delete")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                        .background(Tokens.del).foregroundStyle(Tokens.bg)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                }
                .buttonStyle(.plain).help("Confirm — \(help)")
                Button(action: { armed = false }) {
                    Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Tokens.dim)
                        .frame(width: 20, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Cancel")
            }
        } else if let label {
            // Labelled disarmed pill (mirrors the old Discard button styling).
            Button(action: { armed = true }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "trash").font(.system(size: 11))
                    Text(label).font(.system(size: 11, design: .monospaced))
                }
                .fixedSize()
                .foregroundStyle(Tokens.del)
                .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.del.opacity(0.5)))
            }
            .buttonStyle(.plain).help(help)
        } else {
            Button(action: { armed = true }) {
                Image(systemName: "trash").font(.system(size: 11))
                    .foregroundStyle(Tokens.del.opacity(0.7))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            // The glyph alone reads as "Bin"; say what it deletes.
            .buttonStyle(.plain).help(help).accessibilityLabel(help)
        }
    }
}

// TagDeleteControl — the trash on a tag row that deletes the tag TYPE
// everywhere. Not the inline arm above: this one strips the tag from every
// episode and the vocabulary with no undo, so it asks through a system
// confirmation that names the tag and its reach (hig/feedback.md › Best
// practices: warn before unexpected, irreversible data loss). Same title as
// the sidebar's "Delete tag everywhere…" (Sidebar.deleteTagTitle).

struct TagDeleteControl: View {
    let tag: String
    /// Episodes carrying the tag, read when the confirmation opens (a
    /// whole-history count, so not on every row render).
    let usage: () -> Int
    let onDelete: () -> Void
    @State private var pendingCount: Int? = nil

    var body: some View {
        Button(action: { pendingCount = usage() }) {
            Image(systemName: "trash").font(.system(size: 11))
                .foregroundStyle(Tokens.del.opacity(0.7))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Delete #\(tag) from all episodes")
        .accessibilityLabel("Delete #\(tag) from all episodes")
        .confirmationDialog(
            pendingCount.map { Sidebar.deleteTagTitle(tag: tag, count: $0) } ?? "",
            isPresented: Binding(get: { pendingCount != nil },
                                 set: { if !$0 { pendingCount = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete #\(tag)", role: .destructive) { onDelete() }
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text("It comes off all episodes and out of the tag list. This can't be undone.")
        }
    }
}

// ContinueRenderButton — "Continue render" CTA for a save-and-stop draft
// that still has un-rendered text (POST /episode/resume merges the remainder
// into ONE complete render, superseding the draft server-side). Shared by the
// inline PlayerPanel.controls AND the full-screen TranscriptScreen reader so a
// draft can be resumed from either surface. Renders nothing for a non-draft.

struct ContinueRenderButton: View {
    @Environment(HistoryStore.self) private var store
    @Environment(RenderQueue.self) private var queue
    @Environment(UIRouter.self) private var router
    let entry: VoiceEntry

    var body: some View {
        if entry.isResumableDraft {
            // Already queued / in flight → show a disabled "Queued" state so the
            // same draft can't be stacked into the queue repeatedly (the inline
            // button is always visible now). The enqueue() path also dedupes as
            // the hard guard.
            let queued = queue.hasResume(forTS: entry.ts)
            Button(action: {
                guard !queued else { return }
                // Route through the queue so the resume serializes with any
                // in-flight render (two render POSTs at once would clobber the
                // single streamingEpisode). backend/voice are display-only —
                // the daemon resumes with the draft's original settings.
                queue.enqueue(RenderJob(source: .resume(fromTS: entry.ts),
                                        backendID: entry.backend,
                                        voice: entry.voice ?? "default",
                                        title: entry.derivedTitle(),
                                        // Display only, like backend/voice: the
                                        // daemon carries the draft's own overlay.
                                        overlay: RenderOverlay(title: entry.overlay?.title,
                                                               series: entry.overlay?.series,
                                                               episode: entry.overlay?.episode)))
                store.selectRenderingCategory()
                router.closeToList()
            }) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: queued ? "checkmark" : "play.fill")
                    Text(queued ? "Queued" : "Continue render")
                }
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs)
                .background(queued ? Tokens.brand.opacity(0.3) : Tokens.brand)
                .foregroundStyle(queued ? Tokens.brand : Tokens.bg)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            }
            .buttonStyle(.plain)
            .disabled(queued)
            .help(queued ? "This draft is already in the render queue"
                  : "Render the remaining text and merge into one complete render")
        }
    }
}

