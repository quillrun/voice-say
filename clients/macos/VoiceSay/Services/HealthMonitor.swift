// HealthMonitor — THE liveness authority for the daemon + every TTS backend
// in the catalog. One app-level instance (injected in App.swift) feeds:
//   • the header's daemon pill (cheap 10 s poll, only while the header is
//     visible — startPillPolling/stopPillPolling),
//   • the Settings "Services" panel (refresh(_:) probes daemon + catalog),
// and survives Settings close/reopen instead of resetting to "unknown".
//
// Daemon liveness goes through DaemonClient.health() (respects the base-URL
// override); backend ports go through the shared PortProbe. DaemonController
// end-state probing uses PortProbe.httpOK directly (it needs an ephemeral
// session so a downed daemon's pooled connection can't bleed in).

import Foundation
import Observation

@MainActor
@Observable
final class HealthMonitor {
    enum State { case unknown, up, down }

    var daemon: State = .unknown
    var daemonVersion: String? = nil
    /// Backend up/down keyed by backend id — driven by the daemon catalog
    /// rather than a fixed set, so every backend the catalog names
    /// surfaces automatically.
    var backends: [String: State] = [:]
    /// The header pill's cheap signal. Optimistic start (true) so the pill
    /// isn't red for the instant before the first probe lands.
    private(set) var healthOK: Bool = true

    private var pillTask: Task<Void, Never>? = nil

    // MARK: - Header pill poll (daemon only, 10 s)

    /// Periodic /health cross-check so the daemon pill doesn't go stale
    /// green when SSE is on a half-open socket but the daemon is actually
    /// dead. Probes immediately, then every `interval` while running; cheap
    /// (one localhost GET) so it runs only while the header is visible.
    func startPillPolling(interval: TimeInterval = 10) {
        stopPillPolling()
        pillTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.probeDaemonOnce()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func stopPillPolling() {
        pillTask?.cancel()
        pillTask = nil
    }

    private func probeDaemonOnce() async {
        if let (state, version) = await probeDaemon() {
            daemon = state
            daemonVersion = version
            healthOK = (state == .up)
        }
    }

    // MARK: - Settings panel refresh (daemon + full catalog)

    /// Probe the daemon and each backend in the catalog concurrently.
    func refresh(_ catalog: [Backend]) async {
        async let d = probeDaemon()
        // Probe all backend ports in parallel, collect into a dict.
        let probed = await withTaskGroup(of: (String, State).self) { group in
            for b in catalog {
                group.addTask { (b.id, await Self.probeBackend(url: b.baseURL)) }
            }
            var out: [String: State] = [:]
            for await (id, state) in group { out[id] = state }
            return out
        }
        self.backends = probed
        if let (state, version) = await d {
            self.daemon = state
            self.daemonVersion = version
            self.healthOK = (state == .up)
        }
    }

    private func probeDaemon() async -> (State, String?)? {
        do {
            let h = try await DaemonClient.shared.health()
            return (h.status == "ok" ? .up : .down, h.version)
        } catch {
            return (.down, nil)
        }
    }

    /// Catalog-refresh liveness probe (2.0 s budget). Delegates to the shared
    /// `PortProbe` — "up" = any HTTP response at root (backends answer 200/404
    /// either way). Static + nonisolated so the concurrent task group can call
    /// it off the main actor.
    nonisolated static func probeBackend(url: URL?) async -> State {
        await PortProbe.answers(url: url, timeout: 2.0) ? .up : .down
    }
}
