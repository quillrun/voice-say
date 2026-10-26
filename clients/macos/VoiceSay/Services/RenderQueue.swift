// RenderQueue — an ordered list of upcoming renders, drained one at a time.
//
// Why client-side: the daemon's /render_longform (and /episode/resume) POSTs
// stay open for the WHOLE render (timeout 600) and return only on
// completion/cancel. So awaiting one IS the "current render finished" signal —
// a serial pump that does `await renderer.render(head)` per job gives
// "don't start the next until the current is fully rendered" for free, with no
// daemon changes, and guarantees exactly one episode is ever in flight (so
// HistoryStore's single `streamingEpisode` invariant holds).
//
// `jobs.first` is the locked HEAD while a render is in flight; `jobs[1...]` is
// the reorderable "up next" tail. The head can't be reordered/removed here —
// it's stopped via StreamingRenderControls (Pause / Stop Now / Delete) on the
// streaming card/reader, whose outcome the pump observes (render() throws
// .cancelled / returns normally) and then advances.

import Foundation
import Observation

@MainActor
@Observable
final class RenderQueue {
    /// Ordered jobs. `jobs.first` is the active (locked) head while rendering;
    /// the rest are the reorderable waiting tail.
    private(set) var jobs: [RenderJob] = []
    /// The job currently rendering (== `jobs.first` while a render is in
    /// flight), or nil between jobs / when idle.
    private(set) var activeJobID: UUID? = nil
    /// Jobs whose render failed for a reason waiting won't fix (the daemon
    /// refused the request, the backend errored). Each keeps its text and the
    /// error (`failure`) until the user presses Retry or Remove.
    private(set) var failed: [RenderJob] = []
    /// True while the pump holds the head because the daemon can't be reached
    /// (down, stopped, restarting); the head renders again once it answers.
    private(set) var waitingForDaemon: Bool = false

    var isRendering: Bool { activeJobID != nil }
    /// The locked, currently-rendering job (if any).
    var activeJob: RenderJob? { jobs.first { $0.id == activeJobID } }
    /// The reorderable waiting tail (everything that isn't the active head).
    var waiting: [RenderJob] { jobs.filter { $0.id != activeJobID } }

    /// Wired in App.swift. Weak: both are app-lifetime @State owned elsewhere.
    @ObservationIgnored weak var renderer: (any RenderRunning)?
    @ObservationIgnored weak var store: HistoryStore?

    /// Backend resolver — injectable so the pump is unit-testable without the
    /// daemon-loaded AppConfig catalog. Production uses the live catalog.
    @ObservationIgnored var resolveBackend: @MainActor (String) -> Backend? = { Backends.find(id: $0) }
    /// /health probe the pump polls while the daemon is unreachable —
    /// injectable for the same reason.
    @ObservationIgnored var daemonStatus: @MainActor () async -> DaemonStatus = { await RenderQueue.liveDaemonStatus() }
    @ObservationIgnored var retryPollInterval: Duration = .seconds(3)

    /// This app's episode for the job in flight, from the SSE (HistoryStore
    /// forwards its own episode_start / episode_complete): lets the pump tell
    /// "the connection dropped but the daemon finished the render" apart from
    /// "the render was lost" before sending the text again.
    @ObservationIgnored private var attemptEpisodeID: String? = nil
    @ObservationIgnored private var attemptCompleted: Bool = false

    /// How long a job may render once its episode has started (this app's
    /// episode_start) — so time spent waiting at the daemon's gate behind
    /// another client's render doesn't count. Fresh renders get the per-text
    /// budget; a resume keeps `longestRenderS`. Injectable for tests.
    @ObservationIgnored var renderBudget: @MainActor (RenderJob) -> Duration = { job in
        if case let .fresh(text) = job.source {
            return .seconds(DaemonClient.renderTimeout(chars: text.count))
        }
        return .seconds(DaemonClient.longestRenderS)
    }
    /// Runs when a started render outlives its budget; nil = the default
    /// (`saveOverBudget`). Injectable for tests.
    @ObservationIgnored var onBudgetExceeded: (@MainActor (RenderJob) -> Void)? = nil
    @ObservationIgnored private var watchdog: Task<Void, Never>? = nil

    private var pumpTask: Task<Void, Never>? = nil

    // MARK: - Mutations (main-actor; driven from the UI)

    func enqueue(_ job: RenderJob) {
        // Dedupe a resume: a given draft must never be queued more than once.
        // The inline "Continue render" button is now always visible on a paused
        // draft row, so without this guard a repeated tap would stack the same
        // draft into the queue indefinitely (one item added infinitely).
        if case let .resume(ts) = job.source, hasResume(forTS: ts) {
            store?.reportError("That draft is already in the render queue.")
            return
        }
        jobs.append(job)
        startPumpIfIdle()
    }

    /// True if a resume for this draft `ts` is already queued or in flight — the
    /// guard the inline Continue-render button uses to disable itself so the same
    /// draft can't be enqueued twice.
    func hasResume(forTS ts: String) -> Bool { resumingTSs.contains(ts) }

    /// HistoryStore forwards this app's episode_start and every
    /// episode_complete; a completion counts only for the episode this job
    /// started.
    func noteEpisode(_ signal: HistoryStore.EpisodeSignal) {
        // pumpTask, not activeJobID: a completion can land while the pump
        // waits for the daemon after a dropped connection.
        guard pumpTask != nil else { return }
        switch signal {
        case .ownStarted(let id):
            attemptEpisodeID = id
            armWatchdog(episodeID: id)
        case .completed(let id): if id == attemptEpisodeID { attemptCompleted = true }
        }
    }

    /// The draft ts of every queued/active resume job. A draft being continued
    /// is BOTH a resume job here AND a still-undeleted resumable-draft entry, so
    /// the Rendering count/display dedupes the draft against this set (count
    /// unique items, don't show it in both UP NEXT and PAUSED).
    var resumingTSs: Set<String> {
        Set((jobs + failed).compactMap { if case let .resume(t) = $0.source { return t } else { return nil } })
    }

    /// Remove a WAITING job. The active head is never removable here — it's
    /// stopped via StreamingRenderControls (Pause / Stop Now / Delete).
    func remove(_ id: UUID) {
        guard id != activeJobID else { return }
        jobs.removeAll { $0.id == id }
        failed.removeAll { $0.id == id }
    }

    /// Put a failed job back at the end of the queue and render it again.
    func retry(_ id: UUID) {
        guard let idx = failed.firstIndex(where: { $0.id == id }) else { return }
        var job = failed.remove(at: idx)
        job.failure = nil
        jobs.append(job)
        startPumpIfIdle()
    }

    /// Reorder within the waiting tail. `source`/`destination` index into the
    /// WAITING list (what SwiftUI `.onMove` provides), NOT `jobs` — we splice
    /// them back in past the locked head so the in-flight render stays put.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let head = (activeJobID != nil) ? 1 : 0
        guard jobs.count > head else { return }
        var tail = Array(jobs[head...])
        tail.move(fromOffsets: source, toOffset: destination)
        jobs = Array(jobs[..<head]) + tail
    }

    /// Swap a waiting job's model (backend + voice) before it renders. No-op on
    /// the active head (its model is already locked into the in-flight POST).
    func setModel(_ id: UUID, backendID: String, voice: String) {
        guard id != activeJobID, let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].backendID = backendID
        jobs[idx].voice = voice
    }

    /// Toggle a waiting job's "play while rendering" override.
    func setPlayWhileRendering(_ id: UUID, _ on: Bool) {
        guard id != activeJobID, let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[idx].playWhileRendering = on
    }

    // MARK: - Serial pump

    private func startPumpIfIdle() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in await self?.pump() }
    }

    /// Drain the queue, one job at a time. Each render/resume POST blocks until
    /// that render is fully done, so the next job never starts early. The only
    /// await-free region (loop-condition recheck → `pumpTask = nil`) means an
    /// enqueue racing the drain either extends this loop or starts a fresh pump
    /// — never orphans a job.
    ///
    /// No outcome drops a job's text: a cancel (Delete) or success removes it;
    /// a daemon that can't be reached (down, stopped, restarting) keeps it at
    /// the head and retries once the daemon answers again; any other failure
    /// moves it to `failed`, where it stays with its text until Retry or Remove.
    private func pump() async {
        var transportFailures = 0
        while let head = jobs.first {
            activeJobID = head.id
            attemptEpisodeID = nil
            attemptCompleted = false
            // Silent batch unless this job opts into play-while-rendering.
            store?.pendingPlayIntent = head.playWhileRendering ? .whileRendering : .none
            let outcome = await attempt(head)
            watchdog?.cancel()
            watchdog = nil
            activeJobID = nil
            switch outcome {
            case .finished:
                transportFailures = 0
                jobs.removeAll { $0.id == head.id }
            case .failed(let message):
                transportFailures = 0
                store?.reportError("render failed: \(message)")
                moveToFailed(head.id, message: message)
            case .daemonUnreachable(let message):
                transportFailures += 1
                // Health says up but every POST still fails at the transport:
                // stop retrying this one and keep it with a Retry instead.
                if transportFailures > Self.maxTransportRetries {
                    transportFailures = 0
                    store?.reportError("render failed: \(message)")
                    moveToFailed(head.id, message: message)
                    continue
                }
                store?.reportError("voice-say daemon unreachable — '\(head.title)' stays queued and retries when it is back")
                await waitForDaemon(episodeMayBeRunning: attemptEpisodeID != nil)
                // The daemon finished this render before the connection
                // dropped (its episode_complete arrived): don't render it twice.
                if attemptCompleted {
                    transportFailures = 0
                    jobs.removeAll { $0.id == head.id }
                }
            }
        }
        pumpTask = nil
    }

    private enum Outcome { case finished, failed(String), daemonUnreachable(String) }

    private func attempt(_ head: RenderJob) async -> Outcome {
        do {
            switch head.source {
            case .fresh(let text):
                guard let backend = resolveBackend(head.backendID) else {
                    throw DaemonError.pipelineFailed(stage: "backend",
                                                     message: "unknown backend \(head.backendID)")
                }
                _ = try await renderer?.render(text: text, backend: backend, voice: head.voice,
                                               speed: head.speed, tags: head.tags,
                                               overlay: head.overlay)
            case .resume(let ts):
                _ = try await renderer?.resume(fromTS: ts)
            }
            return .finished
        } catch DaemonError.cancelled {
            // Cancelled mid-render (Delete pressed) — keep nothing, advance.
            return .finished
        } catch DaemonError.unreachable(let message) {
            return .daemonUnreachable(message)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Start the budget clock for the job in flight at its own episode_start.
    private func armWatchdog(episodeID: String) {
        watchdog?.cancel()
        guard let job = activeJob else { return }
        let budget = renderBudget(job)
        watchdog = Task { [weak self] in
            do { try await Task.sleep(for: budget) } catch { return }
            guard let self, self.activeJobID == job.id,
                  self.attemptEpisodeID == episodeID, !self.attemptCompleted else { return }
            if let handler = self.onBudgetExceeded { handler(job) } else { self.saveOverBudget(job) }
        }
    }

    /// Default over-budget action: say so and save-and-stop, keeping what has
    /// rendered as a draft (Continue render finishes it). The POST is left
    /// open rather than cancelled: once a stream render has started the
    /// daemon ignores a client hang-up and writes the row anyway, so a
    /// cancelled POST followed by Retry would render the text twice.
    private func saveOverBudget(_ job: RenderJob) {
        guard let store, store.streamingEpisode?.id == attemptEpisodeID else { return }
        store.reportError("'\(job.title)' ran past its render time budget — saving what is rendered as a draft; Continue render finishes it.")
        store.finalizeEpisode()
    }

    private func moveToFailed(_ id: UUID, message: String) {
        guard let idx = jobs.firstIndex(where: { $0.id == id }) else { return }
        var job = jobs.remove(at: idx)
        job.failure = message
        failed.append(job)
    }

    /// Hold the pump until the daemon answers /health again. When this job's
    /// episode had started, also wait until no episode is running, so a render
    /// the daemon carried on with after the connection dropped can finish (and
    /// its episode_complete land) before deciding whether to send it again.
    private func waitForDaemon(episodeMayBeRunning: Bool) async {
        waitingForDaemon = true
        defer { waitingForDaemon = false }
        while !Task.isCancelled, !jobs.isEmpty {
            try? await Task.sleep(for: retryPollInterval)
            let status = await daemonStatus()
            if status.up && !(episodeMayBeRunning && status.episodeRunning) { return }
        }
    }

    /// Consecutive transport failures on one job, with /health answering in
    /// between, before the job moves to `failed`.
    static let maxTransportRetries = 5

    /// What the pump needs from /health to decide when to retry.
    struct DaemonStatus: Equatable, Sendable {
        var up: Bool
        var episodeRunning: Bool
    }

    static func liveDaemonStatus() async -> DaemonStatus {
        guard let h = try? await DaemonClient.shared.health() else {
            return DaemonStatus(up: false, episodeRunning: false)
        }
        return DaemonStatus(up: h.status == "ok", episodeRunning: h.queue?.episodeRunningS != nil)
    }
}
