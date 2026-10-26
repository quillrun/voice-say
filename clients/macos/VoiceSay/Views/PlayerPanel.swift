// PlayerPanel — the expanded active commit. Player + transport + bookmarks
// + tag manager.

import SwiftUI

struct PlayerPanel: View {
    @Environment(HistoryStore.self) var store
    @Environment(AudioPlayer.self) var player
    @Environment(UIRouter.self) var router

    let entry: VoiceEntry

    @State private var addingBookmark: Bool = false
    @State private var bookmarkNote: String = ""
    /// Play-head fraction FROZEN when "add bookmark" is tapped, so the saved
    /// position is the timestamp when you set it — not where playback drifted to
    /// while the note was typed.
    @State private var bookmarkFraction: Double = 0
    // Per-bookmark inline note editor. `nil` = no row is being edited;
    // otherwise holds the bookmark id whose note is currently editable.
    @State private var editingNoteFor: String? = nil
    @State private var editingNoteText: String = ""
    @State private var confirmingDelete: Bool = false
    // Drives the reused per-entry bookmarks dialog (RowBookmarksPopover) — the
    // SAME dialog component the sidebar Library "Bookmarks" row opens, scoped to
    // this entry. Replaces having a third hand-rolled inline list as the source
    // of truth; the inline list below is now just a preview.
    @State private var bookmarksDialogOpen: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            playerStrip
            controls
            if addingBookmark { addBookmarkRow }
            bookmarksList
            tagManager
        }
        .padding(.top, Spacing.md)
        .overlay(alignment: .top) {
            Rectangle()
                .strokeBorder(Tokens.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(height: 1)
                .clipShape(Rectangle())
        }
        // .task(id:) fires both on appear AND when entry.id changes —
        // one modifier replaces the onAppear + onChange pair. The
        // transcript is served inline (entry.text); no async load needed.
        .task(id: entry.id) {
            // Switching to a different expanded row resets any pending
            // transient state so the user's mid-edit text never
            // gets accidentally applied to the new row.
            confirmingDelete = false
            addingBookmark = false
            bookmarkNote = ""
            editingNoteFor = nil
            editingNoteText = ""
        }
        // ⌘⌫ from PlaybackKeys, aimed at this (expanded) row.
        .onChange(of: router.trashRequest) { _, req in
            guard req?.entryID == entry.id,
                  !store.deletingKeys.contains(store.tagKey(for: entry)) else { return }
            confirmingDelete = true
        }
        // Dialog anchored at the panel root so it opens even when the trash
        // button itself is scrolled offscreen.
        .confirmationDialog(
            "Move this render to Trash?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                // Stop playback first so we're not trashing a file that
                // AVAudioPlayer still holds open.
                if player.activeEntry?.id == entry.id { player.stop() }
                Task { await store.trashEntry(entry) }
            }
            .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.cancelAction)
        } message: {
            Text("Audio file will be moved to Trash. The render row is removed from the store.")
        }
    }


    private var playerStrip: some View {
        HStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                skipButton(direction: -1)
                playButton
                skipButton(direction: +1)
            }
            waveform
            timeBlock
        }
    }

    /// Prev/next card transport — walks the visible (filtered) list order,
    /// skipping rows with missing audio. The target starts playing and its
    /// list row is expanded + scrolled into view, so the panel follows.
    private func skipButton(direction: Int) -> some View {
        let target = store.playableNeighbor(of: entry.id, direction: direction)
        return Button(action: {
            guard let target else { return }
            player.play(target)
            store.activate(target.id)
            store.markSeenIfNew(target.id)
        }) {
            Image(systemName: direction < 0 ? "backward.end.fill" : "forward.end.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.muted)
                .frame(width: 26, height: 26)
                .overlay(Circle().stroke(Tokens.borderStrong))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .opacity(target == nil ? 0.35 : 1.0)
        .help(direction < 0 ? "Previous card in list" : "Next card in list")
        .accessibilityLabel(direction < 0 ? "Previous render" : "Next render")
    }

    private var playButton: some View {
        Button(action: { player.play(entry) }) {
            ZStack {
                Circle()
                    .fill(Tokens.accent)
                    .frame(width: 38, height: 38)
                    .shadow(color: Tokens.accent.opacity(0.3), radius: 5, y: 1)
                if isLoadingThis {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Tokens.bg)
                } else {
                    Image(systemName: isThisPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Tokens.bg)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(playButtonDisabled)
        .opacity(playButtonDisabled ? 0.4 : 1.0)
        .help(resumeHelpText)
        .accessibilityLabel(isThisPlaying ? "Pause" : "Play")
    }

    private var playButtonDisabled: Bool {
        entry.resolvedAudioURL() == nil || isLoadingThis
    }

    private var isLoadingThis: Bool {
        player.loadingEntryID == entry.id
    }

    private var resumeHelpText: String {
        if let p = entry.progress, p.playedS > 1, p.playedS < (p.durationS - 2) {
            return "Resume at \(fmtDuration(Int(p.playedS)))"
        }
        if entry.progress?.completed == true {
            return "Played to end — restarts on play"
        }
        return "Play"
    }

    private var waveform: some View {
        let rowBookmarks = store.bookmarksFor(entry)
        // A resumable draft's audio file is only the rendered prefix. Map the
        // played head, bookmarks, and seek onto the FULL-draft timeline and dim
        // the un-rendered remainder (amber frontier at draftFrac) so the
        // visualizer shows how much of the draft has been rendered. nil draftFrac
        // → a normal entry, byte-identical to before.
        let map = entry.draftSeekMap   // shared draft↔audio math (VoiceEntry)
        let played = map.played(progressFraction)
        let marks = map.marks(rowBookmarks)
        return WaveformView(
            audioURL: entry.resolvedAudioURL(),
            seed: entry.id,
            playedFraction: played,
            renderedFraction: entry.draftRenderedFraction,
            bookmarks: marks,
            bookmarkHelp: { bm in
                // bm.position is in full-draft space for a draft — un-scale it
                // back to the audio timeline before mapping to a timestamp.
                return bookmarkHelp(Bookmark(id: bm.id, position: map.audioPos(bm.position), note: bm.note),
                                    totalSeconds: displayDuration)
            },
            showBuffering: false,
            isPlaying: isThisPlaying,
            onSeek: { f in
                player.playAndSeek(entry, toFraction: map.seekTarget(f))
            }
        )
    }

    // Elapsed / total · "<n> left" playback countdown — shared TimeReadout
    // ("<n> left" renamed from the ambiguous "Remaining:" — #8).
    private var timeBlock: some View {
        TimeReadout(current: Int(currentSeconds), total: displayDuration, showRemaining: true)
    }

    // Playback accessors → shared AudioPlayer helpers (same math the reader uses).
    private var currentSeconds: TimeInterval { player.playedSeconds(of: entry) }
    private var displayDuration: Int { player.displayDuration(of: entry) }
    private var progressFraction: Double { player.progressFraction(of: entry) }

    private var isThisPlaying: Bool {
        player.activeEntry?.id == entry.id && player.isPlaying
    }




    private var controls: some View {
        HStack(spacing: Spacing.sm) {
            // Continue render — only for a save-and-stop draft that still has
            // un-rendered text. Renders the remainder and merges it into ONE
            // complete render (the draft is superseded server-side). Filled
            // Tokens.brand orange (the draft-action hue) + high-contrast fill
            // distinguishes it from the blue accent CTAs.
            ContinueRenderButton(entry: entry)

            ctrlButton("plus", "add bookmark") {
                bookmarkFraction = progressFraction
                addingBookmark = true
                bookmarkNote = ""
            }
            .disabled(addingBookmark || store.deletedKeys.contains(store.tagKey(for: entry)))

            // Star is now a single inline toggle on the card stat line
            // (alongside Edit Tags), not duplicated here.

            if let url = entry.resolvedAudioURL() {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }) {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: "folder")
                        Text("Show in Finder")
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.borderStrong))
                    .foregroundStyle(Tokens.muted)
                }
                .buttonStyle(.plain)
            }

            if store.deletedKeys.contains(store.tagKey(for: entry)) {
                // Restore only works for soft-deleted rows that still
                // have their on-disk files. Hard delete (trashEntry)
                // moves the audio file; resolvedAudioURL returns
                // nil so the restored row would be unplayable. We still
                // show restore so a soft-deleted row (its overlay marked
                // deleted while the audio stayed) can come back — the play
                // button itself disables on missing audio.
                ctrlButton("arrow.uturn.backward", "restore") { store.restore(entry) }
            } else {
                let deleting = store.deletingKeys.contains(store.tagKey(for: entry))
                Button(action: { confirmingDelete = true }) {
                    HStack(spacing: Spacing.sm) {
                        if deleting {
                            ProgressView().controlSize(.small).tint(Tokens.del)
                        } else {
                            Image(systemName: "trash")
                        }
                        Text(deleting ? "trashing…" : "delete")
                    }
                    .font(.system(size: 11.5, design: .monospaced))
                    .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.del.opacity(0.4)))
                    .foregroundStyle(Tokens.del)
                }
                .buttonStyle(.plain)
                .disabled(deleting)
                // ⌘⌫ (Finder's "Move to Trash") is handled by PlaybackKeys,
                // which yields to a focused text field and fires only while
                // the list is in front — see .onChange(of: router.trashRequest).
                .help("Move to Trash (⌘⌫) — files are recycled, row hides")
            }
        }
    }

    private func ctrlButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: 11.5, design: .monospaced))
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.borderStrong))
            .foregroundStyle(Tokens.muted)
        }
        .buttonStyle(.plain)
    }


    private var addBookmarkRow: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "bookmark.fill").foregroundStyle(Tokens.warn).font(.system(size: 11))
            Text(fmtDuration(Int((bookmarkFraction * Double(displayDuration)).rounded())))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.warn)
            TextField("Add a note (optional)…", text: $bookmarkNote)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .onSubmit { confirmBookmark() }
            Button("save") { confirmBookmark() }
                .buttonStyle(.plain)
                .accentPill(vertical: Spacing.xs)
            Button(action: { addingBookmark = false; bookmarkNote = "" }) {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(Tokens.dim)
            .help("Cancel")
            .accessibilityLabel("Cancel bookmark")
        }
        .bookmarkComposerChrome()
    }

    private func confirmBookmark() {
        // Use the fraction frozen at "add bookmark" — NOT the live play-head,
        // which advanced while the note was typed.
        store.addBookmark(entry, position: bookmarkFraction, note: bookmarkNote.trimmingCharacters(in: .whitespaces))
        bookmarkNote = ""
        addingBookmark = false
    }

    private func commitNoteEdit(for bm: Bookmark) {
        let note = editingNoteText.trimmingCharacters(in: .whitespaces)
        store.updateBookmark(entry, id: bm.id, note: note)
        editingNoteFor = nil
        editingNoteText = ""
    }


    @ViewBuilder
    private var bookmarksList: some View {
        let bms = store.bookmarksSortedFor(entry)
        if !bms.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                // Shared header; opens the SAME reused dialog the sidebar
                // Library "Bookmarks" opens (RowBookmarksPopover, per-entry).
                BookmarksSectionHeader(count: bms.count, dialogOpen: $bookmarksDialogOpen) {
                    RowBookmarksPopover(
                        entry: entry, bookmarks: bms, totalSeconds: displayDuration,
                        onJump: { bm in
                            // playAndSeek (not seek) so jumping from a NOT-
                            // active entry's bookmark loads THIS entry first
                            // rather than seeking whatever track is loaded.
                            player.playAndSeek(entry, toFraction: bm.position)
                            bookmarksDialogOpen = false
                        })
                        .environment(store)
                }
                ForEach(bms) { bm in
                    HStack(spacing: Spacing.sm) {
                        Button(action: { player.playAndSeek(entry, toFraction: bm.position) }) {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Tokens.warn)
                                Text(bookmarkTimestamp(bm, totalSeconds: displayDuration))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Tokens.warn)
                            }
                        }
                        .buttonStyle(.plain)
                        if editingNoteFor == bm.id {
                            TextField("note…", text: $editingNoteText)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5, design: .monospaced))
                                .onSubmit { commitNoteEdit(for: bm) }
                            Button("save") { commitNoteEdit(for: bm) }
                                .buttonStyle(.plain)
                                .accentPill()
                                .font(.system(size: 11, design: .monospaced))
                            Button(action: { editingNoteFor = nil; editingNoteText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Tokens.dim)
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            // Only while the list is in front: under Compose,
                            // Settings or the reader, Esc is their Back.
                            .keyboardShortcut(router.listInFront ? KeyboardShortcut.cancelAction : nil)
                            .help("Cancel (Esc)")
                        } else {
                            Button(action: {
                                editingNoteText = bm.note
                                editingNoteFor = bm.id
                            }) {
                                Text(bm.note.isEmpty ? "click to add a note" : bm.note)
                                    .font(.system(size: 12.5, design: .monospaced))
                                    .foregroundStyle(bm.note.isEmpty ? Tokens.ultraDim : Tokens.muted)
                                    .italic(bm.note.isEmpty)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(bm.note.isEmpty ? "Click to add a note" : "Click to edit note")
                        }
                        Spacer(minLength: 0)
                        // Two-click armed confirm — same control as the popovers,
                        // so a bookmark can't be lost to a single stray click.
                        ArmedDeleteControl(onDelete: { store.deleteBookmark(entry, id: bm.id) }, help: "Remove bookmark")
                    }
                    .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                }
            }
        }
    }


    private var tagManager: some View {
        // [★] [Tags & Category] on the first line; the applied tags flow on
        // the second row; the "Read transcript" CTA spans the full width on its
        // own bottom row so it reads as a card-level action rather than an
        // inline utility button.
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                starPill
                editTagsPill
                Spacer(minLength: 0)
            }
            inlineTags
            HStack {
                Spacer(minLength: 0)
                openButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inlineTags: some View {
        let allTags = store.tagsFor(entry)
        let maxShown = 4
        let shown = Array(allTags.prefix(maxShown))
        let extra = allTags.count - shown.count
        return HStack(spacing: Spacing.sm) {
            ForEach(shown, id: \.self) { t in appliedTagChip(t) }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tokens.dim)
                    .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs)
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.borderStrong))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Read transcript" — prominent bottom-right CTA for the expanded card
    ///. Full-width within its trailing HStack, taller padding and
    /// larger text so it reads as a card-level action rather than a utility
    /// link. Filled Tokens.accent with a Radius.md corner to match the card's
    /// own rounding family; shadow anchors it visually above the card floor.
    private var openButton: some View {
        Button(action: { router.open(.transcript(entry.id)) }) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 12, weight: .semibold))
                Text("Read transcript")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .opacity(0.75)
            }
            .foregroundStyle(Tokens.bg)
            .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm + 2)
            .frame(minWidth: 200)
            .background(Tokens.accent)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .shadow(color: Tokens.accent.opacity(0.35), radius: 6, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The key is Episode ▸ Read Transcript's (PlayerCommands), live only
        // while the list is in front.
        .help("Read the full transcript (⌘Y)")
    }

    /// Single star toggle, inline with Edit Tags.
    private var starPill: some View {
        let isStar = store.starred.contains(store.tagKey(for: entry))
        return Button(action: { store.toggleStar(entry) }) {
            Image(systemName: isStar ? "star.fill" : "star")
                .font(.system(size: 12))
                .foregroundStyle(isStar ? Tokens.warn : Tokens.muted)
                .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.borderStrong))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isStar ? "Starred — click to unstar" : "Star this render")
        // Same name as the collapsed card's star: unlabelled, VoiceOver read
        // the symbol's own name ("Favourite").
        .accessibilityLabel("Star")
        .accessibilityAddTraits(isStar ? .isSelected : [])
    }

    /// Opens the searchable tag + category dialog (shared trigger button).
    private var editTagsPill: some View {
        TagsAndCategoryButton(action: { router.openTagDialog(for: entry.id) }, tone: Tokens.borderStrong)
    }

    private func appliedTagChip(_ t: String) -> some View {
        AppliedTagChip(entry: entry, tag: t)   // shared with the transcript reader
    }

    // The inline collapsible transcript was removed — the full transcript
    // now opens in the dedicated full-screen TranscriptScreen reader, reached
    // from the always-visible "View transcript" button on the card stat line.

}
