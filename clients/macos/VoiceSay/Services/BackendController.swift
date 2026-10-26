// BackendController — start/stop a TTS backend's OS service from the app.
//
// The companion to DaemonController, generalized across the two ways a
// backend ships: a server registered as a LaunchAgent (e.g. mlx-audio's),
// driven via `launchctl bootstrap/bootout`; and a Docker container (e.g.
// Kokoro-FastAPI off Apple silicon), driven via `docker start/stop`.
// Which mechanism applies is read from the daemon-reported
// `Backend.service` descriptor (kind: "launchd" | "docker" | "none") rather
// than hardcoded here, so a private VOICE_SAY_BACKENDS_CONFIG overlay can
// remap labels without an app rebuild.
//
// Success is judged by the *observed end state* — we poll the backend's TCP
// port after the command — not by the tool's exit code, which is noisy
// across launchctl/docker/OS versions (same discipline as DaemonController).
//
// One controller instance backs the whole Settings list; per-backend action
// state lives in `actions` keyed by backend id, so each row reflects only
// its own in-flight / ok / failed status.

import Foundation
import Observation

@MainActor
@Observable
final class BackendController {
    /// Per-backend action state, keyed by `Backend.id`.
    private(set) var actions: [String: ServiceOutcome] = [:]

    /// Called on the main actor after any action settles (ok or failed) so
    /// the host view can re-probe service status. Set by the owner. Not a UI
    /// property — @ObservationIgnored so assigning it doesn't churn observers.
    @ObservationIgnored var onSettled: (() -> Void)?

    func action(for id: String) -> ServiceOutcome { actions[id] ?? .idle }

    /// True when this backend exposes a control the app can drive. Rows for
    /// `none`/missing descriptors show status only (no Start/Stop buttons).
    static func isManageable(_ backend: Backend) -> Bool {
        switch backend.service?.kind {
        case "launchd", "docker": return true
        default: return false
        }
    }


    func start(_ backend: Backend) { run(backend, start: true) }
    func stop(_ backend: Backend)  { run(backend, start: false) }


    private func run(_ backend: Backend, start: Bool) {
        guard let svc = backend.service else {
            actions[backend.id] = .failed("backend not client-managed")
            return
        }
        let id = backend.id
        let port = backend.port
        let verb = start ? "start" : "stop"
        actions[id] = .running

        Task.detached { [weak self] in
            let cmd: ProcessRun
            switch svc.kind {
            case "launchd":
                cmd = Self.runLaunchd(start: start, label: svc.label, plist: svc.plistPath)
            case "docker":
                cmd = Self.runDocker(start: start, container: svc.container ?? svc.composeService)
            default:
                cmd = .fail("unsupported service kind \(svc.kind)")
            }

            // Confirm via the observed end state. Backends take a few seconds
            // to bind their port after launch (model import); shutdown is
            // near-instant. Poll up to ~20 s for start, ~6 s for stop.
            let finalUp = await ProcessRun.pollState(until: start, within: start ? 20.0 : 6.0,
                                                     everyNs: 400_000_000) {
                await Self.probePort(port)
            }
            guard let self else { return }
            await MainActor.run {
                if finalUp == start {
                    self.actions[id] = .ok(start ? "\(verb) ok — up" : "\(verb) ok — stopped")
                } else {
                    self.actions[id] = .failed("\(verb) failed: \(cmd.detail(stillUp: finalUp))")
                }
                self.onSettled?()
            }
        }
    }

    // launchctl bootstrap gui/UID <plist>  /  bootout gui/UID/<label>
    nonisolated private static func runLaunchd(start: Bool,
                                               label: String?,
                                               plist: String?) -> ProcessRun {
        guard let label else { return .fail("no launchd label in service descriptor") }
        let target = "gui/\(getuid())"
        let args: [String]
        if start {
            guard let plist, FileManager.default.fileExists(atPath: plist) else {
                return .fail("plist not installed at \(plist ?? "~/Library/LaunchAgents/\(label).plist") — run the bootstrap script first")
            }
            args = ["bootstrap", target, plist]
        } else {
            args = ["bootout", "\(target)/\(label)"]
        }
        return ProcessRun.run(URL(fileURLWithPath: "/bin/launchctl"), args)
    }

    // docker start/stop <container>. By container name (created once by
    // `docker compose up`) so we don't need the repo's compose file path.
    nonisolated private static func runDocker(start: Bool,
                                              container: String?) -> ProcessRun {
        guard let container, !container.isEmpty else {
            return .fail("no docker container in service descriptor")
        }
        guard let docker = dockerPath() else {
            return .fail("docker not found on PATH — is Docker installed/running?")
        }
        return ProcessRun.run(docker, [start ? "start" : "stop", container])
    }

    /// docker from Homebrew arm64/x86 or Docker Desktop.
    nonisolated private static func dockerPath() -> URL? {
        ProcessRun.firstExecutable([
            "/opt/homebrew/bin/docker",
            "/usr/local/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ])
    }

    /// Liveness poll for the start/stop confirmation loop (1.5 s per probe —
    /// backends need several to bind their port after launch). Delegates to the
    /// shared `PortProbe`; "up" = any HTTP response, transport failure = down.
    nonisolated private static func probePort(_ port: Int) async -> Bool {
        await PortProbe.answers(port: port, timeout: 1.5)
    }
}
