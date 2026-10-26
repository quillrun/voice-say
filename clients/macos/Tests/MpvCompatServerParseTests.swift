// Swift Testing port of the mpv IPC command parser tests. The parser under
// test IS the production code (`@testable import VoiceSay`), not a copy.

import Darwin
import Foundation
import os
import Testing
@testable import VoiceSay

@Suite("MpvCompatServer command parsing")
struct MpvCompatServerParseTests {

    @Test("cycle/pause parses to a 2-element command")
    func cyclePause() throws {
        let cmd = try #require(MpvCompatServer.parseCommand(line: #"{"command":["cycle","pause"]}"#))
        #expect(cmd.count == 2)
        #expect(cmd[0] as? String == "cycle")
        #expect(cmd[1] as? String == "pause")
    }

    @Test("seek keeps its negative number argument and relative mode")
    func seek() throws {
        let cmd = try #require(MpvCompatServer.parseCommand(line: #"{"command":["seek",-5,"relative"]}"#))
        #expect(cmd.count == 3)
        #expect(cmd[0] as? String == "seek")
        let n = (cmd[1] as? Double) ?? (cmd[1] as? Int).map(Double.init)
        #expect(n == -5.0)
        #expect(cmd[2] as? String == "relative")
    }

    @Test("set_property preserves the trailing bool")
    func setProperty() throws {
        let cmd = try #require(MpvCompatServer.parseCommand(line: #"{"command":["set_property","pause",true]}"#))
        #expect(cmd.count == 3)
        #expect(cmd[0] as? String == "set_property")
        #expect(cmd[1] as? String == "pause")
        #expect(cmd[2] as? Bool == true)
    }

    @Test("single-element quit parses")
    func quit() throws {
        let cmd = try #require(MpvCompatServer.parseCommand(line: #"{"command":["quit"]}"#))
        #expect(cmd.count == 1)
        #expect(cmd[0] as? String == "quit")
    }

    @Test("rejects malformed input", arguments: [
        "not json",                 // not JSON at all
        #"{"foo":"bar"}"#,          // missing the `command` field
        #"{"command":"toggle"}"#,   // `command` is not an array
        "",                          // empty line
    ])
    func rejectsMalformed(_ line: String) {
        #expect(MpvCompatServer.parseCommand(line: line) == nil)
    }

    @Test("sockets live in the per-user temp folder under stable names")
    func socketPath() {
        let dir = NSTemporaryDirectory()
        #expect(MpvCompatServer.defaultSocketPath == dir + "voice-sayapp.sock")
        #expect(MpvCompatServer.mpvSocketPath == dir + "voice-mpv.sock")
        #expect(!MpvCompatServer.defaultSocketPath.hasPrefix("/tmp/"))
    }

    @Test("a socket file nobody serves is stale and swept; a served one is live and kept")
    func staleProbe() throws {
        let path = TestSupport.socketPath()
        #expect(!MpvCompatServer.isLive(path))
        // A crashed owner leaves a bound-but-closed socket file behind.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { tup in
                tup.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strncpy($0, src, 103) }
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        close(fd)
        #expect(bound && FileManager.default.fileExists(atPath: path))
        #expect(!MpvCompatServer.isLive(path))
        MpvCompatServer.removeIfStale(path)
        #expect(!FileManager.default.fileExists(atPath: path))

        let server = MpvCompatServer(path: path) { _ in }
        server.start()
        defer { server.stop() }
        #expect(MpvCompatServer.isLive(path))
        MpvCompatServer.removeIfStale(path)
        #expect(FileManager.default.fileExists(atPath: path))
    }
}

@Suite("MpvCompatServer socket")
struct MpvCompatServerSocketTests {
    private func connectUnix(_ path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { tup in
                tup.withMemoryRebound(to: CChar.self, capacity: 104) { _ = strncpy($0, src, 103) }
            }
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        return ok ? fd : -1
    }

    /// stop() then start() at once must leave exactly one accept loop: the
    /// old loop exits on its stale generation even though `running` is true
    /// again and the new socket may reuse its fd number.
    @Test func restartLeavesOneAcceptLoop() async throws {
        let path = TestSupport.socketPath()
        // Hold the FIRST loop at its entry until the restart is done — the
        // race where the old loop next looks at the state after start().
        let entries = OSAllocatedUnfairLock(initialState: 0)
        let release = DispatchSemaphore(value: 0)
        let server = MpvCompatServer(path: path, loopEntered: {
            let n = entries.withLock { $0 += 1; return $0 }
            if n == 1 { release.wait() }
        }) { _ in }
        server.start()
        let entered = Date().addingTimeInterval(3)
        while entries.withLock({ $0 }) < 1 && Date() < entered {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try #require(entries.withLock({ $0 }) >= 1, "the server never started listening")
        server.stop()
        server.start()
        release.signal()

        let deadline = Date().addingTimeInterval(3)
        while server.liveAcceptLoops != 1 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(server.liveAcceptLoops == 1)

        server.stop()
        let gone = Date().addingTimeInterval(3)
        while server.liveAcceptLoops != 0 && Date() < gone {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(server.liveAcceptLoops == 0)
    }

    /// A client that connects and never closes must not block the next one:
    /// the receive timeout releases the single accept thread.
    @Test func silentClientDoesNotStallTheNext() async throws {
        let got = OSAllocatedUnfairLock(initialState: [String]())
        let path = TestSupport.socketPath()
        let server = MpvCompatServer(path: path) { cmd in
            let first = cmd.first as? String ?? ""
            got.withLock { $0.append(first) }
        }
        server.start()
        defer { server.stop() }

        let silent = connectUnix(path)
        #expect(silent >= 0)
        defer { close(silent) }

        let talker = connectUnix(path)
        #expect(talker >= 0)
        let line = #"{"command":["quit"]}"# + "\n"
        _ = line.withCString { write(talker, $0, strlen($0)) }
        close(talker)

        let deadline = Date().addingTimeInterval(4)
        while got.withLock({ $0.isEmpty }) && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(got.withLock { $0 } == ["quit"])
    }
}
