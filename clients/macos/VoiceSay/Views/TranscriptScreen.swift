// TranscriptScreen — full-screen, ONE unified transcript reader used for BOTH
// a finished entry and a live render. A pinned nav header sits over a single
// shared ScrollView, so the whole details surface scrolls as one page. There
// is NO control sidebar: a finished entry stacks full-width blocks (a
// horizontal stat bar of 5 tiles — chars / words / pace / read-time / render-
// time, then a LIVE-READ seekable player, a bookmarks list with inline add,
// inline tags under the title, then the transcript body); a live render stacks
// the StreamingRenderControls bar + render legend over the 3-state transcript.
// Replaces the inline collapsible transcript in PlayerPanel.
//
// Reads transcript text from the already-inline `VoiceEntry.text` — no
// vault / sidecar / daemon access (UI-only pass).

import SwiftUI
import AppKit

struct TranscriptScreen: View {
    @Environment(HistoryStore.self) var store
    @Environment(AudioPlayer.self) var player
    @Environment(UIRouter.self) var router
    @Environment(CategoryStore.self) var categories
    @Environment(RenderQueue.self) var queue

    let entryID: String
    @AppStorage(ReaderType.key) private var readerSize = ReaderType.defaultSize

    @State private var copied = false
    @State private var addingBookmark = false
    @State private var bookmarkNote = ""
    /// Play-head fraction FROZEN the instant "+ add bookmark" is tapped, so the
    /// saved position is the timestamp when you set it — not where playback has
    /// drifted to by the time you finish typing the note.
    @State private var bookmarkFraction: Double = 0
    @State private var bookmarksDialogOpen = false
    // Inline title editor (moved here from the now-removed inline PlayerPanel).
    @State private var editingTitle = false
    @State private var titleText = ""
    @FocusState private var titleFocused: Bool
    // Cached transcript segments (paragraph/sentence units). Recomputing the
    // split on every 4 Hz progress tick of a long episode would be wasteful;
    // the split only depends on entry.text.
    @State private var cachedSegments: [Segment] = []
    @State private var cachedSegmentsForId: String = ""
    /// True while the reader is scrolled at (near) the very top — gates the
    /// go-to-top button visibility (hidden when atTop, shown otherwise).
    @State private var atTop = true
    /// Live-read follow toggle: when ON the scroll view tracks the active
    /// playback segment (auto-scrolls with the karaoke head). Persisted
    /// globally in UserDefaults so the preference survives restarts.
    @State private var liveReadFollow: Bool = UserDefaults.standard.bool(forKey: DefaultsKeys.liveReadFollow)
    /// ScrollViewReader anchor for the very top of the reader page.
    private static let topAnchorID = "reader-top"
    private static let readerScrollSpace = "reader-scroll"

    /// Reports the reader's top-anchor offset within the scroll's coordinate
    /// space, so the widget reliably knows whether we're at the top (a robust
    /// GeometryReader signal — onScrollGeometryChange proved unreliable here).
    private struct ReaderScrollTopKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
    }

    /// Reading segment — pure model, see Models/Transcript.swift.
    private typealias Segment = Transcript.Segment

    private var entry: VoiceEntry? { store.entries.first { $0.id == entryID } }

    /// Streaming mode — the transcript was opened for an in-progress render
    /// (entryID == the episode id, which has no saved row yet).
    private var streaming: StreamingEpisode? {
        store.streamingEpisode?.id == entryID ? store.streamingEpisode : nil
    }

    /// The reader's data source — a finished entry, a live render, OR a queued render preview. Lets the
    /// stat bar + transcript render through ONE code path; the player block switches engine
    /// internally and the finished-only blocks (bookmarks / tags) self-hide for
    /// a stream. Derived values for a live render use what an episode has
    /// (chars, fullText word count, predicted pace) — never a fabricated total.
    // @MainActor: paceText reads a live episode's MEASURED renderHeadS/renderedChars
    // (mutable @MainActor state) to self-calibrate the live pace; only ever used
    // from the main-actor view, so isolating the enum is safe.
    @MainActor
    private enum ReaderMode {
        case entry(VoiceEntry)
        case stream(StreamingEpisode)
        case queued(RenderJob)   // a fresh queued render — read-only text preview

        var charsValue: Int {
            switch self {
            case .entry(let e): return e.chars
            case .stream(let s): return s.chars
            case .queued(let j): return j.charCount
            }
        }
        var wordsValue: Int {
            switch self {
            case .entry(let e): return e.words
            case .stream(let s): return Self.wordCount(s.fullText)
            case .queued(let j): return Self.wordCount(j.freshText ?? "")
            }
        }
        /// Whitespace-token word count with inline [emotion]/<angle> markup
        /// stripped first — backends with emotion tags keep it in the text, so a raw
        /// split would over-count it as words. Markup strip is shared with
        /// VoiceEntry.derivedTitle via EmotionMarkup (the constrained angle arm
        /// leaves prose like "a < b" intact); also a coupled pair with the
        /// daemon's `_sinks.py` word-count.
        static func wordCount(_ t: String) -> Int {
            EmotionMarkup.stripped(t, replacement: " ")
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        }
        /// (value, unit) — duration-based wpm for a finished entry; an estimate
        /// from predictedTotalS (stream) / estDurationS (queued). Same "—" sentinel.
        var paceText: (String, String?) {
            switch self {
            case .entry(let e): return (e.wordsPerMinute > 0 ? "\(e.wordsPerMinute)" : "—", "wpm")
            case .stream(let s):
                // Prefer MEASURED pace once a chunk has rendered, so the live
                // wpm tracks the real voice instead of the chars/17.8 seed. Fall
                // back to the seed only before the first chunk. "~" — it
                // extrapolates over the un-rendered tail until episode_complete.
                let minutes = (s.estimatedTotalS ?? s.predictedTotalS) / 60.0
                let wpm = minutes > 0 ? Int((Double(wordsValue) / minutes).rounded()) : 0
                return (wpm > 0 ? "~\(wpm)" : "—", "wpm")
            case .queued(let j):
                // No measured signal yet — an honest estimate (chars/17.8), so "~".
                let m = (j.estDurationS ?? 0) / 60.0
                let wpm = m > 0 ? Int((Double(wordsValue) / m).rounded()) : 0
                return (wpm > 0 ? "~\(wpm)" : "—", "wpm")
            }
        }
        /// SILENT reading time in seconds (words / 230 wpm) — same basis as
        /// VoiceEntry.readSeconds, so the live/queued READ TIME tile means the same.
        var readSecondsValue: Double {
            switch self {
            case .entry(let e): return e.readSeconds
            case .stream, .queued: return VoiceEntry.readSeconds(words: wordsValue)
            }
        }
        var showsFinishedBlocks: Bool {
            if case .entry = self { return true }
            return false
        }
    }

    private var mode: ReaderMode? {
        if let e = entry { return .entry(e) }
        if let s = streaming { return .stream(s) }
        if let j = queuedJob { return .queued(j) }
        return nil
    }

    /// A fresh queued render opened from the up-next list (entryID == the job
    /// UUID). Resume jobs route to their source draft instead, so only fresh
    /// jobs resolve here.
    private var queuedJob: RenderJob? {
        (queue.jobs + queue.failed).first { $0.id.uuidString == entryID && $0.freshText != nil }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Tokens.bg.ignoresSafeArea()
            if let m = mode {
                reader(m)
            } else {
                missing
            }
        }
        .foregroundStyle(Tokens.text)
        .font(.system(.body, design: .monospaced))
        .task(id: entryID) {
            // Opening the reader marks a New-inbox render as seen.
            store.markSeenIfNew(entryID)
            refreshSegments()
        }
        // Streaming episode cleared. On a natural completion HistoryStore has
        // already swapped a reader open on that episode to the finished row's
        // .transcript (the live reader becomes the finished reader). Close only
        // a reader still routed to the episode that just ended (a save-and-stop
        // draft); a finished row, a queued-job preview or another episode's
        // reader stays put.
        .onChange(of: store.streamingEpisode?.id) { old, id in
            guard id == nil, let old else { return }
            if router.screen == .transcript(old) { router.closeToList() }
        }
    }

    /// ONE unified reader surface for BOTH a finished entry and a live render
    ///: a pinned nav header over a single shared ScrollView, so the whole
    /// surface scrolls as one page with the transcript's karaoke auto-scroll
    /// driving it. Only the mode-specific blocks differ — a finished entry shows
    /// stats / player / bookmarks / tags; a live render shows the transport+stop
    /// control bar + the render legend — while the chrome, the scroll, and the
    /// transcript rendering are shared. On episode_complete the router swaps this
    /// same screen onto the finished row, so the live reader literally becomes
    /// the details screen.
    private func reader(_ m: ReaderMode) -> some View {
        let segs = unifiedSegments
        let activeId = unifiedActiveId(segs)
        return VStack(spacing: 0) {
            unifiedHeader
            Divider().background(Tokens.border)
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        // ONE ordered block list for both modes — each block takes
                        // the ReaderMode and differs only by data/behaviour. The
                        // finished-only blocks (bookmarks / tags) are gated, not a
                        // parallel block set. Per-block wrappers (frame/padding/
                        // Divider) stay here so the finished layout is pixel-identical.
                        VStack(spacing: 0) {
                            // Top anchor: scroll-to-top target + reports its offset
                            // in the scroll space so the widget knows we're at top.
                            Color.clear.frame(height: 1).id(Self.topAnchorID)
                                .background(GeometryReader { g in
                                    Color.clear.preference(
                                        key: ReaderScrollTopKey.self,
                                        value: g.frame(in: .named(Self.readerScrollSpace)).minY)
                                })
                            statBar(m)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.md)
                            Divider().background(Tokens.border)
                            player(m)
                                .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.md)
                            Divider().background(Tokens.border)
                            if m.showsFinishedBlocks {
                                bookmarksSection(m)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.md)
                                Divider().background(Tokens.border)
                                inlineTagManager(m)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.md)
                                Divider().background(Tokens.border)
                            }
                            transcriptContent(segs)
                        }
                    }
                    .coordinateSpace(.named(Self.readerScrollSpace))
                    .onPreferenceChange(ReaderScrollTopKey.self) { y in
                        let top = y >= -8   // top anchor at/near the viewport top
                        if top != atTop { atTop = top }
                    }
                    .onChange(of: activeId) { _, id in
                        // A live render always follows (it has no toggle); a
                        // finished entry follows only when the toggle is on.
                        guard id >= 0, liveReadFollow || streaming != nil else { return }
                        withAnimation(Motion.standard) { proxy.scrollTo(id, anchor: .center) }
                    }
                    scrollNavStack(proxy: proxy, segs: segs)
                        .padding(.trailing, Spacing.xl)
                        .padding(.bottom, Spacing.xl)
                }
            }
        }
    }

    /// Lower-right floating widget stack:
    ///   (a) go-to-top (arrow.up) — hidden when already at top.
    ///   (b) jump-to-playhead (scope) — one-shot scroll to the current playback
    ///       position; shown only when a live read head exists.
    ///   (c) live-read follow toggle — auto-scrolls with the active playback
    ///       segment (karaoke highlight). Hidden during streaming reads. State
    ///       persisted in UserDefaults so it survives restarts.
    ///
    /// (b) keys off `unifiedActiveId` (gated on isActive + progressFraction>0)
    /// and is HIDDEN whenever that target is meaningless — reading
    /// `progressFraction` alone made it a silent "scroll to top".
    private func scrollNavStack(proxy: ScrollViewProxy, segs: [Segment]) -> some View {
        // Recomputed each body pass (unifiedActiveId reads player.currentTime),
        // so the jump button appears the instant playback gives a read position
        // and hides when idle.
        let showJump = Self.jumpToProgressVisible(isStreaming: streaming != nil,
                                                  activeId: unifiedActiveId(segs))
        return VStack(spacing: Spacing.sm) {
            // (a) Go-to-top — visible only when scrolled away from top.
            if Self.goToTopVisible(atTop: atTop) {
                Button {
                    withAnimation(Motion.standard) {
                        proxy.scrollTo(Self.topAnchorID, anchor: .top)
                    }
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tokens.bg)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Tokens.accent))
                        .overlay(Circle().stroke(Tokens.bg.opacity(0.25), lineWidth: 1))
                        .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                .help("Scroll to top")
                .accessibilityLabel("Scroll to top")
                .transition(.scale.combined(with: .opacity))
            }
            // (b) Jump-to-playhead — one-shot scroll to where playback is now.
            // Shown only when there's a live read position (the entry is playing
            // or paused mid-track), so it's never confused with go-to-top
            // (#6 "go to transcript where progress is at while playing").
            if showJump {
                Button {
                    let id = unifiedActiveId(segs)
                    if id >= 0 {
                        withAnimation(Motion.standard) { proxy.scrollTo(id, anchor: .center) }
                    }
                } label: {
                    Image(systemName: "scope")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Tokens.accent)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Tokens.bg2))
                        .overlay(Circle().stroke(Tokens.accent.opacity(0.55), lineWidth: 1))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .help("Jump to where playback is now")
                .accessibilityLabel("Jump to playback position")
                .transition(.scale.combined(with: .opacity))
            }
            // (c) Live-read follow toggle — hidden during streaming reads
            // (the streaming mode already drives auto-scroll unconditionally;
            // the toggle is for finished-entry playback).
            if Self.followToggleVisible(isStreaming: streaming != nil) {
                Button {
                    liveReadFollow.toggle()
                    UserDefaults.standard.set(liveReadFollow, forKey: DefaultsKeys.liveReadFollow)
                    // If turning ON while playing, snap to the active segment now.
                    if liveReadFollow {
                        let id = unifiedActiveId(segs)
                        if id >= 0 {
                            withAnimation(Motion.standard) { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                } label: {
                    Image(systemName: liveReadFollow ? "text.line.first.and.arrowtriangle.forward" : "pause.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(liveReadFollow ? Tokens.bg : Tokens.accent)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(liveReadFollow ? Tokens.accent : Tokens.bg2))
                        .overlay(Circle().stroke(
                            liveReadFollow ? Tokens.bg.opacity(0.25) : Tokens.accent.opacity(0.55),
                            lineWidth: 1))
                        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                }
                .buttonStyle(.plain)
                .help(liveReadFollow ? "Following playback — tap to stop auto-scroll" : "Auto-scroll with playback")
                .accessibilityLabel(liveReadFollow ? "Stop following playback" : "Follow playback")
            }
        }
        .animation(Motion.quick, value: atTop)
        .animation(Motion.quick, value: showJump)
    }

    // MARK: - Pure widget-visibility rules (nonisolated static — testable)

    /// True when the go-to-top button should be visible.
    /// Hidden when already at the top — nothing to return to.
    nonisolated static func goToTopVisible(atTop: Bool) -> Bool { !atTop }

    /// True when the live-read follow toggle should be visible.
    /// Hidden during streaming reads (the streaming reader doesn't use a
    /// follow toggle — auto-scroll is unconditional while a render streams in).
    nonisolated static func followToggleVisible(isStreaming: Bool) -> Bool { !isStreaming }

    /// True when the jump-to-playhead button should show: a live read position
    /// exists (activeId >= 0) and we're not in a streaming read (streaming
    /// already auto-scrolls unconditionally). activeId is −1 when the entry
    /// isn't the active player track, so the button is hidden exactly when
    /// "scroll to progress" had no meaningful target.
    nonisolated static func jumpToProgressVisible(isStreaming: Bool, activeId: Int) -> Bool {
        !isStreaming && activeId >= 0
    }

    /// The player block — the one place the two engines stay distinct: a finished
    /// entry uses the file/draft WaveformView + AVAudioPlayer (livePlayer); a live
    /// render uses the StreamingScrubber/PlayButton/RenderControls bar with the
    /// render legend beneath it. Single block function, switched internally.
    @ViewBuilder private func player(_ m: ReaderMode) -> some View {
        switch m {
        case .entry(let e):
            livePlayer(e)
        case .stream(let s):
            VStack(alignment: .leading, spacing: Spacing.md) {
                streamingControlBar(s)
                streamingLegend(s)
            }
        case .queued:
            // No audio yet — a queued render hasn't started. State note in place
            // of the player; its transport/remove live on the up-next card.
            HStack(spacing: Spacing.sm) {
                Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(Tokens.dim)
                Text("Queued — not yet rendered. Renders after the current job.")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Tokens.dim)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Pinned nav header, shared by both modes: Back + an icon + a title block
    /// (a static "TRANSCRIPT" eyebrow for a finished entry; for a live render
    /// the same identity block as the Rendering card, the phase and progress
    /// sit in the control bar below) + a copy button (finished only).
    private var unifiedHeader: some View {
        HStack(spacing: Spacing.md) {
            backButton
            let icon = streaming != nil ? "dot.radiowaves.left.and.right"
                : (queuedJob != nil ? "clock" : "text.alignleft")
            Image(systemName: icon)
                .font(.system(size: 14)).foregroundStyle(Tokens.accent)
                .frame(width: 30, height: 30).background(Tokens.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            if let s = streaming {
                StreamingEpisodeIdentity(episode: s)
            } else {
                // Title + meta live in the reading column below — a static eyebrow
                // here keeps the header from showing the title a second time.
                Text(queuedJob != nil ? "QUEUED RENDER" : "TRANSCRIPT")
                    .font(.system(size: 11, weight: .bold)).kerning(0.8)
                    .foregroundStyle(Tokens.muted)
            }
            Spacer()
            if let e = entry {
                HStack(spacing: Spacing.sm) {
                    copyButton(e)
                    showInFinderButton(e)
                    deleteButton(e)
                }
            }
        }
        .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.lg)
    }

    private var backButton: some View {
        Button(action: { router.closeToList() }) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                Text("Back").font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Tokens.accent)
            .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.accent.opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).keyboardShortcut(router.shortcutsOpen ? nil : .cancelAction).help("Back (Esc)")
    }

    private func copyButton(_ e: VoiceEntry) -> some View {
        Button(action: { copy(e) }) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 11))
                Text(copied ? "Copied" : "Copy transcript").font(.system(size: 11.5, design: .monospaced))
            }
            .foregroundStyle(copied ? Tokens.add : Tokens.muted)
            .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.borderStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Reveal the rendered audio in Finder. Mirrors CommitRow's button and
    /// reuses VoiceEntry.resolvedAudioURL(); renders nothing when there's no
    /// on-disk audio (e.g. a smoke-test entry).
    @ViewBuilder private func showInFinderButton(_ e: VoiceEntry) -> some View {
        if let url = e.resolvedAudioURL() {
            Button(action: { NSWorkspace.shared.activateFileViewerSelecting([url]) }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "folder").font(.system(size: 11))
                    Text("Show in Finder").font(.system(size: 11.5, design: .monospaced))
                }
                .foregroundStyle(Tokens.muted)
                .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.borderStrong))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reveal the audio file in Finder")
        }
    }

    /// Two-tap armed delete: trashes the audio + hides the row via
    /// HistoryStore.trashEntry (the same path CommitRow's delete uses), then
    /// returns to the list since this entry is gone.
    private func deleteButton(_ e: VoiceEntry) -> some View {
        ArmedDeleteControl(
            onDelete: {
                if player.activeEntry?.id == e.id { player.stop() }
                Task { await store.trashEntry(e) }
                router.closeToList()
            },
            help: "Delete this render — move its audio to Trash",
            label: "Delete")
    }

    /// The transcript body for whichever mode is active: 2-state read highlight
    /// for a finished entry, 3-state (read / rendered / not-yet) for a render.
    @ViewBuilder private func transcriptContent(_ segs: [Segment]) -> some View {
        if let e = entry {
            readingContent(e, segs: segs)
        } else if let s = streaming {
            streamingTranscript(s, segs: segs)
        } else if let j = queuedJob {
            queuedTranscript(j, segs: segs)
        }
    }

    /// Read-only preview of a queued fresh render's text — title + plain segments
    /// (no read-head / no audio). Same gutters as the other reading columns.
    private func queuedTranscript(_ job: RenderJob, segs: [Segment]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            Text(job.title.isEmpty ? "Untitled" : job.title)
                .font(.system(size: 26, weight: .bold)).foregroundStyle(Tokens.text)
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(segs) { seg in
                    Text(seg.text)
                        .font(ReaderType.font(readerSize))
                        .foregroundStyle(Tokens.text)
                        .lineSpacing(ReaderType.lineSpacing(readerSize)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(seg.id)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.xxl)
    }

    /// Segments for whichever mode is active (cached split, shared by both).
    private var unifiedSegments: [Segment] {
        if let e = entry { return entrySegments(e) }
        if let s = streaming {
            return (cachedSegmentsForId == entryID && !cachedSegments.isEmpty)
                ? cachedSegments : Transcript.segments(s.fullText)
        }
        if let j = queuedJob { return Transcript.segments(j.freshText ?? "") }
        return []
    }

    /// The segment id under the read head, for the shared auto-scroll.
    private func unifiedActiveId(_ segs: [Segment]) -> Int {
        if let e = entry { return activeReadSegmentId(e, segs: segs) }
        if let s = streaming {
            // Idle sentinel (mirrors the finished path): -1 before any playback so
            // auto-scroll doesn't yank to segment 0 while the episode is merely
            // preparing. Paused mid-stream keeps a non-negative id (currentTime>0).
            guard s.armsPlayer, s.renderedChars > 0, player.currentTime > 0 else { return -1 }
            let off = streamingReadOffset(s)
            return (segs.last(where: { $0.start <= max(off, 0) })?.id) ?? (segs.first?.id ?? -1)
        }
        return -1
    }

    /// Live read-head char offset: the play-head mapped into rendered-char space
    /// through the chunk seams (each chunk's real pace) for a fresh render; word
    /// timings arrive once the finished row is aligned. A resume — whose prefix
    /// seams aren't live — keeps the self-calibrating uniform map.
    private func streamingReadOffset(_ s: StreamingEpisode) -> Int {
        if !s.armsPlayer { return -1 }    // not in the player: no read head
        if s.prefixAudioS == 0, let last = s.chunks.last, last.cumulativeChars > 0 {
            var seams: [(Double, Double)] = [(0, 0)]
            var cum = 0.0
            for ch in s.chunks { cum += ch.durationS; seams.append((cum, Double(ch.cumulativeChars))) }
            return Int(ReadAlong.char(at: max(0, player.currentTime), points: seams).rounded())
        }
        let head = max(player.renderHeadS, 0.001)
        return Int(min(1, max(0, player.currentTime / head)) * Double(s.renderedChars))
    }

    private var missing: some View {
        VStack(spacing: 12) {
            Text("Transcript unavailable")
                .font(.system(size: 14, design: .monospaced)).foregroundStyle(Tokens.muted)
            Button("Back") { router.closeToList() }
                .buttonStyle(.plain).foregroundStyle(Tokens.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Reader title with inline edit (pencil → field → Save), replacing the
    /// title editor that lived in the removed inline PlayerPanel.
    @ViewBuilder
    private func titleRow(_ e: VoiceEntry) -> some View {
        if editingTitle {
            HStack(spacing: Spacing.sm) {
                TextField("title…", text: $titleText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Tokens.accent)
                    .focused($titleFocused)
                    .onSubmit { commitTitle(e) }
                Button("save") { commitTitle(e) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .accentPill()
                Button(action: { editingTitle = false }) {
                    Image(systemName: "xmark").font(.system(size: 12)).foregroundStyle(Tokens.dim)
                }.buttonStyle(.plain).help("Cancel")
            }
        } else {
            if let series = e.seriesLabelIfNotInTitle {
                Text(series)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tokens.accent)
            }
            HStack(spacing: Spacing.sm) {
                Text(e.derivedTitle()).font(.system(size: 26, weight: .bold)).foregroundStyle(Tokens.text)
                Button(action: {
                    // Prefill with the shown title (derived when no overlay title)
                    // so the field starts populated, not blank.
                    titleText = e.derivedTitle()
                    editingTitle = true
                    DispatchQueue.main.async { titleFocused = true }
                }) {
                    Image(systemName: "pencil").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Tokens.accent).contentShape(Rectangle())
                }.buttonStyle(.plain).help("Edit title")
            }
        }
    }

    private func commitTitle(_ e: VoiceEntry) {
        store.setTitle(e, titleText)
        editingTitle = false
    }

    /// The 3-state live read-along transcript (read / rendered / not-yet) — the
    /// streaming counterpart to `readingContent`, rendered inside the shared
    /// reader scroll. Same gutters as the finished reading column.
    // MARK: - Transcript body — live render (3-state segments)

    private func streamingTranscript(_ s: StreamingEpisode, segs: [Segment]) -> some View {
        let renderOffset = s.renderedChars
        let readOffset = streamingReadOffset(s)
        return VStack(alignment: .leading, spacing: Spacing.md) {
            ForEach(segs) { seg in
                Text(segmentAttributed3(seg, readOffset: readOffset, renderOffset: renderOffset))
                    .font(ReaderType.font(readerSize))
                    .lineSpacing(ReaderType.lineSpacing(readerSize)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(seg.id)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.xxl)
    }

    // LIVE READ — segmented "karaoke" highlight that follows playback. Already-
    // read text is brightened (Tokens.text), the rest stays dim; playback
    // progress maps to a character offset through ReadAlong (word-level once
    // the daemon has aligned the audio, the current paragraph until then). The transcript is split into segments so the read head can be kept
    // centred on a long episode (the single-Text version highlighted correctly
    // but scrolled off-screen). Plain fully-legible text when not playing. NO
    // own ScrollView — it renders into the shared page scroll (see `body`) so
    // the WHOLE details screen scrolls as one; auto-scroll runs off that scroll's
    // ScrollViewReader via `activeReadSegmentId`.
    // MARK: - Transcript body — finished entry (read-along)

    private func readingContent(_ e: VoiceEntry, segs: [Segment]) -> some View {
        let readOffset = entryReadOffset(e)
        let wordLevel = ReadAlong.isWordLevel(seamMap: e.seamMap, words: e.words, durationS: e.durationS)
        return VStack(alignment: .leading, spacing: Spacing.lg) {
            titleRow(e)
            Text(metaLine(e)).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Tokens.dim)
            VStack(alignment: .leading, spacing: Spacing.md) {
                ForEach(segs) { seg in
                    Text(segmentAttributed(seg, readOffset: readOffset, wordLevel: wordLevel))
                        // Paragraph → word when the alignment lands: a fade, not a jump.
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.5), value: wordLevel)
                        .font(ReaderType.font(readerSize))
                        .lineSpacing(ReaderType.lineSpacing(readerSize)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(seg.id)
                }
            }
        }
        // Full window width with symmetric gutters (no reading-width cap).
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.xxl)
    }

    /// Cached transcript split for the finished-entry reader — recomputed only
    /// when the cache is for a different entry or empty (the `.task(id:)` warms
    /// it; this compute-on-miss fallback is the reader's long-standing behavior).
    private func entrySegments(_ e: VoiceEntry) -> [Segment] {
        (cachedSegmentsForId == entryID && !cachedSegments.isEmpty)
            ? cachedSegments : Transcript.segments(e.text ?? "(no transcript)")
    }

    /// Absolute read-head char offset into the transcript — −1 when this entry
    /// isn't the one actively playing (every segment then renders fully legible).
    private func entryReadOffset(_ e: VoiceEntry) -> Int {
        guard isActive(e), progressFraction(e) > 0 else { return -1 }
        let total = (e.text ?? "(no transcript)").count
        // Through the stored seam_map (chunk seams, plus a point per word once the
        // daemon has aligned the audio). Its audio is in the finished file's
        // timeline, so map player.currentTime.
        if let sm = e.seamMap, sm.count >= 2 {
            let seams = sm.compactMap { $0.count >= 2 ? ($0[0], $0[1]) : nil }
            let off = ReadAlong.char(at: player.currentTime, points: seams)
            return Int(min(Double(total), max(0, off)).rounded())
        }
        // Uniform fallback — single render or a pre-seam-map row. For a resumable
        // DRAFT the audio is only the rendered prefix while e.text is the full
        // text, so cap the span to the prefix (mirrors the waveform frontier);
        // nil draftRenderedFraction → span == total → normal entry unchanged.
        let span = (e.draftRenderedFraction != nil) ? min(e.resumeCharOffset ?? total, total) : total
        return Int((Double(span) * progressFraction(e)).rounded())
    }

    /// The segment id under the read head — drives the shared page's auto-scroll.
    /// −1 when idle, so the onChange no-ops and the page stays where the user
    /// scrolled it.
    private func activeReadSegmentId(_ e: VoiceEntry, segs: [Segment]) -> Int {
        let off = entryReadOffset(e)
        return off < 0 ? -1 : (segs.last(where: { $0.start <= off })?.id ?? -1)
    }

    /// Inline tags + "Tags & Category" trigger under the title — the
    /// reading-column equivalent of PlayerPanel.tagManager. The button opens
    /// the shared TagPicker via router.tagDialogEntryID (same wiring as
    /// the expanded card, PlayerPanel.editTagsPill); the applied pills below
    /// reuse PlayerPanel's chip recipe (client tags tap-to-filter + removable,
    /// server tags muted/read-only). Pills WRAP here (wide column, legibility
    /// over truncation) rather than single-line-clipping like the card.
    /// Finished-only (a live render has no tags); stream arm yields nothing.
    @ViewBuilder private func inlineTagManager(_ mode: ReaderMode) -> some View {
        if case let .entry(e) = mode { inlineTagManagerEntry(e) }
    }

    @ViewBuilder
    private func inlineTagManagerEntry(_ e: VoiceEntry) -> some View {
        let tags = store.tagsFor(e)
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Left-aligned section header (mirrors "BOOKMARKS") that opens the
            // tag/category dialog — replaces the outlined pill.
            Button(action: { router.openTagDialog(for: e.id) }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "tag.fill").font(.system(size: 11)).foregroundStyle(Tokens.accent)
                    Text("TAGS & CATEGORY")
                        .font(.system(size: 11, weight: .bold)).kerning(0.6).foregroundStyle(Tokens.accent)
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Tokens.accent.opacity(0.7))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Pick tags & categories from the existing vocabulary")
            if tags.isEmpty {
                Text("No tags").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.ultraDim)
            } else {
                FlowTags(tags: tags) { t in AppliedTagChip(entry: e, tag: t, removable: false) }
            }
        }
    }

    private func refreshSegments() {
        if cachedSegmentsForId != entryID || cachedSegments.isEmpty {
            // entry is nil for an in-progress stream (no row yet) — fall back to
            // the streaming episode's immutable fullText so the streaming reader
            // gets the same cached split instead of re-splitting every ~4 Hz tick.
            cachedSegments = Transcript.segments(entry?.text ?? streaming?.fullText ?? "")
            cachedSegmentsForId = entryID
        }
    }

    /// Two-state highlight for one segment given the absolute read offset:
    /// fully read (bright), unread (dim), or split within the segment.
    // MARK: - Read-head highlighting (AttributedString builders)

    private func segmentAttributed(_ seg: Segment, readOffset: Int, wordLevel: Bool) -> AttributedString {
        var attr = AttributedString(seg.text)
        if readOffset < 0 || readOffset >= seg.end {
            attr.foregroundColor = Tokens.text          // not reading, or fully read
            return attr
        }
        if readOffset <= seg.start {
            attr.foregroundColor = Tokens.dim            // unread
            return attr
        }
        attr.foregroundColor = Tokens.dim
        let readInSeg = ReadAlong.litEnd(in: seg.text, at: readOffset - seg.start, wordLevel: wordLevel)
        let s = attr.startIndex
        let mid = attr.index(s, offsetByCharacters: readInSeg)
        attr[s..<mid].foregroundColor = Tokens.text      // read portion
        return attr
    }

    /// Live transport + render analytics + stop controls for the streaming
    /// reader — the same play button / scrubber / "chunk K of N · NN%" the card
    /// shows, plus the shared StreamingRenderControls (Pause / Stop / Delete).
    /// Makes the reader a full read-along + controls surface.
    private func streamingControlBar(_ s: StreamingEpisode) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if s.armsPlayer { HStack(spacing: Spacing.md) {
                StreamingPlayButton(diameter: 34, glyphSize: 12, readyHelp: "Play / pause")
                StreamingScrubber(episodeID: s.id)
                Text("\(fmtDuration(Int(player.currentTime))) / \(fmtDuration(Int(player.episodeTotalS)))")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Tokens.muted)
                    .fixedSize()
            } }
            HStack(spacing: Spacing.sm) {
                renderProgressLine(s)
                Spacer(minLength: 0)
                StreamingRenderControls()
            }
        }
    }

    /// The phase cycler while preparing; once chunks land, the card's facts —
    /// "chunk K of N · m:ss rendered" and "elapsed · about m:ss left" (one
    /// shape, both surfaces).
    @ViewBuilder private func renderProgressLine(_ s: StreamingEpisode) -> some View {
        if s.isPreparing {
            StreamStatusLabel(episode: s, isFinalizing: store.finalizing, isForcingStop: store.forcingStop,
                              font: .system(size: 11, design: .monospaced), color: Tokens.dim)
        } else {
            StreamingProgressFacts(episode: s, showsRemaining: !store.finalizing && !store.forcingStop)
        }
    }

    private func streamingLegend(_ s: StreamingEpisode) -> some View {
        HStack(spacing: Spacing.lg) {
            legendDot(Tokens.text, "read")
            legendDot(Tokens.muted, "rendered")
            legendDot(Tokens.ultraDim, "not yet rendered")
            Spacer()
            // Denominator from episode_start.chars (non-zero even if the daemon
            // omitted the full text), numerator clamped — never "N/0 chars".
            Text("\(fmtCompactChars(min(s.renderedChars, s.chars)))/\(fmtCompactChars(s.chars)) chars")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.ultraDim)
        }
    }

    private func legendDot(_ c: Color, _ label: String) -> some View {
        HStack(spacing: Spacing.xs) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.dim)
        }
    }

    /// Three-state coloring for a segment given absolute read + render offsets:
    /// read (bright) ⊂ rendered (muted) ⊂ not-yet-rendered (grayed).
    private func segmentAttributed3(_ seg: Segment, readOffset: Int, renderOffset: Int) -> AttributedString {
        var attr = AttributedString(seg.text)
        let s = attr.startIndex
        let n = seg.text.count
        attr.foregroundColor = Tokens.ultraDim          // unrendered (grayed)
        if renderOffset > seg.start {
            let e = min(n, max(0, renderOffset - seg.start))
            attr[s..<attr.index(s, offsetByCharacters: e)].foregroundColor = Tokens.muted   // rendered
        }
        if readOffset > seg.start {
            // Paragraph-level while rendering (word timings come once the row is
            // aligned), never past what has rendered.
            let lit = ReadAlong.litEnd(in: seg.text, at: readOffset - seg.start, wordLevel: false)
            let e = min(lit, max(0, renderOffset - seg.start))
            attr[s..<attr.index(s, offsetByCharacters: e)].foregroundColor = Tokens.text     // read
        }
        return attr
    }

    // Analytics + the LIVE-READ player now stack full-width in the body
    // (statBar above, livePlayer below); the old side-by-side topBar is gone.
    private func statBar(_ mode: ReaderMode) -> some View {
        // Float left with one constant gap + a trailing Spacer — matches the
        // main screen's HeaderView stat strip (item 9). Plain content-hugging
        // cells, no boxes. For a finished entry the strings are byte-identical to
        // before; a live render fills RENDER TIME with "rendering…" (no fake
        // wall-clock) and derives the rest from the episode.
        let render: (String, String?)
        switch mode {
        case .entry(let e): render = renderTimeValue(e)
        case .stream(let s): render = (s.done ? "—" : "rendering…", nil)
        case .queued: render = ("queued", nil)
        }
        return HStack(spacing: Spacing.xl) {
            barTile("\(mode.charsValue.formatted())", "CHARACTERS", nil)
            barTile("\(mode.wordsValue.formatted())", "WORDS", nil)
            barTile(mode.paceText.0, "PACE", mode.paceText.1)
            barTile(readTimeValue(mode.readSecondsValue), "READ TIME", "min")
            barTile(render.0, "RENDER TIME", render.1)
            Spacer(minLength: 0)
        }
    }

    private func barTile(_ value: String, _ label: String, _ unit: String?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(value).font(.system(size: 20, weight: .bold, design: .monospaced)).foregroundStyle(Tokens.text)
                if let u = unit { Text(u).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.dim) }
            }
            Text(label).font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Tokens.muted)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // (leftSidebar removed — bookmarks are now full-width under the player; the
    // details screen has no sidebar. Tags live inline under the title.)

    private func livePlayer(_ e: VoiceEntry) -> some View {
        let frac = progressFraction(e)
        let bms = store.bookmarksFor(e)
        let total = displayDuration(e)
        // A resumable draft's audio is only the rendered prefix — map played /
        // bookmarks / seek onto the full-draft timeline and dim the rest, same as
        // the inline PlayerPanel. nil draftFrac → a normal entry, unchanged.
        let map = e.draftSeekMap   // shared draft↔audio math (VoiceEntry)
        let played = map.played(frac)
        let marks = map.marks(bms)
        return VStack(spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Button(action: { togglePlay(e) }) {
                    ZStack {
                        Circle().fill(Tokens.accent).frame(width: 40, height: 40)
                        Image(systemName: isPlaying(e) ? "pause.fill" : "play.fill")
                            .font(.system(size: 14)).foregroundStyle(Tokens.bg)
                    }
                }
                .buttonStyle(.plain)
                WaveformView(
                    audioURL: e.resolvedAudioURL(),
                    seed: e.id,
                    playedFraction: played,
                    renderedFraction: e.draftRenderedFraction,
                    bookmarks: marks,
                    bookmarkHelp: { bm in
                        return bookmarkHelp(Bookmark(id: bm.id, position: map.audioPos(bm.position), note: bm.note),
                                            totalSeconds: total)
                    },
                    isPlaying: isPlaying(e),
                    onSeek: { f in
                        seek(e, to: map.seekTarget(f))
                    }
                )
            }
            // Time — centered beneath the waveform for visibility (was a small
            // bottom-right block). LIVE READ eyebrow sits above it.
            VStack(spacing: Spacing.xxs) {
                // Read-while-playing indicator — tracks ACTUAL playback: animated
                // accent while the voice is speaking, dimmed static when paused.
                HStack(spacing: Spacing.xs) {
                    Image(systemName: isPlaying(e) ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 11))
                        .symbolEffect(.variableColor.iterative, isActive: isPlaying(e))
                    Text(isPlaying(e) ? "LIVE READ" : "PAUSED")
                        .font(.system(size: 11, weight: .bold)).kerning(0.6)
                }
                .foregroundStyle(isPlaying(e) ? Tokens.accent : Tokens.dim)
                HStack(spacing: Spacing.sm) {
                    Text("\(fmtDuration(Int(currentSeconds(e)))) / \(fmtDuration(total))")
                        .font(.system(size: 14, weight: .medium, design: .monospaced)).foregroundStyle(Tokens.text)
                    Text("·").foregroundStyle(Tokens.ultraDim)
                    Text("−\(fmtDuration(max(0, total - Int(currentSeconds(e)))))")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Tokens.dim)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            // Continue render — surfaced in the full-screen reader too (not just
            // the inline PlayerPanel) so a draft opened here can be resumed.
            ContinueRenderButton(entry: e)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.vertical, Spacing.sm)
    }

    // Stats now render as a horizontal bar at the top (statBar/barTile).

    private func readTimeValue(_ readSeconds: Double) -> String {
        let m = readSeconds / 60.0
        return m < 1 ? "<1" : "\(Int(m.rounded()))"
    }

    /// Wall-clock time the daemon took to render this entry. "Unknown" (no
    /// unit) for entries rendered before render-timing existed, or any row
    /// missing it — never synthesized. Seconds under a minute, M:SS above.
    private func renderTimeValue(_ e: VoiceEntry) -> (value: String, unit: String?) {
        guard let s = e.renderElapsedS, s > 0 else { return ("Unknown", nil) }
        if s < 60 { return (String(format: "%.1f", s), "s") }
        return (fmtDuration(Int(s.rounded())), nil)
    }

    /// Finished-only: a live render has no bookmarks. The stream arm yields
    /// nothing, so "absent block" needs no parallel branch (it's only ever called
    /// under `mode.showsFinishedBlocks`, so the empty stream arm is dead-but-safe).
    @ViewBuilder private func bookmarksSection(_ mode: ReaderMode) -> some View {
        if case let .entry(e) = mode { bookmarksSectionEntry(e) }
    }

    @ViewBuilder
    // MARK: - Bookmarks section

    private func bookmarksSectionEntry(_ e: VoiceEntry) -> some View {
        let bms = store.bookmarksSortedFor(e)
        let total = displayDuration(e)
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Shared header (BookmarkAtoms) — same RowBookmarksPopover the
            // sidebar Library "Bookmarks" row opens, scoped to this entry.
            BookmarksSectionHeader(count: bms.count, dialogOpen: $bookmarksDialogOpen,
                                   disableWhenEmpty: true, arrowEdge: .trailing,
                                   alignment: .firstTextBaseline, spacing: Spacing.xs,
                                   kerning: 0.6) {
                RowBookmarksPopover(entry: e, bookmarks: bms, totalSeconds: total,
                                    onJump: { bm in seek(e, to: bm.position); bookmarksDialogOpen = false })
                    .environment(store)
            }
            // "+ add bookmark" — the card's add affordance (PlayerPanel.controls
            // ctrlButton("plus","add bookmark")), full-width in this column.
            Button(action: { bookmarkFraction = progressFraction(e); addingBookmark = true; bookmarkNote = "" }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "plus").font(.system(size: 11))
                    Text("add bookmark").font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(Tokens.accent)
                .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.accent.opacity(0.45)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(addingBookmark)
            .opacity(addingBookmark ? 0.5 : 1.0)
            .help("Bookmark the current position")

            if addingBookmark { addBookmarkRow(e) }
            // Inline preview — first 3 rows; the rest live in the dialog so the
            // narrow column never overflows. Same row recipe as before.
            ForEach(bms.prefix(3)) { bm in
                HStack(spacing: Spacing.md) {
                    Button(action: { seek(e, to: bm.position) }) {
                        Text(bookmarkTimestamp(bm, totalSeconds: total))
                            .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Tokens.warn)
                    }
                    .buttonStyle(.plain)
                    Text(bm.note.isEmpty ? "—" : bm.note)
                        .font(.system(size: 13.5, design: .monospaced)).foregroundStyle(Tokens.text)
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(3)
                    ArmedDeleteControl(onDelete: { store.deleteBookmark(e, id: bm.id) }, help: "Remove bookmark")
                }
                .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.border))
            }
            if bms.count > 3 {
                Button(action: { bookmarksDialogOpen = true }) {
                    Text("+\(bms.count - 3) more — view all")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func addBookmarkRow(_ e: VoiceEntry) -> some View {
        // Grows with the note (axis:.vertical, 1…8 lines); Save + cancel ride
        // the bottom-right as the field expands. With axis:.vertical Return
        // inserts a newline, so the primary commit is the Save button / ⌘Return.
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundStyle(Tokens.warn)
                Text(fmtDuration(Int((bookmarkFraction * Double(displayDuration(e))).rounded())))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Tokens.warn)
                TextField("note (optional)…", text: $bookmarkNote, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13.5, design: .monospaced))
                    .lineLimit(1...8)
                    .onSubmit { saveBookmark(e) }
            }
            HStack(spacing: Spacing.sm) {
                Spacer(minLength: 0)
                Button(action: { addingBookmark = false; bookmarkNote = "" }) {
                    Image(systemName: "xmark").font(.system(size: 11)).foregroundStyle(Tokens.dim)
                        .padding(.horizontal, Spacing.xs).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Cancel")
                Button("save") { saveBookmark(e) }
                    .buttonStyle(.plain)
                    .accentPill()
                    .font(.system(size: 11, design: .monospaced))
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Save bookmark (⌘Return)")
            }
        }
        .bookmarkComposerChrome()
    }

    // Playback accessors → shared AudioPlayer helpers (same math the inline
    // PlayerPanel uses; was duplicated here).
    private func isActive(_ e: VoiceEntry) -> Bool { player.isActive(e) }
    private func isPlaying(_ e: VoiceEntry) -> Bool { isActive(e) && player.isPlaying }
    private func currentSeconds(_ e: VoiceEntry) -> TimeInterval { player.playedSeconds(of: e) }
    private func displayDuration(_ e: VoiceEntry) -> Int { player.displayDuration(of: e) }
    private func progressFraction(_ e: VoiceEntry) -> Double { player.progressFraction(of: e) }

    private func togglePlay(_ e: VoiceEntry) {
        if isActive(e) { player.togglePlay() } else { player.play(e) }
    }

    private func seek(_ e: VoiceEntry, to f: Double) {
        player.playAndSeek(e, toFraction: f)
    }

    private func saveBookmark(_ e: VoiceEntry) {
        // Use the fraction frozen at "+ add" — NOT the live play-head, which has
        // advanced while the note was typed.
        store.addBookmark(e, position: bookmarkFraction,
                          note: bookmarkNote.trimmingCharacters(in: .whitespaces))
        addingBookmark = false
        bookmarkNote = ""
    }

    private func metaLine(_ e: VoiceEntry) -> String {
        var v = ""
        if let voice = e.voice, !voice.isEmpty { v = " · \(voice)" }
        // Category bucket (Says / a user tag-category / History) replaces the
        // git-like short hash: where the render lives says more than an
        // opaque ref.
        return "\(categoryName(e)) · \(e.backend)\(v) · \(fmtRel(e.ts))"
    }

    /// The category bucket this entry falls in, for the meta line. Mirrors
    /// HistoryStore.count(for:) membership + CategoryStore's built-in
    /// semantics: the first registered tag-backed category whose backing tag
    /// the entry carries (registry order — a user tag-category resolves by its
    /// backing tag); else the kind-backed Says for a "say" utterance; else the
    /// all-view History. (Re-derived here rather than read from the store: no
    /// store accessor returns a single bucket-per-entry, and count(for:)'s
    /// completeness/New/Rendering filtering doesn't map to one label.)
    private func categoryName(_ e: VoiceEntry) -> String {
        let tags = Set(store.tagsFor(e))
        if let hit = categories.categories.first(where: { cat in
            guard let t = cat.tag else { return false }   // skip History/Says (tag == nil)
            return tags.contains(t)
        }) {
            return hit.name
        }
        if e.kind == "say" { return CategoryStore.says.name }   // "Says"
        return CategoryStore.history.name                       // "History"
    }

    private func copy(_ e: VoiceEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(e.text ?? "", forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// Minimal left-aligned wrapping row — lays children left→right, wrapping to a
/// new line when the next child would overflow. Used by the transcript reader's
/// inline tag pills so they wrap (legible) instead of clipping like the card's
/// single-line tag row. Reuses the existing `FlowLayout` (Theme/FlowLayout.swift)
/// rather than adding a second wrapping primitive.
private struct FlowTags<Tag: Hashable, Content: View>: View {
    let tags: [Tag]
    let content: (Tag) -> Content
    var spacing: CGFloat = Spacing.sm

    var body: some View {
        FlowLayout(spacing: spacing, lineSpacing: spacing) {
            ForEach(tags, id: \.self) { content($0) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
