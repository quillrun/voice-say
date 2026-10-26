// MpvCompatServer — listens on a Unix domain socket and accepts a small
// subset of mpv's JSON-line IPC, dispatching to AudioPlayer. This lets
// external controllers (a global hotkey → voice-ctl) drive the app's
// AVAudioPlayer the same way they drive the CLI's mpv.
//
// Wire protocol — mpv-compatible, one JSON object per line:
//   {"command":["cycle","pause"]}                  → togglePlay
//   {"command":["seek", <±N>, "relative"]}         → skip(by: ±N)
//   {"command":["set_property","pause", true]}     → ensure paused
//   {"command":["set_property","pause", false]}    → ensure playing
//   {"command":["quit"]}                           → stop
//
// Socket path: voice-sayapp.sock in the per-user temp folder (what
// `getconf DARWIN_USER_TEMP_DIR` prints), or $VOICESAY_APP_SOCKET. It is
// distinct from the CLI mpv's voice-mpv.sock in the same folder so VoiceSay
// and the CLI's mpv can coexist briefly during handoff. voice-ctl tries the mpv
// path first, then this one — both speak the same protocol, and it honours the
// same variable. Per-user rather than /tmp: another account can't pre-create
// or reach it.

import Foundation
import Darwin
import os

final class MpvCompatServer: @unchecked Sendable {
    static let socketPath = ProcessInfo.processInfo.environment["VOICESAY_APP_SOCKET"]
        ?? defaultSocketPath
    static let defaultSocketPath = userTempPath("voice-sayapp.sock")
    /// The CLI's mpv IPC socket (voice-ctl's first choice).
    static let mpvSocketPath = userTempPath("voice-mpv.sock")

    /// `name` in the per-user temp folder. NSTemporaryDirectory() is that
    /// folder for an unsandboxed app and ignores $TMPDIR, so it matches the
    /// CLI's `getconf DARWIN_USER_TEMP_DIR`.
    static func userTempPath(_ name: String) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
    }

    // `running`/`serverFd`/`generation`/`loops` cross threads (caller
    // start/stop vs. the accept loop) — every access goes through `stateLock`
    // so the accept thread never reads a torn/stale value (@unchecked Sendable
    // is earned, not asserted).
    private let stateLock = OSAllocatedUnfairLock()
    private var serverFd: Int32 = -1   // guarded by stateLock
    private var running = false        // guarded by stateLock
    /// Bumped by every start and stop. An accept loop runs only while the
    /// generation it was started under is current: a stop followed at once
    /// by a start must not leave the old loop alive (the `running` flag is
    /// true again, and the new socket can reuse the old fd number).
    private var generation: UInt64 = 0 // guarded by stateLock
    private var loops = 0              // guarded by stateLock
    /// Accept loops currently alive (test-visible; one at most once settled).
    var liveAcceptLoops: Int { stateLock.withLock { loops } }
    private var acceptThread: Thread?  // main-thread only (start/stop/deinit)
    // `sending`: each parsed command is freshly built and handed off (never
    // retained by the server), so it can cross the isolation boundary into the
    // handler's @MainActor Task without a data race under Swift 6.
    private let onCommand: @Sendable (sending [Any]) -> Void
    private let path: String   // `socketPath` in the app; a temp path in tests
    /// Test seam: runs on the accept thread as each loop begins, so a test
    /// can hold a loop there across a restart. nil in the app.
    private let loopEntered: (@Sendable () -> Void)?

    init(path: String = MpvCompatServer.socketPath,
         loopEntered: (@Sendable () -> Void)? = nil,
         onCommand: @escaping @Sendable (sending [Any]) -> Void) {
        self.path = path
        self.loopEntered = loopEntered
        self.onCommand = onCommand
    }

    deinit { _stopUnsafe() }

    func start() {
        guard !stateLock.withLock({ running }) else { return }
        // Another running copy of the app owns a live socket here; taking it
        // over would leave that copy's controls dead. Only a stale file goes.
        if Self.isLive(path) {
            Log.ipc.info("\(self.path, privacy: .public) is served by another process; not taking it over")
            return
        }
        unlink(path)
        guard var addr = Self.address(path) else { return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Log.ipc.error("socket() failed errno=\(errno)")
            return
        }
        let bindSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindOK = withUnsafePointer(to: &addr) { ap -> Bool in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.bind(fd, sap, bindSize) == 0
            }
        }
        guard bindOK else {
            Log.ipc.error("bind() failed errno=\(errno)")
            close(fd)
            return
        }
        guard listen(fd, 4) == 0 else {
            Log.ipc.error("listen() failed errno=\(errno)")
            close(fd)
            unlink(path)
            return
        }
        chmod(path, 0o600)

        let gen: UInt64 = stateLock.withLock {
            serverFd = fd
            running = true
            generation &+= 1
            loops += 1
            return generation
        }
        let thr = Thread { [weak self] in self?.acceptLoop(fd: fd, generation: gen) }
        thr.name = "MpvCompatServer.accept"
        thr.start()
        acceptThread = thr
        Log.ipc.info("listening at \(self.path, privacy: .public)")
    }

    func stop() {
        _stopUnsafe()
    }

    private func _stopUnsafe() {
        // Flip the flag and take the fd under the lock, then tear the socket
        // down outside it — shutdown() unblocks the accept thread, which then
        // observes running == false and exits.
        let fd: Int32 = stateLock.withLock {
            running = false
            generation &+= 1
            let f = serverFd
            serverFd = -1
            return f
        }
        if fd >= 0 {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        unlink(path)
        acceptThread = nil
    }

    private func acceptLoop(fd: Int32, generation myGen: UInt64) {
        defer { stateLock.withLock { loops -= 1 } }
        loopEntered?()
        let current = { self.stateLock.withLock { self.generation == myGen } }
        while current() {
            let cfd = Darwin.accept(fd, nil, nil)
            if cfd < 0 {
                if !current() { break }
                continue
            }
            // mpv's voice-ctl sends one JSON line and closes; we read until
            // EOF (small messages) and dispatch each newline-separated line.
            // Clients are served inline on this one thread, so a 1 s receive
            // timeout keeps a client that never closes from stalling the rest.
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                       socklen_t(MemoryLayout<timeval>.size))
            var buf = [UInt8](repeating: 0, count: 4096)
            var acc = Data()
            while true {
                let n = Darwin.read(cfd, &buf, buf.count)
                if n <= 0 { break }
                acc.append(contentsOf: buf.prefix(n))
                if acc.count > 1 << 16 { break }  // safety
            }
            Darwin.close(cfd)
            guard let text = String(data: acc, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                dispatch(line: String(line))
            }
        }
    }

    private func dispatch(line: String) {
        guard let cmd = Self.parseCommand(line: line) else { return }
        onCommand(cmd)
    }

    /// A `sockaddr_un` for `path`; nil when the path is too long for one.
    private static func address(_ path: String) -> sockaddr_un? {
        guard path.utf8.count < 104 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { tup in
                tup.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                    _ = strncpy(dst, src, 103)
                }
            }
        }
        return addr
    }

    /// True when something accepts connections at `path`. A socket file left
    /// by a crashed process refuses them, so this tells stale from in use.
    /// Connecting and closing is harmless to a server: it reads EOF and
    /// dispatches nothing.
    static func isLive(_ path: String) -> Bool {
        guard var addr = address(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withUnsafePointer(to: &addr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sap in
                Darwin.connect(fd, sap, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    /// Remove the socket file at `path` only if nothing is serving it.
    static func removeIfStale(_ path: String) {
        if !isLive(path) { unlink(path) }
    }

    /// Pure parse — exposed so the test target can verify shapes without
    /// touching the socket / actor / NotificationCenter machinery.
    /// Returns the `command` array from a one-line mpv-style JSON object,
    /// or nil if the line is malformed or missing the field.
    static func parseCommand(line: String) -> [Any]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["command"] as? [Any]
        else { return nil }
        return cmd
    }
}
