// HistoryStore+Episodes — streaming-episode control: cancel, save-and-stop
// (finalize), force-stop, and the provisional-card teardown they share with
// the SSE apply loop. Split from HistoryStore.swift.

import Foundation

extension HistoryStore {

    /// Cancel the active streaming episode — discards it (no canonical row);
    /// the episode_cancelled SSE tears down the card.
    func cancelEpisode() {
        guard let ep = streamingEpisode else { return }
        let id = ep.id
        // Optimistic teardown — drop the card NOW (close ASAP) rather than
        // waiting for the episode_cancelled SSE round-trip. The later SSE is
        // idempotent (its id guard no-ops on the now-nil streamingEpisode).
        teardownStreamingCard()
        Task {
            do { _ = try await DaemonClient.shared.cancelEpisode(id: id) }
            // Already torn down; surface only a genuine non-404 failure.
            catch { if !isEpisodeGone(error) { reportError("cancel failed: \(error.localizedDescription)") } }
        }
    }

    /// Save-and-stop the active streaming episode — keep the rendered-so-far
    /// audio as one row tagged "draft"; episode_complete swaps to it.
    func finalizeEpisode() {
        guard let ep = streamingEpisode else { return }
        guard !finalizing else { return }   // ignore double-press
        finalizing = true
        let id = ep.id
        Task {
            do { _ = try await DaemonClient.shared.finalizeEpisode(id: id) }
            catch {
                // Already gone → drop the card, unless a newer episode took
                // its place while the POST was out (its card must stay).
                if isEpisodeGone(error) {
                    if streamingEpisode?.id == id { teardownStreamingCard() }
                }
                else {
                    finalizing = false   // POST failed → re-enable so the user can retry
                    reportError("save & stop failed: \(error.localizedDescription)")
                }
            }
        }
        // Watchdog: "wrapping up" only needs the daemon to finish the in-flight
        // chunk (seconds). If a terminal SSE is dropped (reconnect window /
        // slow-subscriber kick), `finalizing` would stay true forever and pin
        // the controls on "wrapping up…". After a generous margin, reconcile
        // from /history and clear the flag if this episode is still active.
        Task {
            try? await Task.sleep(for: .seconds(90))
            guard finalizing, streamingEpisode?.id == id else { return }
            await load()
            finalizing = false
        }
    }

    /// Force save-and-stop the active streaming episode — like finalizeEpisode
    /// but DROP the chunk currently being rendered instead of waiting for it.
    /// Only offered during the "wrapping up" state once at least one chunk is
    /// done (so there's something to keep). `finalizing` is already true here.
    func forceFinalizeEpisode() {
        guard let ep = streamingEpisode else { return }
        guard !forcingStop else { return }   // ignore double-press
        forcingStop = true
        let id = ep.id
        Task {
            do { _ = try await DaemonClient.shared.forceFinalizeEpisode(id: id) }
            catch {
                // Already gone → drop the orphaned card, not a newer one.
                if isEpisodeGone(error) {
                    if streamingEpisode?.id == id { teardownStreamingCard() }
                }
                else {
                    forcingStop = false   // POST failed → re-enable so the user can retry
                    reportError("force stop failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Land on the live "Rendering" category (the render-queue surface). Called
    /// by the render-queue flow on enqueue (ComposeScreen, ContinueRenderButton)
    /// so a freshly-queued render is immediately visible. Clears the other
    /// LIBRARY axes so exactly one is active. (Continuing a draft now routes
    /// through RenderQueue — see ContinueRenderButton — so it serializes with
    /// any in-flight render via the same serial pump.)
    func selectRenderingCategory() {
        clearLibraryFilters()
        kindFilter = CategoryStore.renderingKind
    }

    /// Tear down the provisional streaming card + player. Used by the optimistic
    /// Discard path, the episode_cancelled/error SSE handlers, and the
    /// already-gone (404) fallback (e.g. the daemon restarted mid-stream).
    /// Idempotent — the SSE handlers guard on the episode id, so a later event
    /// no-ops once this has run.
    func teardownStreamingCard() {
        let id = streamingEpisode?.id
        if streamingEpisode?.armsPlayer == true { audioPlayer?.stopStreaming() }
        finalizing = false
        forcingStop = false
        streamingEpisode = nil
        // Stay on whatever category the user is viewing (the render-queue
        // flow owns navigation). Only close a reader that was open ON this now-
        // dead episode, so they aren't stranded reading a render that's gone.
        if let id, router?.screen == .transcript(id) { router?.closeToList() }
    }

    /// True when a daemon error means "this episode no longer exists"
    /// (404 / not_found) — distinct from a real failure worth surfacing.
    private func isEpisodeGone(_ error: Error) -> Bool {
        if case DaemonError.pipelineFailed(let stage, _) = error, stage == "not_found" { return true }
        if case DaemonError.http(let status, _) = error, status == 404 { return true }
        return false
    }
}
