// The archive fallback lookup caches hits and misses; a cached file that has
// since gone to the Trash must not resolve as playable, and a miss must not
// re-walk the tree on every call.

import Foundation
import Testing
@testable import VoiceSay

@Suite("Archive lookup cache")
struct ArchiveLookupTests {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-lookup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("a cached file moved out of the archive (Trash) no longer resolves; one moved within it is found again")
    func trashedHitIsEvicted() throws {
        let root = try tempDir(), trash = try tempDir()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: trash) }
        let name = "voice-\(UUID().uuidString).mp3"
        let sub = root.appendingPathComponent("2026/10", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let file = sub.appendingPathComponent(name)
        try Data([0]).write(to: file)

        let first = try #require(VoiceEntry.archiveLookup(name: name, root: root))
        #expect(first.lastPathComponent == name)

        let other = root.appendingPathComponent(name)
        try FileManager.default.moveItem(at: file, to: other)
        #expect(VoiceEntry.archiveLookup(name: name, root: root)?.standardizedFileURL.path
                == other.standardizedFileURL.path)

        try FileManager.default.moveItem(at: other, to: trash.appendingPathComponent(name))
        #expect(VoiceEntry.archiveLookup(name: name, root: root) == nil)
    }

    @Test("a miss is remembered (no re-walk) until the list reloads or the retry time passes")
    func missIsCached() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "voice-\(UUID().uuidString).mp3"
        let t0 = Date()
        #expect(VoiceEntry.archiveLookup(name: name, root: root, now: t0) == nil)

        // The file comes back; the remembered miss still answers…
        try Data([0]).write(to: root.appendingPathComponent(name))
        #expect(VoiceEntry.archiveLookup(name: name, root: root, now: t0.addingTimeInterval(1)) == nil)
        // …until the retry time has passed,
        #expect(VoiceEntry.archiveLookup(name: name, root: root,
                                         now: t0.addingTimeInterval(VoiceEntry.missRetryS + 1)) != nil)

        // or a reload forgets the misses.
        let other = "voice-\(UUID().uuidString).mp3"
        #expect(VoiceEntry.archiveLookup(name: other, root: root) == nil)
        try Data([0]).write(to: root.appendingPathComponent(other))
        VoiceEntry.forgetMissingAudio()
        #expect(VoiceEntry.archiveLookup(name: other, root: root) != nil)
    }
}
