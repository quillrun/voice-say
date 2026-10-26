// RenderQueue tests — the serial pump + the head-locked reorder/remove
// contract, exercised with a fake RenderRunning (no daemon). The fake is
// "gated" (each render blocks until the test releases it) so the in-flight
// head can be inspected and the reorder/remove rules asserted deterministically.

import Foundation
import Testing
@testable import VoiceSay

@MainActor
@Suite("RenderQueue", .serialized)
struct RenderQueueTests {

    /// Minimal Backend so the pump's resolver can hand one to the renderer.
    private func backend(_ id: String) -> Backend {
        Backend(id: id, label: id, port: 0, defaultVoice: "v",
                voices: ["v"], supportsSpeed: false, accent: "#888888", service: nil)
    }

    private func freshQueue(_ renderer: any RenderRunning) -> RenderQueue {
        let q = RenderQueue()
        q.renderer = renderer
        q.resolveBackend = { [self] id in backend(id) }
        q.retryPollInterval = .milliseconds(5)
        q.daemonStatus = { .init(up: true, episodeRunning: false) }
        return q
    }

    private func waitUntil(_ cond: () -> Bool) async {
        for _ in 0..<400 {
            if cond() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func freshJob(_ backendID: String) -> RenderJob {
        RenderJob(source: .fresh(text: "hello \(backendID)"),
                  backendID: backendID, voice: "v", title: backendID)
    }

    /// Poll until the queue is idle (drained) or a bounded number of ticks pass.
    private func waitUntilIdle(_ q: RenderQueue) async {
        for _ in 0..<400 {
            if q.jobs.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func waitUntilActive(_ q: RenderQueue) async {
        for _ in 0..<400 {
            if q.activeJobID != nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Fakes

    /// Whether the fake daemon answers /health.
    final class DaemonFlag { var up = false }

    /// Renders return immediately; records the backend order it was asked to run.
    final class ImmediateRenderer: RenderRunning {
        private(set) var renderedBackends: [String] = []
        private(set) var resumedTS: [String] = []
        /// Per-call outcome by backend id — defaults to success.
        var outcomeFor: [String: DaemonError] = [:]
        /// Outcomes for the next calls, consumed in order before `outcomeFor`
        /// (nil = success).
        var scripted: [DaemonError?] = []
        /// Runs inside each render, before its outcome (e.g. to deliver SSE).
        var during: (@MainActor () -> Void)? = nil

        func render(text: String, backend: Backend, voice: String, speed: Double,
                    tags: [String], overlay: RenderOverlay) async throws -> String {
            renderedBackends.append(backend.id)
            await Task.yield()
            during?()
            if !scripted.isEmpty, let err = scripted.removeFirst() { throw err }
            if let err = outcomeFor[backend.id] { throw err }
            return "archive-\(backend.id)"
        }
        func resume(fromTS ts: String) async throws -> String {
            resumedTS.append(ts)
            await Task.yield()
            return "archive-resume"
        }
    }

    /// Each render blocks until `releaseNow()` is called, so a test can inspect
    /// the in-flight head and the waiting tail.
    final class GatedRenderer: RenderRunning {
        private(set) var renderedBackends: [String] = []
        private var cont: CheckedContinuation<Void, Never>? = nil

        func render(text: String, backend: Backend, voice: String, speed: Double,
                    tags: [String], overlay: RenderOverlay) async throws -> String {
            renderedBackends.append(backend.id)
            await withCheckedContinuation { c in self.cont = c }
            return "archive-\(backend.id)"
        }
        func resume(fromTS ts: String) async throws -> String { "archive-resume" }

        func releaseNow() { cont?.resume(); cont = nil }
    }

    // MARK: - Tests

    @Test("drains serially, in order, each on its own backend (model swap)")
    func serialInOrderPerModel() async {
        let fake = ImmediateRenderer()
        let q = freshQueue(fake)

        q.enqueue(freshJob("qwen3"))
        q.enqueue(freshJob("kokoro"))
        q.enqueue(freshJob("remote"))

        await waitUntilIdle(q)
        #expect(q.jobs.isEmpty)
        #expect(q.activeJobID == nil)
        // Strict order + each ran on its OWN backend — the per-item model.
        #expect(fake.renderedBackends == ["qwen3", "kokoro", "remote"])
    }

    @Test("head is locked: reorder + remove operate only on the waiting tail")
    func headLockedReorderRemove() async {
        let fake = GatedRenderer()
        let q = freshQueue(fake)

        let j1 = freshJob("qwen3"), j2 = freshJob("kokoro"), j3 = freshJob("remote")
        q.enqueue(j1); q.enqueue(j2); q.enqueue(j3)
        await waitUntilActive(q)

        // j1 is the locked head; j2,j3 are the reorderable tail.
        #expect(q.activeJobID == j1.id)
        #expect(q.waiting.map(\.id) == [j2.id, j3.id])

        // Reorder the tail: move j3 (tail index 1) before j2 (tail index 0).
        q.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(q.jobs.first?.id == j1.id)              // head unchanged
        #expect(q.waiting.map(\.id) == [j3.id, j2.id])  // tail reordered

        // The head can't be removed here, nor its model changed.
        q.remove(j1.id)
        #expect(q.jobs.first?.id == j1.id)
        q.setModel(j1.id, backendID: "kokoro", voice: "v")
        #expect(q.jobs.first?.backendID == "qwen3")

        // A waiting job can be removed and re-modelled.
        q.remove(j2.id)
        #expect(q.waiting.map(\.id) == [j3.id])
        q.setModel(j3.id, backendID: "mlx-swift", voice: "Ryan")
        #expect(q.jobs.first(where: { $0.id == j3.id })?.backendID == "mlx-swift")

        // Drain the gated renders.
        for _ in 0..<8 {
            if q.jobs.isEmpty { break }
            fake.releaseNow()
            try? await Task.sleep(for: .milliseconds(10))
        }
        await waitUntilIdle(q)
        #expect(q.jobs.isEmpty)
    }

    @Test("a cancelled render is discarded and the queue advances")
    func advancesOnCancel() async {
        let fake = ImmediateRenderer()
        fake.outcomeFor["qwen3"] = .cancelled(episodeID: "ep")
        let q = freshQueue(fake)

        q.enqueue(freshJob("qwen3"))   // will "cancel"
        q.enqueue(freshJob("kokoro"))  // must still run

        await waitUntilIdle(q)
        #expect(q.jobs.isEmpty)
        #expect(fake.renderedBackends == ["qwen3", "kokoro"])
    }

    @Test("a failed render keeps its text under failed, the queue advances, Retry renders it again")
    func failedRenderIsKeptWithRetry() async {
        let fake = ImmediateRenderer()
        fake.outcomeFor["qwen3"] = .pipelineFailed(stage: "tts", message: "backend 500")
        let q = freshQueue(fake)

        let bad = freshJob("qwen3")
        q.enqueue(bad)                 // will error
        q.enqueue(freshJob("kokoro"))  // must still run

        await waitUntilIdle(q)
        #expect(q.jobs.isEmpty)
        #expect(fake.renderedBackends == ["qwen3", "kokoro"])
        // Not dropped: kept with its text and the error.
        #expect(q.failed.map(\.id) == [bad.id])
        #expect(q.failed.first?.freshText == "hello qwen3")
        #expect(q.failed.first?.failure == "tts: backend 500")

        fake.outcomeFor = [:]
        q.retry(bad.id)
        #expect(q.failed.isEmpty)
        await waitUntilIdle(q)
        #expect(fake.renderedBackends == ["qwen3", "kokoro", "qwen3"])
        #expect(q.failed.isEmpty)
    }

    @Test("daemon unreachable: the head and the rest stay queued, then render once /health answers")
    func unreachableWaitsForDaemonAndRetries() async {
        let fake = ImmediateRenderer()
        fake.scripted = [.unreachable("Could not connect to the server.")]
        let q = freshQueue(fake)
        let daemon = DaemonFlag()
        q.daemonStatus = { .init(up: daemon.up, episodeRunning: false) }

        q.enqueue(freshJob("qwen3"))
        q.enqueue(freshJob("kokoro"))

        await waitUntil { q.waitingForDaemon }
        #expect(q.waitingForDaemon)
        #expect(q.jobs.map(\.backendID) == ["qwen3", "kokoro"])   // nothing dropped
        #expect(q.failed.isEmpty)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(fake.renderedBackends == ["qwen3"])               // no retry while down

        daemon.up = true
        await waitUntilIdle(q)
        #expect(q.jobs.isEmpty)
        #expect(!q.waitingForDaemon)
        #expect(fake.renderedBackends == ["qwen3", "qwen3", "kokoro"])
    }

    @Test("connection lost after the daemon finished the episode: the job is not rendered twice")
    func unreachableAfterCompletionIsNotResent() async {
        let fake = ImmediateRenderer()
        let q = freshQueue(fake)
        fake.scripted = [.unreachable("The network connection was lost.")]
        fake.during = {
            q.noteEpisode(.ownStarted("ep1"))
            q.noteEpisode(.completed("ep1"))
        }
        q.enqueue(freshJob("qwen3"))

        await waitUntilIdle(q)
        #expect(q.jobs.isEmpty)
        #expect(q.failed.isEmpty)
        #expect(fake.renderedBackends == ["qwen3"])
    }

    @Test("a daemon that answers /health but drops every POST: the job ends under failed, not in a loop")
    func persistentTransportFailureEndsInFailed() async {
        let fake = ImmediateRenderer()
        fake.outcomeFor["qwen3"] = .unreachable("reset")
        let q = freshQueue(fake)

        q.enqueue(freshJob("qwen3"))
        await waitUntilIdle(q)
        #expect(q.jobs.isEmpty)
        #expect(q.failed.count == 1)
        #expect(fake.renderedBackends.count == RenderQueue.maxTransportRetries + 1)
    }

    @Test("the render budget starts at this app's episode_start: waiting at the daemon's gate doesn't count; over budget saves, the POST stays open")
    func budgetStartsAtOwnEpisodeStart() async {
        let fake = GatedRenderer()
        let q = freshQueue(fake)
        var exceeded: [UUID] = []
        q.renderBudget = { _ in .milliseconds(20) }
        q.onBudgetExceeded = { exceeded.append($0.id) }

        let job = freshJob("qwen3")
        q.enqueue(job)
        await waitUntilActive(q)
        // Queued behind another client's render: no episode_start yet.
        try? await Task.sleep(for: .milliseconds(80))
        #expect(exceeded.isEmpty)

        q.noteEpisode(.ownStarted("ep1"))
        await waitUntil { !exceeded.isEmpty }
        #expect(exceeded == [job.id])
        #expect(q.activeJobID == job.id)          // not cancelled: still in flight

        fake.releaseNow()
        await waitUntilIdle(q)
        #expect(q.jobs.isEmpty)
        #expect(q.failed.isEmpty)
        #expect(fake.renderedBackends == ["qwen3"])
        #expect(exceeded == [job.id])
    }

    @Test("a render that finishes inside its budget never trips the watchdog")
    func finishedRenderDisarmsWatchdog() async {
        let fake = GatedRenderer()
        let q = freshQueue(fake)
        var exceeded = 0
        q.renderBudget = { _ in .milliseconds(40) }
        q.onBudgetExceeded = { _ in exceeded += 1 }

        q.enqueue(freshJob("qwen3"))
        await waitUntilActive(q)
        q.noteEpisode(.ownStarted("ep1"))
        fake.releaseNow()
        await waitUntilIdle(q)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(exceeded == 0)
    }

    @Test("budgets: a fresh render gets the per-text budget, a resume the longest render")
    func defaultBudgets() {
        let q = RenderQueue()
        let fresh = RenderJob(source: .fresh(text: String(repeating: "a", count: 40_000)),
                              backendID: "b", voice: "v", title: "t")
        let resume = RenderJob(source: .resume(fromTS: "1"), backendID: "b", voice: "v", title: "t")
        #expect(q.renderBudget(fresh) == .seconds(4000))
        #expect(q.renderBudget(resume) == .seconds(DaemonClient.longestRenderS))
    }

    @Test("a resume job routes through resume(), serialized with fresh renders")
    func resumeRoutesThroughResume() async {
        let fake = ImmediateRenderer()
        let q = freshQueue(fake)

        q.enqueue(freshJob("qwen3"))
        q.enqueue(RenderJob(source: .resume(fromTS: "1700000000.5"),
                            backendID: "qwen3", voice: "v", title: "draft"))

        await waitUntilIdle(q)
        #expect(fake.renderedBackends == ["qwen3"])
        #expect(fake.resumedTS == ["1700000000.5"])
    }
}
