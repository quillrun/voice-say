// CommitRow — git-log style row for one render. Title + preview is
// the click-to-expand zone; tagsLine + diffstatRow + the inline
// PlayerPanel live OUTSIDE the toggle button so their internal
// buttons receive clicks instead of the row-toggle eating them.

import SwiftUI
import AppKit

struct CommitRow: View {
    @Environment(HistoryStore.self) var store
    @Environment(AudioPlayer.self) var player
    @Environment(CategoryStore.self) var categories
    @Environment(UIRouter.self) var router

    /// Per-row bookmark popover binding. Anchored on the bookmark badge
    /// in diffstatRow so each card can open its own list without going
    /// through the global header popover.
    @State private var rowBookmarksOpen: Bool = false
    // Inline title editor — an edit button sits after the title when the row is
    // expanded; editing commits with Save (replaces the old "Set a title" row).
    @State private var editingTitle: Bool = false
    @State private var titleText: String = ""
    // Focus tracking for the inline title editor — losing focus (clicking
    // outside the field) commits the edit.
    @FocusState private var titleFieldFocused: Bool

    let entry: VoiceEntry
    let isExpanded: Bool
    let onToggle: () -> Void
    /// Rendering-context row — a paused-draft in the Rendering list. It opens the
    /// details screen on click instead of expanding inline, shows RENDER
    /// progress rather than playback (R2), and surfaces its resume + reveal
    /// actions inline (R3). Default false = an ordinary History row, unchanged:
    /// inline expand, playback progress (the P0 "no row-opens-reader" revert
    /// stands everywhere EXCEPT this rendering context).
    var renderingContext: Bool = false
    /// Non-nil only for the pinned card above the list: the loaded track,
    /// labelled "Now Playing" (playing) or "Last Played" (paused). nil for
    /// ordinary list rows — they get no corner tag and the plain border.
    var pinLabel: String? = nil

    private var isActiveInPlayer: Bool { player.activeEntry?.id == entry.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            headerLine
            // Rendering context: a paused-draft row opens the details screen
            // on click and never expands inline. History rows keep the inline
            // expand toggle.
            Button(action: { if renderingContext { router.open(.transcript(entry.id)) } else { onToggle() } }) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    titleLine
                    if !isExpanded, !strippedPreview.isEmpty { previewLine }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(renderingContext ? "Open details" : pinLabel != nil ? "Show in list" : "")
            diffstatRow
            if renderingContext {
                renderingActions
            } else if isExpanded {
                PlayerPanel(entry: entry)
            } else if pinLabel != nil {
                // Pinned Now-Playing / Last-Played card: always-visible
                // transport — prev · play/pause · next — like the expanded
                // card, instead of a lone play button jammed in the header.
                pinnedTransport
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Each render is a self-contained card: padded, rounded, bordered, with
        // gaps between cards (ContentView's LazyVStack spacing). The expanded
        // card gets an accent border + brighter fill. The pinned card (pinLabel
        // != nil) floats over the list in regular Liquid Glass (regular, not
        // clear: text-heavy — hig/materials.md › Liquid Glass) with no fill or
        // border of its own, plus a "Now Playing / Last Played" tag straddling
        // its top-left edge. The row loaded in the player keeps a
        // highlighted border IN the list too (border only, fill unchanged) —
        // full accent while playing, dimmed accent while paused.
        .padding(Spacing.md)
        .background {
            if pinLabel == nil {
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(isExpanded ? Tokens.surfActive : Tokens.bg2.opacity(0.35))
                    .overlay(RoundedRectangle(cornerRadius: Radius.md)
                        .stroke(isActiveInPlayer ? (player.isPlaying ? Tokens.accent : Tokens.accent.opacity(0.55))
                                : (isExpanded ? Tokens.accent.opacity(0.35) : Tokens.border),
                                lineWidth: isActiveInPlayer ? 1.5 : 1))
            }
        }
        .glassEffect(pinLabel != nil ? .regular : .identity,
                     in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(alignment: .topLeading) {
            if let pinLabel {
                Text(pinLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, Spacing.xs).padding(.vertical, 1)
                    .background(Tokens.accent, in: RoundedRectangle(cornerRadius: Radius.sm))
                    .foregroundStyle(Tokens.bg)
                    .padding(.leading, Spacing.md)
                    .offset(y: -7)   // straddle the top border (legend style)
            }
        }
        // Spring the expand/collapse: PlayerPanel reveal, card fill + border change.
        .animation(Motion.springy, value: isExpanded)
        .contextMenu { addToCategoryMenu }
    }

    /// Right-click → "Add to category". Adds the category's backing tag to
    /// this entry via the existing overlay-tag write (durable, cross-surface).
    /// Categories the entry is already in show a checkmark and are disabled.
    @ViewBuilder
    private var addToCategoryMenu: some View {
        let current = Set(store.tagsFor(entry))
        // Only tag-backed buckets — "add to category" works by adding the
        // backing tag; kind-backed categories (Says) and History have none.
        let buckets = categories.categories.filter { $0.tag != nil }
        Menu("Add to category") {
            if buckets.isEmpty {
                Text("No categories yet")
            } else {
                ForEach(buckets) { cat in
                    let inIt = cat.tag.map { current.contains($0) } ?? false
                    Button {
                        if let tag = cat.tag { store.addTag(entry, tag) }
                    } label: {
                        if inIt { Label(cat.name, systemImage: "checkmark") }
                        else { Text(cat.name) }
                    }
                    .disabled(inIt)
                }
            }
        }
    }

    private var headerLine: some View {
        // voice ……… date-created. The relative time moved to its own flush-left
        // row beneath the summary (item 3). Backend shows as the voice's accent
        // colour (the git hash + model badge were removed).
        let accent = Backends.find(id: entry.backend).map { Color(hex: $0.accent) } ?? Tokens.muted
        let voiceLabel = (entry.voice?.isEmpty == false) ? entry.voice! : entry.backend
        return HStack(spacing: Spacing.sm) {
            // One date: relative, the exact time on hover.
            Text(fmtRel(entry.ts))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Tokens.warn)
                .help(fmtDate(entry.ts))
            if let series = entry.seriesLabelIfNotInTitle {
                Text(series)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tokens.accent)
                    .lineLimit(1)
            }
            // Voice + model only when they differ from the configured
            // defaults — on most rows they'd repeat the same two words.
            if !isDefaultVoice {
                Text(voiceLabel)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(accent)
                // Model/backend name next to the voice. Skipped when voice was empty
                // (voiceLabel already IS the backend then — avoids "qwen3 qwen3").
                if entry.voice?.isEmpty == false {
                    Text(entry.backend)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Tokens.ultraDim)
                }
            }
            if store.deletedKeys.contains(store.tagKey(for: entry)) {
                refBadge("deleted", color: Tokens.del, fill: Color.clear)
            }
            Spacer(minLength: Spacing.sm)
            // (The pinned card's transport moved OUT of this cramped header
            // corner into its own always-visible row beneath the stats — see
            // `pinnedTransport`, item #1.)
        }
    }

    /// True when the row used the configured default backend + voice (then
    /// the header leaves both out). Unknown defaults → show them.
    private var isDefaultVoice: Bool {
        let cfg = AppConfig.shared
        guard let be = cfg.defaultBackend else { return false }
        let dv = cfg.defaultVoice ?? Backends.find(id: be)?.defaultVoice
        return entry.backend == be && (entry.voice ?? "") == (dv ?? "")
    }

    private func refBadge(_ label: String, color: Color, fill: Color) -> some View {
        Text(label)
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, Spacing.xs).padding(.vertical, Spacing.xxs)
            .background(fill)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(color.opacity(0.4)))
            .foregroundStyle(color)
    }

    private var titleLine: some View {
        HStack(spacing: Spacing.sm) {
            if isExpanded && editingTitle {
                // Editing: pre-filled with the current title (edit, don't retype),
                // accent-tinted + outlined so it reads as "in edit mode".
                TextField("title…", text: $titleText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Tokens.accent)
                    .focused($titleFieldFocused)
                    .onSubmit { commitTitle() }
                    .onChange(of: titleFieldFocused) { _, focused in
                        // Click-outside (focus loss) commits — unless we're
                        // mid-cancel (cancel-X clears editingTitle first).
                        if !focused && editingTitle { commitTitle() }
                    }
                    .padding(.horizontal, Spacing.xs).padding(.vertical, Spacing.xxs)
                    .background(Tokens.accent.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.accent.opacity(0.5)))
                Button("save") { commitTitle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .accentPill()
                Button(action: { editingTitle = false; titleText = ""; titleFieldFocused = false }) {
                    Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Tokens.dim)
                }
                .buttonStyle(.plain).help("Cancel")
            } else {
                Text(entry.derivedTitle())
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                    .strikethrough(store.deletedKeys.contains(store.tagKey(for: entry)), color: Tokens.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Pencil floats LEFT, directly next to the title.
                if isExpanded {
                    Button(action: beginTitleEdit) {
                        Image(systemName: "pencil").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Tokens.accent)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Edit title")
                }
                Spacer(minLength: 0)
            }
        }
        // Collapsing the row removes the field without a commit; don't leave
        // the editor armed for the next expand.
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { editingTitle = false; titleText = "" }
        }
    }

    private func beginTitleEdit() {
        // Prefill with the CURRENTLY SHOWN title (the derived title when there's
        // no overlay title yet) so editing starts from it instead of a blank
        // field the user has to retype.
        titleText = entry.derivedTitle()
        editingTitle = true
        // Focus a tick later, once the TextField has mounted to receive it.
        DispatchQueue.main.async { titleFieldFocused = true }
    }

    private func commitTitle() {
        store.setTitle(entry, titleText)
        editingTitle = false
        titleText = ""
    }

    private var previewLine: some View {
        Text(strippedPreview)
            .font(.system(size: 13))
            .foregroundStyle(Tokens.muted)
            .lineLimit(2)
    }

    private var strippedPreview: String {
        VoiceEntry.preview(of: entry.text ?? "", title: entry.derivedTitle())
    }

    private var diffstatRow: some View {
        let rowBookmarks = store.bookmarksFor(entry)
        // Rendering context (R2) shows RENDER progress — how much of the draft
        // has been rendered to audio — in the brand/draft hue. History shows
        // playback progress (accent), turning green once complete.
        let useRenderProgress = renderingContext
        let frac = useRenderProgress ? renderedFraction : rowProgressFraction
        let tags = store.tagsFor(entry)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                // Leading stats — star FIRST (collapsed-only quick access; the
                // expanded PlayerPanel carries its own), then clock · played/
                // time-left · speed · bookmark count. Content-hugging so the tag
                // strip gets the remaining width.
                HStack(spacing: Spacing.sm) {
                    if !isExpanded { starButton }
                    Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Tokens.dim)
                    durationView
                    if useRenderProgress {
                        Text("·").foregroundStyle(Tokens.ultraDim)
                        Text("\(min(99, Int(renderedFraction * 100)))% rendered").foregroundStyle(Tokens.brand)
                    }
                    if let s = entry.speed, s != 1.0 {
                        Text("·").foregroundStyle(Tokens.ultraDim)
                        Text(fmtSpeed(s))
                            .foregroundStyle(Tokens.dim)
                    }
                    if !rowBookmarks.isEmpty {
                        Text("·").foregroundStyle(Tokens.ultraDim)
                        bookmarksBadge(rowBookmarks)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .fixedSize()
                // Inline tags after the duration, filling to the card's trailing
                // edge; overflow collapses into a "+N" chip that expands to a
                // wrapped multi-row block (and back) — collapsed rows only.
                if !isExpanded && !tags.isEmpty {
                    InlineTagStrip(tags: tags)
                } else {
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, Spacing.sm)   // +8px above & below the stat line
            // Per-row PROGRESS visualizer — collapsed / rendering rows only (the
            // expanded PlayerPanel waveform owns progress + bookmarks). In the
            // rendering context the fill is RENDER progress in the brand hue; in
            // History it encodes playback STATE: a fully-rendered ("complete")
            // render is GREEN — track + fill — so "done" reads at a glance even
            // unplayed; an in-progress render uses the main accent.
            if !isExpanded && (entry.bestDurationS() > 0 || !rowBookmarks.isEmpty || rowListened || useRenderProgress) {
                // Playback-state coloring: GRAY track = unplayed; the ACCENT
                // fill grows with play position; once the row has been LISTENED
                // (played to ≥90% or finished) it flips GREEN, marking "already
                // heard" without a manual #completed tag. The fill stays the real
                // position (a finished play saves it at the end, so it reads full;
                // a replay shows where it stands, matching the "x left" text).
                // Rendering rows keep their brand-hue render-progress bar.
                let listened = !useRenderProgress && rowListened
                let trackColor = listened ? Tokens.add.opacity(0.22) : Tokens.borderStrong.opacity(0.5)
                let fillColor  = useRenderProgress ? Tokens.brand : (listened ? Tokens.add : Tokens.accent)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(trackColor)
                            .frame(height: 4)
                        if frac > 0 {
                            Rectangle()
                                .fill(fillColor)
                                .frame(width: max(2, geo.size.width * frac), height: 4)
                        }
                        // Bookmark markers — only on the playback bar (the render
                        // bar's axis is chars rendered, not playback time).
                        if !useRenderProgress {
                            ForEach(rowBookmarks) { bm in
                                BookmarkPip()
                                    .offset(x: geo.size.width * bm.position - 1.5, y: -3)
                                    .help(bookmarkHelp(bm, totalSeconds: Int(entry.bestDurationS())))
                                    .onTapGesture { jumpTo(bm) }
                            }
                        }
                    }
                }
                .frame(height: 4)
            }
        }
    }

    // Star + Edit Tags + the transcript Open button moved into the expanded
    // PlayerPanel; the collapsed stat line keeps duration · bookmarks.

    /// Enhanced duration: <played> / <total> · <n> left while there's progress;
    /// bare total otherwise — played in text colour, the rest dim. "<n> left" is
    /// the playback countdown (renamed from the ambiguous "Remaining:", which
    /// read as time-until-render-complete — #8). When the row is expanded the
    /// PlayerPanel timeBlock owns the live readout, so the collapsed stat line
    /// shows only the bare total (no duplicate).
    @ViewBuilder
    private var durationView: some View {
        // For the active entry use the live player duration (same denominator the
        // expanded panel uses) so played (live currentTime) and total share one
        // source — otherwise "N left" can freeze at 0:00 when the live audio
        // duration differs from the stored duration.
        let total = isActiveInPlayer ? player.displayDuration(of: entry) : Int(entry.bestDurationS())
        let played = currentPlayedSeconds
        if played > 0 && total > 0 && !isExpanded {
            TimeReadout(current: played, total: total, showRemaining: true,
                        playedColor: Tokens.text,
                        font: .system(size: 11, design: .monospaced),
                        separatorColor: Tokens.dim, spacing: Spacing.sm)
        } else {
            Text(fmtDuration(total)).foregroundStyle(Tokens.text)
        }
    }

    /// Inline badge next to the diffstat that opens a per-row popover
    /// listing every bookmark on this entry. Click on a row in the
    /// popover plays the entry and seeks to that bookmark.
    // MARK: - Stat-line badges

    private func bookmarksBadge(_ bms: [Bookmark]) -> some View {
        Button(action: { rowBookmarksOpen.toggle() }) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 11))
                Text("\(bms.count)")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(Tokens.warn)
        }
        .buttonStyle(.plain)
        .help("\(bms.count) bookmark\(bms.count == 1 ? "" : "s") — click to list")
        .popover(isPresented: $rowBookmarksOpen, arrowEdge: .top) {
            RowBookmarksPopover(entry: entry, bookmarks: bms,
                                totalSeconds: Int(entry.bestDurationS()),
                                onJump: { bm in jumpTo(bm); rowBookmarksOpen = false })
                .environment(store)
        }
    }

    /// Jump to a bookmark: seek the loaded entry, or load this one at the
    /// mark. (play() toggles an entry that's already playing, so the old
    /// play-then-seek paused it instead.) Bookmark positions are audio
    /// fractions — no draft mapping.
    private func jumpTo(_ bm: Bookmark) {
        player.playAndSeek(entry, toFraction: bm.position)
    }

    /// Current playback position for this row — live for the active entry,
    /// persisted progress for everyone else. Returns 0 when unknown.
    private var currentPlayedSeconds: Int {
        if isActiveInPlayer { return Int(player.currentTime) }
        if let p = entry.progress { return Int(p.playedS) }
        return 0
    }

    private var rowProgressFraction: Double {
        let total = entry.bestDurationS()
        guard total > 0 else { return 0 }
        let played = Double(currentPlayedSeconds)
        return min(1.0, max(0, played / total))
    }

    /// True when this render is fully RENDERED (not a resumable draft). One
    /// source of truth in HistoryStore (shared with the New inbox + the
    /// render→History transition). NOTE: this is render-completeness, NOT
    /// playback — the green "already heard" bar keys off `rowListened`.
    private var isComplete: Bool { store.isComplete(entry) }

    /// True when this row has been LISTENED to completion — sticky once the
    /// daemon's playback `completed` latch is set (≥90% or end), plus a live
    /// ≥90% check for the row currently playing so the bar greens the instant
    /// you cross the threshold (before the progress POST round-trips). Drives
    /// the green bar + the virtual #completed tag; DISTINCT from `isComplete`.
    private var rowListened: Bool {
        store.hasFinishedPlayback(entry) || (isActiveInPlayer && rowProgressFraction >= 0.9)
    }

    /// Render progress for a rendering-context (paused-draft) row: the fraction
    /// of the full draft text already rendered to audio. A complete render reads
    /// 1; a non-draft with no draft fraction reads 0.
    private var renderedFraction: Double {
        entry.draftRenderedFraction ?? (isComplete ? 1 : 0)
    }

    /// Rendering-context inline actions (R3) — since these rows no longer expand
    /// to a PlayerPanel, surface the two things a paused draft needs right on the
    /// row: Continue render (resume the remaining text) + Show in Finder. Both
    /// self-gate (Continue render only for a resumable draft; Finder only when
    /// the audio file resolves), so nothing shows for a row with neither.
    @ViewBuilder private var renderingActions: some View {
        HStack(spacing: Spacing.sm) {
            ContinueRenderButton(entry: entry)
            showInFinderButton
            Spacer(minLength: 0)
            // Discard the draft — restores the delete affordance the expanded
            // PlayerPanel used to provide (these rows no longer expand).
            ArmedDeleteControl(
                onDelete: {
                    if player.activeEntry?.id == entry.id { player.stop() }
                    Task { await store.trashEntry(entry) }
                },
                help: "Discard this draft — move its audio to Trash",
                label: "Delete")
        }
        .padding(.top, Spacing.xxs)
    }

    @ViewBuilder private var showInFinderButton: some View {
        if let url = entry.resolvedAudioURL() {
            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "folder")
                    Text("Show in Finder")
                }
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.borderStrong))
                .foregroundStyle(Tokens.muted)
            }
            .buttonStyle(.plain)
            .help("Reveal the audio file in Finder")
        }
    }

    /// Star toggle for the collapsed card (the expanded PlayerPanel has its own).
    private var starButton: some View {
        let isStar = store.starred.contains(store.tagKey(for: entry))
        return Button(action: { store.toggleStar(entry) }) {
            Image(systemName: isStar ? "star.fill" : "star")
                .font(.system(size: 11))
                .foregroundStyle(isStar ? Tokens.warn : Tokens.muted)
                // 20×20 pt hit area around the 11 pt glyph: the macOS minimum
                // for a control (hig/accessibility.md › Mobility).
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isStar ? "Starred — click to unstar" : "Star this render")
        .accessibilityLabel("Star")
        .accessibilityAddTraits(isStar ? .isSelected : [])
    }

    // MARK: - Pinned-card transport

    /// Always-visible transport for the pinned Now-Playing / Last-Played card,
    /// mirroring the expanded PlayerPanel's playerStrip (prev · play/pause ·
    /// next) so the loaded track is controllable without expanding its list
    /// row — replacing the single play button that used to sit awkwardly in the
    /// header's top-right corner. The pinned card's `entry` IS the active track,
    /// and the live progress + played/total readout already render in
    /// `diffstatRow` above, so this row carries transport only.
    @ViewBuilder private var pinnedTransport: some View {
        HStack(spacing: Spacing.sm) {
            pinnedSkipButton(direction: -1)
            pinnedPlayButton
            pinnedSkipButton(direction: +1)
            Spacer(minLength: 0)
            showInListButton
        }
        .padding(.top, Spacing.xxs)
    }

    /// The pinned card's way back to its row: scrolls the list to it and
    /// expands it (ContentView's onToggle → revealInList, clearing any filter
    /// that hides it). Clicking the title does the same, but nothing says so.
    private var showInListButton: some View {
        Button(action: onToggle) {
            Label("Show in list", systemImage: "list.bullet.indent")
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Tokens.accent)
                .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.accent.opacity(0.5)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Scroll to this card in the list and open it")
    }

    /// Prev/next over the visible list order (skips missing-audio rows). Unlike
    /// the expanded panel's skip — which `activate`s the target so the panel
    /// follows — the pinned card stays put: it just plays the neighbour and lets
    /// the card re-bind to the new active track, never yanking the list.
    private func pinnedSkipButton(direction: Int) -> some View {
        let target = store.playableNeighbor(of: entry.id, direction: direction)
        return Button(action: {
            guard let target else { return }
            player.play(target)
            store.markSeenIfNew(target.id)
        }) {
            Image(systemName: direction < 0 ? "backward.end.fill" : "forward.end.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Tokens.muted)
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(Tokens.borderStrong))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(target == nil)
        .opacity(target == nil ? 0.35 : 1.0)
        .help(direction < 0 ? "Previous card in list" : "Next card in list")
        .accessibilityLabel(direction < 0 ? "Previous render" : "Next render")
    }

    /// Play/pause — `player.play(entry)` toggles when the entry is already the
    /// active track (it always is for the pinned card). Filled accent circle,
    /// like the expanded card's playButton, one step smaller for the indicator.
    private var pinnedPlayButton: some View {
        Button(action: { player.play(entry) }) {
            ZStack {
                Circle()
                    .fill(Tokens.accent)
                    .frame(width: 32, height: 32)
                    .shadow(color: Tokens.accent.opacity(0.3), radius: 4, y: 1)
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.bg)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(player.isPlaying ? "Pause" : "Play")
        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
    }
}

/// Inline tag strip for a collapsed row's stat line. COLLAPSED: as many #tag
/// chips as fit on one line after the duration, capped at the card's trailing
/// edge, with a "+N" chip when they overflow. Tapping "+N" EXPANDS to a wrapped
/// multi-row block (FlowLayout) and turns the chip into a collapse control;
/// tapping that collapses back. Widths are measured exactly via NSFont (the app
/// is monospaced throughout), so the one-line fit is deterministic — no
/// measuring pass or fragile estimate. Available width comes from a clear
/// background GeometryReader.
struct InlineTagStrip: View {
    @Environment(HistoryStore.self) private var store
    let tags: [String]

    @State private var expanded = false
    @State private var availableWidth: CGFloat = 0

    private let chipSpacing = Spacing.xs
    private static let chipFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)

    var body: some View {
        Group {
            if expanded {
                FlowLayout(spacing: chipSpacing, lineSpacing: chipSpacing) {
                    ForEach(tags, id: \.self) { tagChip($0) }
                    toggleChip(label: nil, icon: "chevron.up") { expanded = false }
                }
            } else {
                let split = fit(in: availableWidth > 0 ? availableWidth : .greatestFiniteMagnitude)
                HStack(spacing: chipSpacing) {
                    ForEach(split.shown, id: \.self) { tagChip($0) }
                    if split.hidden > 0 {
                        toggleChip(label: "+\(split.hidden)", icon: nil) { expanded = true }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { availableWidth = geo.size.width }
                .onChange(of: geo.size.width) { _, w in availableWidth = w }
        })
    }

    private func tagChip(_ tag: String) -> some View {
        TagChip(tag: tag, onTap: { store.toggleTagFilter(tag) })
    }

    private func toggleChip(label: String?, icon: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.xxs) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                if let label { Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced)) }
            }
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs)
            .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Tokens.borderStrong, lineWidth: 1))
            .foregroundStyle(Tokens.muted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(icon == nil ? "Show all tags" : "Collapse tags")
    }

    /// Pixel width of one #tag chip: measured text + horizontal padding (Spacing.sm
    /// each side) + ~1px border each side, matching TagChip's recipe.
    private func chipWidth(_ tag: String) -> CGFloat {
        let textW = ("#\(tag)" as NSString).size(withAttributes: [.font: Self.chipFont]).width
        return ceil(textW) + 2 * Spacing.sm + 2
    }

    /// Worst-case "+N" chip width (reserve room so the count never gets clipped).
    private var plusChipWidth: CGFloat {
        let textW = ("+99" as NSString).size(withAttributes: [.font: Self.chipFont]).width
        return ceil(textW) + 2 * Spacing.sm + 2
    }

    /// Greedy one-line fit. If every chip fits, show them all (no "+N"); else fit
    /// as many as possible while reserving room for the trailing "+N" chip.
    private func fit(in width: CGFloat) -> (shown: [String], hidden: Int) {
        let totalAll = tags.enumerated().reduce(CGFloat(0)) { acc, e in
            acc + chipWidth(e.element) + (e.offset == 0 ? 0 : chipSpacing)
        }
        if totalAll <= width { return (tags, 0) }
        var used: CGFloat = 0
        var shown: [String] = []
        for tag in tags {
            let gap: CGFloat = shown.isEmpty ? 0 : chipSpacing
            if used + gap + chipWidth(tag) + chipSpacing + plusChipWidth <= width {
                used += gap + chipWidth(tag)
                shown.append(tag)
            } else { break }
        }
        return (shown, tags.count - shown.count)
    }
}

