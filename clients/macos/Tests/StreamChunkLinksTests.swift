// The app's links keep a queued chunk playable after the daemon deletes its
// transient file at the final concat.

import Foundation
import Testing
@testable import VoiceSay

@Suite("Stream chunk links")
struct StreamChunkLinksTests {

    @Test("a retained chunk survives the daemon's unlink; release drops only the app's links")
    func survivesDaemonUnlink() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("chunk-links-\(UUID().uuidString)")
        let daemonTmp = base.appendingPathComponent("daemon"), links = base.appendingPathComponent("links")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: daemonTmp, withIntermediateDirectories: true)
        let chunk = daemonTmp.appendingPathComponent("vs-stream-ab12-0003-x.wav")
        try Data("RIFF-chunk".utf8).write(to: chunk)

        let held = StreamChunkLinks.retain(chunk, in: links)
        #expect(held != chunk)
        #expect(StreamChunkLinks.retain(chunk, in: links) == held)   // replayed chunk_ready

        try fm.removeItem(at: chunk)                                  // daemon's finally
        #expect(try Data(contentsOf: held) == Data("RIFF-chunk".utf8))

        StreamChunkLinks.release(in: links)
        #expect(!fm.fileExists(atPath: links.path))
    }

    @Test("a chunk already gone falls back to its own URL")
    func missingChunk() {
        let gone = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).wav")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-links-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(StreamChunkLinks.retain(gone, in: dir) == gone)
    }
}
