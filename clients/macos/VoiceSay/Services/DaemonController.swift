// DaemonController — shell out to /bin/launchctl to start, stop, or
// restart the voice-say LaunchAgent. The daemon has KeepAlive=true in its
// plist, so "stopping" via `kill` would just respawn it — `bootout` is
// what actually takes it offline.
//
// These calls never block the main actor: every Process invocation is
// dispatched off-main and the @Observable `lastAction` field carries
// the human-readable result back so the UI can show a toast/badge.
//
// Why not go through the daemon itself: the daemon is what we're starting
// and stopping. It can't unload itself reliably, and we need a path that
// works when the daemon is already down (to start it).

import Foundation
import Observation

@MainActor
@Observable
final class DaemonController {
    private(set) var lastAction: ServiceOutcome = .idle

    static let serviceLabel = "local.voicesay.daemon"
    static var serviceTarget: String { "gui/\(getuid())/\(serviceLabel)" }
    static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(serviceLabel).plist"
    }
    static var domainTarget: String { "gui/\(getuid())" }

    /// True when the LaunchAgent these controls drive is installed. The
    /// documented install runs the daemon with `make run` instead, and then
    /// launchctl has nothing to start, stop or restart.
    static var agentInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    /// How to start the daemon, for the banners.
    static var startHint: String {
        agentInstalled ? "start it from Settings › Services"
                       : "start it with \"make run\" in the voice-say repo"
    }

    /// `launchctl bootstrap gui/UID <plist>` — loads + runs the agent.
    /// Desired end state: daemon `/health` returns 200.
    func start() {
        run(action: "start", args: ["bootstrap", Self.domainTarget, Self.plistPath],
            expectUp: true)
    }

    /// `launchctl bootout gui/UID/<label>` — unloads the agent. The
    /// KeepAlive flag in the plist is bypassed by bootout (vs `kill`
    /// which would just respawn).
    func stop() {
        run(action: "stop", args: ["bootout", Self.serviceTarget],
            expectUp: false)
    }

    /// `launchctl kickstart -k gui/UID/<label>` — bounce in place. Fast
    /// and the right choice when the agent is already loaded but you
    /// want to pick up new code.
    func restart() {
        run(action: "restart", args: ["kickstart", "-k", Self.serviceTarget],
            expectUp: true, needsExitOK: true)
    }

    /// Run a launchctl invocation and report success/failure based on the
    /// *observed end state* (probe `/health` after) rather than launchctl's
    /// exit code. macOS launchctl exit codes for "already in desired state"
    /// vary across OS versions; the probe is the authoritative signal.
    /// Except for a restart (`needsExitOK`): a daemon that was up stays up
    /// when kickstart fails, so only launchctl's own status says it worked.
    ///
    /// Two timing realities the polling handles:
    ///  - After bootout, launchd can take ~2 s to release. A second
    ///    bootstrap during that window returns "Input/output error (5)".
    ///    On that exact error, we wait and retry the bootstrap once.
    ///  - After bootstrap, the python daemon takes ~3–4 s to import +
    ///    bind :8890. /health 200 is what tells us it's actually ready.
    private func run(action: String, args: [String], expectUp: Bool, needsExitOK: Bool = false) {
        lastAction = .running
        // Strong capture — DaemonController is a long-lived @Observable
        // living in the app environment (App.swift); no retain cycle
        // concern, and Swift 6 rejects `weak self` rebound across
        // `MainActor.run` boundaries.
        Task.detached { [self] in
            var lastCmd = Self.invokeLaunchctl(args: args)
            // Recover from the launchd post-bootout release race. The
            // window where bootstrap returns "Input/output error (5)"
            // can be as long as ~8 s after a bootout. Two retries of
            // 6 s each cap total wait around 12 s before we give up.
            if args.first == "bootstrap" {
                for _ in 0..<2 {
                    guard case .fail(let m) = lastCmd,
                          m.contains("Input/output error") else { break }
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    lastCmd = Self.invokeLaunchctl(args: args)
                }
            }
            // Poll /health up to ~20 s for the desired end state.
            // Bootstrap → python-up takes 3–13 s in practice (aiohttp +
            // mutagen imports under the venv's interpreter, plus state
            // hydration from voice-history.jsonl on cold start). Bootout
            // → no-bind is sub-second. The loop converges either way.
            let finalHealthy = await ProcessRun.pollState(until: expectUp, within: 20.0,
                                                          everyNs: 300_000_000) {
                await Self.probeHealthy()
            }
            let finalCmd = lastCmd   // immutable snapshot for the @MainActor closure
            await MainActor.run {
                if needsExitOK, case .fail(let m) = finalCmd {
                    self.lastAction = .failed("\(action) failed: \(m)")
                } else if finalHealthy == expectUp {
                    self.lastAction = .ok(expectUp ? "\(action) ok — daemon up"
                                                   : "\(action) ok — daemon stopped")
                } else {
                    self.lastAction = .failed("\(action) timeout: \(finalCmd.detail(stillUp: finalHealthy))")
                }
            }
        }
    }

    /// One-shot health probe used by `run` to confirm end state. Goes through
    /// PortProbe.httpOK — a fresh ephemeral session (not DaemonClient.shared's
    /// pooled session) so a stale connection on a down daemon doesn't bleed
    /// in — while honoring the configured base URL, so a "say.mcp.base.url"
    /// override is respected here too.
    nonisolated private static func probeHealthy() async -> Bool {
        await PortProbe.httpOK(url: DaemonClient.shared.baseURL.appending(path: "/health"),
                               timeout: 1.5)
    }

    /// `run` re-probes /health to decide success/failure, so launchctl's
    /// "already loaded" exit codes (which vary by macOS version) need no
    /// special-casing — ProcessRun just passes stdout/stderr + exit detail along.
    nonisolated private static func invokeLaunchctl(args: [String]) -> ProcessRun {
        ProcessRun.run(URL(fileURLWithPath: "/bin/launchctl"), args)
    }
}
