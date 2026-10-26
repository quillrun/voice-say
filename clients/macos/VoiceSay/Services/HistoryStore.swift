// HistoryStore — consumes the voice-say daemon's /history endpoint + /events
// SSE stream and keeps the entry list observable for SwiftUI. Initial GET
// /history seeds the table; the stream then delivers `snapshot`, `render`,
// `progress`, and `overlay` events for live updates. Mutations (star, tag,
// bookmark, soft-delete) POST to /overlays/<ts>; the daemon's database is
// the source of truth.

import AppKit  // NSWorkspace.recycle (the default `recycler`)
import Foundation
import Observation

@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [VoiceEntry] = []
    private(set) var totalDurationS: Int = 0
    private(set) var totalBytes: Int = 0
    private(set) var totalChars: Int = 0
    private(set) var isLoading: Bool = false
    private(set) var lastError: String? = nil

    // User-controlled filters / state — driven from the view, observed here
    // because filtering is cheap and the truth lives close to the data.
    var query: String = ""
    /// TAGS-section refinement — one tag at a time (nil = no tag constraint).
    /// An INDEPENDENT axis from the collection (LIBRARY/CATEGORIES): it ANDs
    /// WITHIN the selected collection rather than replacing it, and `query`
    /// greps within the result. Driven by the sidebar tag rows + the
    /// per-render tag chips. Tag-backed CATEGORIES drive `categoryTag`, not this.
    var tagFilter: String? = nil
    /// Kind-backed COLLECTION filter (e.g. "say"). nil = no kind constraint.
    /// One of the mutually-exclusive collection axes (kind / categoryTag /
    /// starred / bookmarks). Set by the sidebar's kind-backed categories (Says).
    var kindFilter: String? = nil {
        didSet {
            // New-inbox visit lifecycle: clear sticky on enter, commit (opened
            // items leave) on exit — here, not in a list view's onChange, so it
            // runs whichever view is showing (Rendering/Bookmarks replace the list).
            guard kindFilter != oldValue else { return }
            if kindFilter == CategoryStore.newKind { enterNewView() }
            else if oldValue == CategoryStore.newKind { commitSeenInNew() }
        }
    }
    /// Tag-backed COLLECTION filter — the backing tag of a tag-backed category
    /// (e.g. "series-a"). A collection axis SEPARATE from the TAGS-section
    /// `tagFilter`, so a category and a tag refinement COMBINE (AND) instead of
    /// clobbering one another. nil = no category-collection constraint.
    var categoryTag: String? = nil
    /// "Silent tag" filter — when true, only starred entries pass `filtered`.
    /// Header's starred stat cell toggles this.
    var starredFilter: Bool = false
    /// Bookmarks LIBRARY filter — when true, only entries carrying ≥1 bookmark
    /// pass. A single-select category axis, NOT a tag.
    var bookmarksFilter: Bool = false
    /// Series COLLECTION filter (sidebar SERIES) — one series, listed in
    /// episode order instead of newest-first. nil = no series constraint.
    var seriesFilter: String? = nil

    /// "New" inbox — timestamps of completed renders the user hasn't opened
    /// yet. Persisted so an unopened render survives relaunch. Added on natural
    /// episode_complete; removed once opened. The badge/count reads this set.
    /// Every mutation lives in THIS file so the write → persistNewIDs() pairing
    /// stays compiler-enforced (private(set)), not convention.
    private(set) var newIDs: Set<String> = []
    /// Items opened during the CURRENT visit to the New view — kept visible in
    /// the New list until the user leaves it, so an item never vanishes the
    /// instant it's opened. Cleared on enter/exit of the New view.
    private var stickyNewView: Set<String> = []
    private let newIDsName = "voicesay.newIDs.v1"

    // MARK: - New inbox (all writers; reads live in +Filters)

    /// Visible in the New view = still unopened OR opened during this visit
    /// (sticky, so it doesn't vanish mid-look). The badge counts only `newIDs`.
    func isNewVisible(_ e: VoiceEntry) -> Bool {
        newIDs.contains(e.ts) || stickyNewView.contains(e.ts)
    }

    /// Mark a render opened: drop it from the unopened set (badge decrements
    /// now) but keep it visible in the New list until the user leaves
    /// (sticky). Idempotent; no-op for non-New entries.
    func markSeenIfNew(_ id: String) {
        guard newIDs.contains(id) else { return }
        newIDs.remove(id)
        stickyNewView.insert(id)
        persistNewIDs()
    }

    /// Entering the New view starts a fresh visit — clear sticky carryover.
    func enterNewView() { stickyNewView.removeAll() }
    /// Leaving the New view commits the visit: the user saw the whole list,
    /// so every still-unopened render is now seen — clear the badge to 0, not
    /// just the sticky carryover. (Items opened mid-visit already left newIDs;
    /// this also clears the ones merely glanced at in the list — entering then
    /// exiting New resets the counter.)
    func commitSeenInNew() {
        if !newIDs.isEmpty {
            newIDs.removeAll()
            persistNewIDs()
        }
        stickyNewView.removeAll()
    }

    private func persistNewIDs() {
        UserDefaults.standard.set(Array(newIDs), forKey: newIDsName)
    }

    /// Currently expanded commit row (PlayerPanel inline). `nil` = none.
    /// Lifted out of ContentView so the header popovers (starred,
    /// bookmarks) can drive expansion when the user clicks an item.
    var expandedEntryID: String? = nil

    /// Bumped whenever a header popover wants the list to scroll to a
    /// specific entry id. ContentView's ScrollViewReader observes and
    /// clears this back to nil after acting. We can't just observe
    /// `expandedEntryID` because the user may toggle a row without
    /// wanting the list to jump.
    var pendingScrollID: String? = nil

    /// Set `expandedEntryID` and request a scroll-to, so a just-finished
    /// render (episode_complete) expands its card AND brings it into view
    /// without the user having to hunt.
    func activate(_ entryID: String) {
        expandedEntryID = entryID
        pendingScrollID = entryID
    }

    /// ContentView calls this after consuming `pendingScrollID` so the
    /// `.onChange` only fires for the next request, not repeatedly.
    func acknowledgeScroll() { pendingScrollID = nil }

    /// Jump to an entry from a surface outside the list (the pinned Now
    /// Playing / Last Played card, Continue, a bookmark's "Show episode"): if
    /// the active filters hide the target, clear them first — otherwise
    /// ContentView's scrollTo would aim at a row that isn't in `filtered` and
    /// silently no-op. The Bookmarks and Rendering views replace the list, so
    /// from there the filters are cleared and the activate waits one tick for
    /// the list (and its scroll observer) to mount.
    func revealInList(_ entryID: String) {
        let listReplaced = bookmarksFilter || kindFilter == CategoryStore.renderingKind
        if listReplaced || Self.jumpNeedsFilterClear(targetID: entryID, filteredIDs: filtered.map(\.id)) {
            query = ""
            tagFilter = nil
            categoryTag = nil
            starredFilter = false
            bookmarksFilter = false
            kindFilter = nil
            seriesFilter = nil
        }
        if listReplaced {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.activate(entryID) }
        } else {
            activate(entryID)
        }
    }

    /// Pure core for `revealInList`: a jump must clear filters exactly when
    /// the target is absent from the currently-filtered ids.
    nonisolated static func jumpNeedsFilterClear(targetID: String, filteredIDs: [String]) -> Bool {
        !filteredIDs.contains(targetID)
    }

    /// Entries currently being hard-deleted to Trash. PlayerPanel observes
    /// this to show a per-row loader during the (potentially slow) file
    /// system + overlay round-trip.
    var deletingKeys: Set<String> = []

    // Overlay mirrors — populated from entry.overlay when /history loads
    // and updated live via SSE overlay events. Daemon owns the truth
    // (its database); these maps are just convenient client-side
    // indexes keyed by entry ts. Mutations POST to /overlays/<ts> and
    // optimistically update the local mirror so the UI reacts immediately.
    var bookmarks: [String: [Bookmark]] = [:]
    var starred: Set<String> = []
    var deletedKeys: Set<String> = []
    var clientTags: [String: [String]] = [:]
    /// Suppressed tags per entry (overlay.removed_tags) — subtracted from
    /// the effective tag set so "delete tag" works on immutable server tags.
    var clientRemovedTags: [String: [String]] = [:]

    /// Live counts kept in sync with the mirrors. Header renders these
    /// every SSE tick (progress events fire ~4 Hz when playing); the
    /// previous flow did three O(N) scans per render. Computing them
    /// when mirrors mutate (rebuildOverlayMirrors / applyOverlayToMirrors
    /// / trashEntry) costs the same total work but happens
    /// once per write, not once per header redraw.
    private(set) var liveRenderCount: Int = 0
    private(set) var liveStarredCount: Int = 0
    private(set) var liveBookmarkCount: Int = 0

    /// Overlays delivered via SSE that arrived before their corresponding
    /// render event (possible during backlog replay or reconnect ordering).
    /// We stash them here keyed by ts and drain on the next render event
    /// that creates that row. Without this, the overlay update vanishes
    /// silently — stars/tags would appear to be lost until the next
    /// full /history reload. A full-list reconcile (snapshot, load()) settles
    /// every stash, so an overlay for a row that never arrives doesn't stay
    /// for the app's lifetime.
    private(set) var pendingOverlays: [String: Overlay] = [:]

    private var eventStream: EventStreamReader? = nil
    private(set) var streamConnected: Bool = false

    /// Active "play while rendering" episode, or nil. Set on episode_start,
    /// updated on chunk_ready, cleared on episode_complete (after the
    /// canonical row arrives and selection is handed to it). ContentView
    /// renders a provisional card at the top of the list while this is set
    /// and not done.
    var streamingEpisode: StreamingEpisode? = nil

    /// True between finalizeEpisode() (Pause pressed) and the
    /// episode_complete that carries save_and_stop. Drives the "finishing
    /// current chunk…" status on the streaming card + header and disables the
    /// Pause / Delete / play controls so the user can't double-press
    /// while the daemon finishes the in-flight chunk. Cleared in
    /// apply(.episodeComplete/.episodeCancelled/.episodeError).
    var finalizing: Bool = false

    /// True between forceFinalizeEpisode() (Stop Now pressed during the
    /// "finishing current chunk" state) and the terminal episode event. Swaps the
    /// Stop Now button for a "stopping…" label so it can't be double-pressed while
    /// the daemon drops the in-flight chunk and writes the draft row. Cleared
    /// alongside `finalizing` in apply(.episodeStart/Complete/Cancelled/Error).
    var forcingStop: Bool = false

    enum StreamPlayIntent { case whileRendering, none }
    /// How the current render should play: set before a render so the SSE
    /// lifecycle knows whether to play while streaming or stay silent. Every render now routes through the
    /// streaming path (so it shows in Rendering); this picks the playback.
    @ObservationIgnored var pendingPlayIntent: StreamPlayIntent = .whileRendering

    /// AudioPlayer reference, injected so the SSE apply loop can drive the
    /// streaming queue (startStreaming / enqueueChunk / markStreamComplete).
    /// Weak: the player is a long-lived @StateObject owned by the app.
    @ObservationIgnored weak var audioPlayer: AudioPlayer?

    /// UIRouter reference, injected the same way as `audioPlayer` so the SSE
    /// apply loop can land the user on the streaming reader the moment an
    /// episode is born (episode_start) and swap to the finished row's reader on
    /// completion. Weak: the router is a long-lived @StateObject owned by the app.
    @ObservationIgnored weak var router: UIRouter?

    /// Episode lifecycle the render queue needs: this app's own episode_start,
    /// and every episode_complete (the queue matches the id). Wired in App.swift.
    enum EpisodeSignal: Equatable, Sendable {
        case ownStarted(String)
        case completed(String)
    }
    @ObservationIgnored var onEpisodeSignal: (@MainActor (EpisodeSignal) -> Void)? = nil

    /// POST /overlays/<ts>. Injectable so the overlay-write paths (rollback,
    /// trash ordering) are testable without a daemon.
    @ObservationIgnored var overlayWriter: @Sendable (String, OverlayRequest) async throws -> Void = { ts, req in
        _ = try await DaemonClient.shared.postOverlay(ts: ts, request: req)
    }
    /// The last overlay write in flight: writes are chained so they reach the
    /// daemon in click order (two quick star toggles must land true, false).
    @ObservationIgnored var overlayWriteTail: Task<Void, Never>?
    /// Moves a file to the Trash (NSWorkspace.recycle). Injectable likewise.
    @ObservationIgnored var recycler: @MainActor (URL) async throws -> Void = { url in
        try await NSWorkspace.shared.recycle([url])
    }

    /// `connect: false` (tests) skips the /history load and the /events stream.
    init(connect: Bool = true) {
        if let saved = UserDefaults.standard.array(forKey: newIDsName) as? [String] {
            newIDs = Set(saved)
        }
        if connect { startStreaming() }
    }


    /// True while load() is fetching; further load() calls mid-fetch set
    /// `loadQueued` instead of racing a parallel fetch (trailing-edge
    /// coalescing). At most one /history fetch in flight ⇒ no out-of-order
    /// responses clobbering `entries` when `reloaded` SSE events arrive in
    /// bursts (one per POST /reload).
    private var loadInFlight = false
    /// Starts the error a failed /history fetch leaves in `lastError`.
    static let fetchErrorPrefix = "history fetch:"
    private var loadQueued = false

    func load() async {
        // Coalesce: if a fetch is already in flight, request exactly ONE
        // trailing re-run (it sees any state the in-flight payload missed)
        // and return — N burst events collapse to ≤2 fetches, in order.
        if loadInFlight {
            loadQueued = true
            return
        }
        loadInFlight = true
        defer {
            loadInFlight = false
            if loadQueued {
                loadQueued = false
                Task { await self.load() }
            }
        }
        // /history via the daemon, so the app never opens the daemon's
        // database itself.
        isLoading = true
        defer { isLoading = false }
        if !AppConfig.shared.loadedFromDaemon {
            await AppConfig.shared.refresh()
        }
        // Snapshot BEFORE the await: an id inserted by SSE while the fetch is
        // in flight (episodeComplete racing the payload) is absent from BOTH
        // the payload and this snapshot — the prune must keep it.
        let preFetch = Set(entries.map(\.ts))
        let stashedBeforeFetch = Set(pendingOverlays.keys)
        do {
            let payload = try await DaemonClient.shared.history(limit: 5000)
            entries = Self.mergedAfterFetch(current: entries, preFetch: preFetch,
                                            fetched: payload.entries)
            let settled = Self.settledPendingOverlays(pendingOverlays,
                                                      stashedBeforeFetch: stashedBeforeFetch,
                                                      present: Set(entries.map(\.ts)))
            pendingOverlays = settled.keep
            for (ts, ov) in settled.apply {
                if let idx = entries.firstIndex(where: { $0.ts == ts }) {
                    entries[idx] = entries[idx].withOverlay(ov)
                }
            }
            recomputeTotals()
            rebuildOverlayMirrors()
            VoiceEntry.forgetMissingAudio()
            // Drop New-inbox ids only when CONFIRMED deleted — present before
            // the fetch but absent from the fresh payload (e.g. a row another
            // client merged into another and deleted). A degenerate
            // empty payload (daemon mid-restart) prunes nothing.
            let pruned = Self.prunedNewIDs(newIDs, preFetch: preFetch,
                                           fetched: Set(entries.map(\.ts)))
            if pruned != newIDs { newIDs = pruned; persistNewIDs() }
            lastError = nil
        } catch {
            lastError = "\(Self.fetchErrorPrefix) \(error.localizedDescription) — \(DaemonController.startHint)"
        }
    }

    /// Pure core of the New-inbox prune (load() + the snapshot reconcile):
    /// drop only ids whose rows are confirmed deleted — present in the
    /// pre-fetch snapshot but absent from the fetched payload. An empty
    /// payload prunes nothing; an id the payload merely hasn't seen yet
    /// (inserted mid-fetch) survives.
    nonisolated static func prunedNewIDs(_ newIDs: Set<String>,
                                         preFetch: Set<String>,
                                         fetched: Set<String>) -> Set<String> {
        guard !fetched.isEmpty else { return newIDs }
        return newIDs.subtracting(preFetch.subtracting(fetched))
    }

    /// Settle stashed out-of-order overlays after a /history fetch. A stash
    /// older than the fetch is covered by it (the payload carries that row's
    /// overlay, or the row doesn't exist): dropped. A stash that arrived while
    /// the fetch was in flight is newer than the payload: applied when its row
    /// is now present, else kept for the render event that brings the row.
    nonisolated static func settledPendingOverlays(_ pending: [String: Overlay],
                                                   stashedBeforeFetch: Set<String>,
                                                   present: Set<String>)
        -> (apply: [String: Overlay], keep: [String: Overlay]) {
        var apply: [String: Overlay] = [:], keep: [String: Overlay] = [:]
        for (ts, ov) in pending where !stashedBeforeFetch.contains(ts) {
            if present.contains(ts) { apply[ts] = ov } else { keep[ts] = ov }
        }
        return (apply, keep)
    }

    /// The fetched list plus any row SSE inserted while the fetch was in
    /// flight (absent before it and from a payload that predates it), kept
    /// on top as the newest — otherwise it vanishes until the next reload.
    nonisolated static func mergedAfterFetch(current: [VoiceEntry], preFetch: Set<String>,
                                             fetched: [VoiceEntry]) -> [VoiceEntry] {
        let fetchedTS = Set(fetched.map(\.ts))
        let arrived = current.filter { !preFetch.contains($0.ts) && !fetchedTS.contains($0.ts) }
        return arrived + fetched
    }

    /// Connect to /events for live updates. The reader auto-reconnects with
    /// exponential backoff on transport failure, so no separate poll is needed.
    func startStreaming() {
        // Idempotent — init is the sole intended caller. A second call would
        // leak the prior EventStreamReader and double-load; guard like
        // RenderQueue.startPumpIfIdle. The reader lives for the app's lifetime.
        guard eventStream == nil else { return }
        // Initial load fills the table immediately; the snapshot event
        // received once SSE connects will reconcile.
        Task { await self.load() }

        let reader = EventStreamReader(url: DaemonClient.shared.eventsURL)
        self.eventStream = reader
        // Weak on the outer Task too: the reader's callbacks outlive this
        // call, and an implicit strong capture here would contradict the
        // [weak self] on the closures it hands over.
        Task { [weak self] in
            await reader.start(onEvent: { [weak self] ev in
                Task { @MainActor [weak self] in
                    self?.apply(event: ev)
                }
            }, onConnectChange: { [weak self] connected in
                Task { @MainActor [weak self] in
                    self?.streamConnected = connected
                    if connected {
                        await self?.daemonConnected()
                        await self?.dropStreamingCardIfEpisodeGone()
                    }
                }
            })
        }
    }

    /// The event stream (re)connected, so the daemon is up. The snapshot it
    /// sends refills the list without a load(), so the parts only load()
    /// used to settle are settled here: a "history fetch … start it" error
    /// from while it was down goes, and backends/voices are fetched if they
    /// never were (Compose open across the start would otherwise offer none).
    func daemonConnected() async {
        if lastError?.hasPrefix(Self.fetchErrorPrefix) == true { lastError = nil }
        if !AppConfig.shared.loadedFromDaemon { await AppConfig.shared.refresh() }
    }

    /// After a reconnect the episode's terminal event may have been missed
    /// (daemon restarted, or the replay window passed): if the daemon says no
    /// episode is running, the live card is stale — take it down.
    private func dropStreamingCardIfEpisodeGone() async {
        guard let id = streamingEpisode?.id,
              let queue = try? await DaemonClient.shared.health().queue,
              queue.episodeRunningS == nil,
              streamingEpisode?.id == id else { return }
        teardownStreamingCard()
    }

    /// Apply one SSE event to the in-memory entry array + overlay mirrors.
    /// Internal (not private) so tests can drive the store with wire events.
    func apply(event: DaemonEvent) {
        switch event {
        case .snapshot(let snap):
            // snap.history rows arrive without overlay/progress merged
            // (the daemon's broadcast snapshot serves raw history values +
            // separate overlays/progress maps). Hydrate so downstream
            // consumers — tagsFor, the row chrome — can read .overlay
            // straight off the entry without a separate mirror lookup.
            let preSnapshot = Set(entries.map(\.ts))
            // The snapshot is the whole state as of its id: every stashed
            // overlay is either in it or for a row that doesn't exist.
            pendingOverlays.removeAll()
            entries = snap.history.map { e in
                var copy = e
                if let o = snap.overlays?[e.ts] { copy.overlay = o }
                if let p = snap.progress[e.ts] { copy.progress = p }
                return copy
            }
            recomputeTotals()
            rebuildOverlayMirrors()
            VoiceEntry.forgetMissingAudio()
            // Same confirmed-deleted New-inbox prune as load() — the SSE
            // snapshot is the other full-list reconcile path.
            let pruned = Self.prunedNewIDs(newIDs, preFetch: preSnapshot,
                                           fetched: Set(entries.map(\.ts)))
            if pruned != newIDs { newIDs = pruned; persistNewIDs() }
        case .render(let r):
            if let idx = entries.firstIndex(where: { $0.ts == r.ts }) {
                // Preserve overlay/progress on update — render events
                // ship only the canonical entry, not the mutable side.
                var merged = r.entry
                merged.overlay = entries[idx].overlay
                merged.progress = entries[idx].progress
                entries[idx] = merged
                // A same-ts UPDATE can change duration/bytes/chars/star/bookmarks
                // (e.g. a resume superseding a draft) — reconcile header totals +
                // live counts like the insert/progress branches do.
                recomputeTotals()
                recomputeLiveCounts()
            } else {
                var newEntry = r.entry
                // If an overlay event arrived before this render (out-of-
                // order SSE replay or reconnect window), drain the pending
                // map so the star/tags/bookmarks land on the row from
                // birth instead of waiting for the next overlay POST.
                if let stashed = pendingOverlays.removeValue(forKey: r.ts) {
                    newEntry.overlay = stashed
                    applyOverlayToMirrors(ts: r.ts, overlay: stashed,
                                          entryForKey: newEntry)
                }
                entries.insert(newEntry, at: 0)
                // Authoritative recompute (excludes resumable drafts) instead of
                // a manual += that inflated totals for a save-and-stop draft and
                // never refreshed totalChars.
                recomputeTotals()
                recomputeLiveCounts()
            }
        case .progress(let p):
            if let idx = entries.firstIndex(where: { $0.ts == p.ts }) {
                entries[idx] = entries[idx].withProgress(p.progress)
                // Recompute from the authoritative (draft-excluding) path rather
                // than an unfiltered manual +=.
                recomputeTotals()
            }
        case .overlay(let ov):
            if let idx = entries.firstIndex(where: { $0.ts == ov.ts }) {
                entries[idx] = entries[idx].withOverlay(ov.overlay)
                applyOverlayToMirrors(ts: ov.ts, overlay: ov.overlay)
            } else {
                // Stash for the render event to drain. Without this,
                // applyOverlayToMirrors would early-return at its guard
                // and the star/tags/bookmarks would never reach the
                // local mirrors.
                pendingOverlays[ov.ts] = ov.overlay
            }
        case .playbackActive(let pb):
            // Another surface (e.g. the CLI's mpv) just claimed playback —
            // tell AudioPlayer to pause so we don't double-play. Our own
            // announces echo back here; ignore them.
            if pb.source != "voicesay" {
                NotificationCenter.default.post(name: .playbackTakenByOther, object: nil)
            }
        case .episodeStart(let ev):
            // A new streaming episode began. Build the provisional model and
            // arm the AudioPlayer's queue (keyed by episode_id since there's no
            // ts yet). Navigation is owned by the render-queue flow, not here.
            // An episode another client started (agent, CLI) only shows its
            // progress: it never arms the player or moves the user.
            let foreign = ev.client_ref != DaemonClient.clientRef
            let ep = StreamingEpisode(
                id: ev.episode_id,
                predictedTotalS: ev.predicted_total_s,
                totalChunks: ev.total_chunks,
                chars: ev.chars,
                backend: ev.backend,
                voice: ev.voice,
                fullText: ev.text ?? "",
                prefixAudioS: ev.prefix_audio_s ?? 0,
                playIntent: foreign ? .none : pendingPlayIntent,
                isForeign: foreign,
                title: ev.title,
                series: ev.series,
                episodeNumber: ev.episode
            )
            streamingEpisode = ep
            // A fresh episode is never "wrapping up" — clear any stale finalize
            // flag a previous (possibly raced) completion may have left set, so
            // the new render doesn't inherit a phantom "wrapping up…" state.
            finalizing = false
            forcingStop = false
            if foreign { break }
            onEpisodeSignal?(.ownStarted(ev.episode_id))
            // A silent batch render shows its progress only: arming the player
            // would stop whatever is playing, and the user stays where
            // they are.
            guard ep.armsPlayer else { break }
            // Provisional selection — no canonical row exists yet, so this
            // just marks intent; the card binds to the streaming player.
            expandedEntryID = ev.episode_id
            audioPlayer?.startStreaming(ep)
            // Play-while-rendering opens the reader (the merged details +
            // transcript surface) for a live read-along.
            router?.open(.transcript(ev.episode_id))
            // Navigation (landing on the Rendering queue) is owned by the
            // render-queue flow — ComposeScreen / ContinueRenderButton call
            // selectRenderingCategory() on enqueue — NOT this SSE handler, so a
            // mid-batch episode_start never yanks the user off whatever
            // they're viewing. The provisional StreamingEpisodeCard surfaces
            // this render (top of the list everywhere, or the queue head when on
            // Rendering); the reader is reachable via the card's "read" button.
        case .chunkReady(let ev):
            // Append the chunk and feed it to the player's queue. Ignore
            // chunks for a stale episode (id mismatch).
            guard let ep = streamingEpisode, ep.id == ev.episode_id else { break }
            ep.chunks.append(StreamChunk(seq: ev.seq, path: ev.chunk_path,
                                         durationS: ev.chunk_duration_s,
                                         cumulativeChars: ev.rendered_chars ?? ep.renderedChars))
            ep.renderHeadS = ev.cumulative_audio_s
            if let rc = ev.rendered_chars { ep.renderedChars = rc }
            guard ep.armsPlayer else { break }
            audioPlayer?.enqueueChunk(url: URL(fileURLWithPath: ev.chunk_path),
                                      durationS: ev.chunk_duration_s)
            // Self-calibrate the streaming total from MEASURED pace (prefix
            // included on a resume). Replaces the chars/17.8 seed for the
            // scrubber / time / remaining / waveform frontier until the probed
            // duration snaps in on episode_complete.
            if let total = ep.estimatedTotalS {
                audioPlayer?.updateEpisodeTotal(total)
            }
        case .episodeComplete(let ev):
            // The canonical VoiceEntry already arrived via {type:"render"}
            // (ordering guaranteed by the daemon) and sits at entries[0] with
            // ts == ev.ts. Snap the player's total, mark done, and clear the
            // provisional card so exactly one history row remains.
            //
            // Clear the wrapping-up flag FIRST — before the guard — so a
            // completion that races the episode teardown (streamingEpisode
            // already nil/swapped) can't leave `finalizing` stuck true and make
            // the NEXT render show a phantom "wrapping up…".
            finalizing = false
            forcingStop = false
            onEpisodeSignal?(.completed(ev.episode_id))
            guard let ep = streamingEpisode, ep.id == ev.episode_id else { break }
            ep.done = true
            // Save-and-stop arrives as episode_complete with save_and_stop=true.
            // "Stop" means stop playback too — tear down the streaming queue so
            // the buffered partial doesn't keep draining. Natural completion
            // instead snaps the total and hands playback to the archived file
            // at the same second (AudioPlayer.handOffStream). An episode
            // that never armed the player (silent batch, another client's)
            // has nothing to stop or snap — the player may be busy with
            // something else.
            if ep.armsPlayer {
                if ev.save_and_stop == true {
                    audioPlayer?.stopStreaming()
                } else {
                    audioPlayer?.markStreamComplete(totalS: ev.duration_s)
                    if let row = entries.first(where: { $0.ts == ev.ts }) {
                        audioPlayer?.handOffStream(to: row, totalS: ev.duration_s)
                    }
                }
            }
            // A naturally-completed render (not a save-and-stop draft) joins the
            // New inbox as unopened. Save-and-stop produces a resumable draft →
            // it stays in the Rendering bucket, not New.
            if ev.save_and_stop != true {
                newIDs.insert(ev.ts)
                persistNewIDs()
            }
            // Navigation is owned by the render-queue flow, NOT this handler: a
            // finished render stays on the Rendering queue while more jobs drain
            // (silent batch). The canonical row is already in History (delivered
            // via the `render` SSE) and a save-and-stop draft is in Drafts — both
            // reachable when the user chooses. Only reconcile from /history
            // if that canonical row hasn't landed yet (SSE replay lag).
            if !entries.contains(where: { $0.ts == ev.ts }) {
                Task { await self.load() }
            }
            // The one exception: a reader open on this live episode becomes
            // the finished row's reader, so the user keeps reading. A
            // save-and-stop draft's reader closes with the episode instead.
            if ev.save_and_stop != true, router?.screen == .transcript(ep.id) {
                router?.open(.transcript(ev.ts))
            }
            streamingEpisode = nil
        case .episodeCancelled(let ev):
            // Cancelled mid-render: no canonical row. Drop the provisional card
            // + tear down the streaming player.
            guard streamingEpisode?.id == ev.episode_id else { break }
            teardownStreamingCard()
        case .episodeError(let ev):
            guard streamingEpisode?.id == ev.episode_id else { break }
            teardownStreamingCard()
            lastError = Self.episodeErrorText(ev)
        case .other(let env):
            // Out-of-band db changes (e.g. a script merging audio into a
            // pre-staged row, then deleting the transient insert) call
            // POST /reload; the daemon broadcasts {type:"reloaded"}.
            // Refetch /history so the change lands without a relaunch — otherwise
            // the transient render lingers as a wrong-named ghost and the merged
            // row never flips to its rendered state in the live view.
            if env.type == "reloaded" { Task { await self.load() } }
        }
    }

    /// Banner text for a failed episode, naming what was kept (engine._salvage).
    static func episodeErrorText(_ ev: DaemonEpisodeErrorEvent) -> String {
        let head = "render error (\(ev.stage)): \(ev.message)"
        guard ev.saved_ts != nil else { return head }
        return ev.partial == false
            ? head + " — the episode was saved."
            : head + " — the finished part was saved as a draft; Continue render finishes it."
    }

    private func rebuildOverlayMirrors() {
        var bm: [String: [Bookmark]] = [:]
        var st: Set<String> = []
        var del: Set<String> = []
        var tg: [String: [String]] = [:]
        var rt: [String: [String]] = [:]
        for e in entries {
            guard let o = e.overlay else { continue }
            let key = tagKey(for: e)
            if !o.bookmarks.isEmpty { bm[key] = o.bookmarks }
            if o.starred { st.insert(key) }
            if o.deleted { del.insert(key) }
            if !o.tags.isEmpty { tg[key] = o.tags }
            if !o.removedTags.isEmpty { rt[key] = o.removedTags }
        }
        bookmarks = bm
        starred = st
        deletedKeys = del
        clientTags = tg
        clientRemovedTags = rt
        recomputeLiveCounts()
    }

    /// Recompute the header-facing live counts. Cheap (one pass over the
    /// entries + the small mirror dicts) and only fires when the mirrors
    /// actually changed.
    /// Header totals over COMPLETE renders only — not-fully-rendered drafts are
    /// excluded from the app statistics (they live in the Rendering bucket, not
    /// history). Precomputed so the header isn't doing O(N) scans per redraw.
    func recomputeTotals() {
        // Exclude soft-deleted entries too (matches recomputeLiveCounts + the
        // History view), so deleting a render drops it from the header totals.
        let counted = entries.filter { !deletedKeys.contains(tagKey(for: $0)) && isComplete($0) }
        totalDurationS = counted.reduce(0) { $0 + Int($1.bestDurationS()) }
        totalBytes = counted.reduce(0) { $0 + $1.bytes }
        totalChars = counted.reduce(0) { $0 + $1.chars }
    }

    func recomputeLiveCounts() {
        // Exclude not-fully-rendered drafts: they don't count as renders.
        let liveKeys = Set(entries
            .filter { !deletedKeys.contains(tagKey(for: $0)) && isComplete($0) }
            .map { tagKey(for: $0) })
        liveRenderCount = liveKeys.count
        liveStarredCount = starred.intersection(liveKeys).count
        var bm = 0
        for (k, list) in bookmarks where liveKeys.contains(k) {
            bm += list.count
        }
        liveBookmarkCount = bm
    }

    /// Apply an overlay to the four `@Observable` mirror collections.
    /// Pass `entryForKey` when the row isn't yet in `entries` (the
    /// out-of-order overlay-then-render path) — we still need `tagKey`
    /// to build the dict key.
    func applyOverlayToMirrors(ts: String, overlay: Overlay,
                                       entryForKey: VoiceEntry? = nil) {
        let e = entryForKey ?? entries.first(where: { $0.ts == ts })
        guard let e else { return }
        let key = tagKey(for: e)
        bookmarks[key] = overlay.bookmarks.isEmpty ? nil : overlay.bookmarks
        if overlay.starred { starred.insert(key) } else { starred.remove(key) }
        if overlay.deleted { deletedKeys.insert(key) } else { deletedKeys.remove(key) }
        clientTags[key] = overlay.tags.isEmpty ? nil : overlay.tags
        clientRemovedTags[key] = overlay.removedTags.isEmpty ? nil : overlay.removedTags
        recomputeLiveCounts()
        // A delete/undelete (deletedKeys changed above) must also reconcile the
        // header chars/size/time totals, not just the live counts.
        recomputeTotals()
    }


    /// Surface a user-facing error from outside the store (lastError has a
    /// private setter). Used by stream-mode renders that fail BEFORE
    /// episode_start, where no episode_error SSE is emitted to set it.
    func reportError(_ message: String) {
        lastError = message
    }

    /// Dismiss the current error banner (the X button / auto-dismiss).
    func clearError() { lastError = nil }
}
