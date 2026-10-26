// Swift Testing coverage for HistoryStore.flattenBookmarks — the pure core
// behind the sidebar Bookmarks view's flat item list. Liveness + lookup are
// injected, so no daemon and no private mirrors: just the flatten + ordering
// + exclusion logic.

import Foundation
import Testing
@testable import VoiceSay

@Suite("AllBookmarks", .serialized)
@MainActor
struct AllBookmarksTests {

    /// Decode a minimal fully-rendered VoiceEntry with the given ts.
    private func entry(_ ts: String) throws -> VoiceEntry {
        try TestSupport.entry(ts: ts)
    }

    private func bm(_ id: String, _ position: Double) -> Bookmark {
        Bookmark(id: id, position: position, note: "")
    }

    @Test("flattens per-entry bookmarks, preserving entry order and per-entry sort")
    func flattensInOrder() throws {
        let a = try entry("a"), b = try entry("b")
        let marks = ["a": [bm("a1", 0.2), bm("a2", 0.8)], "b": [bm("b1", 0.5)]]
        let flat = HistoryStore.flattenBookmarks(entries: [a, b],
                                                 isLive: { _ in true },
                                                 bookmarksFor: { marks[$0.ts] ?? [] })
        #expect(flat.map { $0.bookmark.id } == ["a1", "a2", "b1"])
        #expect(flat.map { $0.entry.ts } == ["a", "a", "b"])
    }

    @Test("dead entries (deleted / incomplete drafts) contribute no rows")
    func excludesDead() throws {
        let a = try entry("a"), b = try entry("b")
        let marks = ["a": [bm("a1", 0.2)], "b": [bm("b1", 0.5)]]
        let flat = HistoryStore.flattenBookmarks(entries: [a, b],
                                                 isLive: { $0.ts != "a" },
                                                 bookmarksFor: { marks[$0.ts] ?? [] })
        #expect(flat.map { $0.bookmark.id } == ["b1"])
    }

    @Test("entries without bookmarks vanish from the flat list")
    func skipsEmpty() throws {
        let a = try entry("a")
        let flat = HistoryStore.flattenBookmarks(entries: [a],
                                                 isLive: { _ in true },
                                                 bookmarksFor: { _ in [] })
        #expect(flat.isEmpty)
    }
}

@Suite("Bookmarks view filters", .serialized)
@MainActor
struct VisibleBookmarksTests {

    /// Two episodes: "alpha" tagged #work with notes "intro" and "outro",
    /// "beta" untagged with note "intro".
    private func store() throws -> HistoryStore {
        let s = HistoryStore(connect: false)
        let json = #"""
        {"id":1,"type":"snapshot","progress":{},
         "overlays":{
           "a":{"tags":["work"],"bookmarks":[{"id":"a1","position":0.1,"note":"intro"},
                                             {"id":"a2","position":0.9,"note":"outro"}]},
           "b":{"bookmarks":[{"id":"b1","position":0.5,"note":"intro"}]}},
         "history":[{"ts":"a","backend":"kokoro","archive_name":"a.mp3","text":"alpha story."},
                    {"ts":"b","backend":"kokoro","archive_name":"b.mp3","text":"beta story."}]}
        """#
        s.apply(event: try #require(EventStreamReader.decodeEvent(name: "snapshot", data: json)))
        s.bookmarksFilter = true
        return s
    }

    private func ids(_ s: HistoryStore) -> [String] { s.visibleBookmarks.map(\.bookmark.id) }

    @Test("no search, no tag: every bookmark")
    func unfiltered() throws {
        #expect(try ids(store()) == ["a1", "a2", "b1"])
    }

    @Test("the tag filter keeps only bookmarks of tagged episodes")
    func tagFilter() throws {
        let s = try store()
        s.tagFilter = "work"
        #expect(ids(s) == ["a1", "a2"])
    }

    @Test("search matches a bookmark's own note, or its episode's text")
    func search() throws {
        let s = try store()
        s.query = "intro"
        #expect(ids(s) == ["a1", "b1"])
        s.query = "beta"
        #expect(ids(s) == ["b1"])
        s.query = "work"          // tag name matches the episode
        #expect(ids(s) == ["a1", "a2"])
    }
}
