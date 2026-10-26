// Overlay writes against a fake daemon: optimistic mirrors roll back when the
// POST fails, and trashEntry hides the row before it moves the file, putting
// the row back (and saying so) when the Trash refuses.

import Foundation
import Testing
@testable import VoiceSay

@MainActor
@Suite("Overlay writes", .serialized)
struct OverlayWriteTests {

    /// Records every overlay POST; fails them while `failing` is set.
    final class FakeDaemon: @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [OverlayRequest] = []
        private var _failing = false
        var writes: [OverlayRequest] { lock.withLock { _writes } }
        var failing: Bool {
            get { lock.withLock { _failing } }
            set { lock.withLock { _failing = newValue } }
        }
        func write(_ req: OverlayRequest) throws {
            try lock.withLock {
                _writes.append(req)
                if _failing { throw DaemonError.unreachable("down") }
            }
        }
    }

    struct TrashRefused: Error {}

    /// A store with one row (ts "t1", audio at `audio`), fed through the same
    /// snapshot event the daemon sends; overlay POSTs go to `daemon`.
    private func store(daemon: FakeDaemon, audio: URL, overlay: String = "{}") throws -> HistoryStore {
        let s = HistoryStore(connect: false)
        s.overlayWriter = { _, req in try daemon.write(req) }
        let json = #"""
        {"id":1,"type":"snapshot","progress":{},
         "overlays":{"t1":\#(overlay)},
         "history":[{"ts":"t1","backend":"kokoro","archive_name":"\#(audio.lastPathComponent)",
                     "archive_path":"\#(audio.path)","text":"hello"}]}
        """#
        let ev = try #require(EventStreamReader.decodeEvent(name: "snapshot", data: json))
        s.apply(event: ev)
        return s
    }

    private func tempAudio() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overlay-test-\(UUID().uuidString).mp3")
        try Data([0]).write(to: url)
        return url
    }

    private func settle(_ cond: () -> Bool) async {
        for _ in 0..<200 {
            if cond() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a failed bookmark POST rolls the mirror back to the confirmed overlay")
    func bookmarkRollsBack() async throws {
        let daemon = FakeDaemon()
        daemon.failing = true
        let audio = try tempAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let s = try store(daemon: daemon, audio: audio)
        let e = try #require(s.entries.first)

        s.addBookmark(e, position: 0.5, note: "here")
        #expect(s.bookmarksFor(e).count == 1)          // optimistic
        await settle { s.lastError != nil }
        #expect(s.bookmarksFor(e).isEmpty)             // rolled back
        #expect(s.lastError?.contains("change undone") == true)
    }

    @Test("toggleStar is optimistic and rolls back on a failed POST")
    func starIsOptimisticAndRollsBack() async throws {
        let daemon = FakeDaemon()
        let audio = try tempAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let s = try store(daemon: daemon, audio: audio)
        let e = try #require(s.entries.first)
        let key = s.tagKey(for: e)

        s.toggleStar(e)
        #expect(s.starred.contains(key))
        s.toggleStar(e)                                // second click inside the round trip
        #expect(!s.starred.contains(key))
        await settle { daemon.writes.count == 2 }
        #expect(daemon.writes.map(\.starred) == [true, false])

        daemon.failing = true
        s.toggleStar(e)
        #expect(s.starred.contains(key))
        await settle { s.lastError != nil }
        #expect(!s.starred.contains(key))              // back to the confirmed (unstarred) overlay
    }

    @Test("trash: overlay first, then the file; the file leaves only after the row is hidden")
    func trashHidesThenMoves() async throws {
        let daemon = FakeDaemon()
        let audio = try tempAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let s = try store(daemon: daemon, audio: audio)
        let e = try #require(s.entries.first)
        var hiddenWhenRecycled: Bool? = nil
        var recycled: [URL] = []
        s.recycler = { url in
            hiddenWhenRecycled = daemon.writes.last?.deleted == true
            recycled.append(url)
        }

        await s.trashEntry(e)
        #expect(daemon.writes.map(\.deleted) == [true])
        #expect(recycled == [audio])
        #expect(hiddenWhenRecycled == true)
        #expect(s.deletedKeys.contains(s.tagKey(for: e)))
        #expect(s.lastError == nil)
    }

    @Test("trash: a failed overlay write moves nothing and says so")
    func trashOverlayFailureMovesNothing() async throws {
        let daemon = FakeDaemon()
        daemon.failing = true
        let audio = try tempAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let s = try store(daemon: daemon, audio: audio)
        let e = try #require(s.entries.first)
        var recycled = 0
        s.recycler = { _ in recycled += 1 }

        await s.trashEntry(e)
        #expect(recycled == 0)
        #expect(!s.deletedKeys.contains(s.tagKey(for: e)))
        #expect(s.lastError?.contains("nothing was moved") == true)
    }

    @Test("trash: a refused Trash un-hides the row and reports it")
    func trashRefusedRestoresRow() async throws {
        let daemon = FakeDaemon()
        let audio = try tempAudio()
        defer { try? FileManager.default.removeItem(at: audio) }
        let s = try store(daemon: daemon, audio: audio)
        let e = try #require(s.entries.first)
        s.recycler = { _ in throw TrashRefused() }

        await s.trashEntry(e)
        #expect(daemon.writes.map(\.deleted) == [true, false])
        #expect(!s.deletedKeys.contains(s.tagKey(for: e)))
        #expect(s.lastError?.contains("back in the list") == true)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }
}
