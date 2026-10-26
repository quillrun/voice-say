import Foundation

/// Result of running an external process: combined stdout+stderr on a clean
/// exit, else a human-readable "exit N: …" detail (or a spawn-failure message).
/// Shared two-case type + runner for the service controllers (launchctl /
/// docker) — neither needs `Result<String, Error>`'s Error dressing; both flow
/// plain message strings.
enum ProcessRun {
    case ok(String)
    case fail(String)

    /// Run `exe` with `args`, capturing stdout+stderr. `.ok(out)` on exit 0,
    /// else `.fail(detail)` on a non-zero exit or a spawn failure. Synchronous
    /// — call off the main actor. Both streams share one pipe that is drained
    /// to EOF *before* `waitUntilExit`: waiting first deadlocks once the child
    /// fills the ~64 KB pipe buffer and blocks on write.
    static func run(_ exe: URL, _ args: [String]) -> ProcessRun {
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch {
            return .fail("\(exe.lastPathComponent) spawn failed: \(error.localizedDescription)")
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        proc.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        if proc.terminationStatus == 0 { return .ok(out) }
        let combined = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return .fail(combined.isEmpty ? "exit \(proc.terminationStatus)"
                                      : "exit \(proc.terminationStatus): \(combined)")
    }

    /// First executable among `paths`. A spawned Process does not inherit the
    /// login-shell PATH, so tools are resolved from their usual install spots.
    static func firstExecutable(_ paths: [String]) -> URL? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Failure detail once the end-state poll missed: the command's own
    /// output or error, else "still up" / "still down".
    func detail(stillUp: Bool) -> String {
        switch self {
        case .ok(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "still \(stillUp ? "up" : "down")" : t
        case .fail(let m):
            return m
        }
    }

    /// Poll `probe` until it returns `want` or `seconds` pass; returns the last
    /// observed state. Service control judges success by this end state, not
    /// by the tool's exit code (noisy across launchctl/docker/OS versions).
    static func pollState(until want: Bool, within seconds: TimeInterval, everyNs: UInt64,
                          _ probe: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        var state = await probe()
        while state != want && Date() < deadline {
            try? await Task.sleep(nanoseconds: everyNs)
            state = await probe()
        }
        return state
    }
}

/// UI state of one service-control action (daemon or backend start/stop).
enum ServiceOutcome: Equatable {
    case idle
    case running   // operation in flight
    case ok(String)
    case failed(String)
}
