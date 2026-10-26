// Overlays that arrive before their row are stashed; a full-list reconcile
// (snapshot or /history load) settles every stash instead of keeping it for
// the app's lifetime.

import Foundation
import Testing
@testable import VoiceSay

@MainActor
@Suite("Pending overlays")
struct PendingOverlaysTests {

    private func event(_ name: String, _ json: String) throws -> DaemonEvent {
        try #require(EventStreamReader.decodeEvent(name: name, data: json))
    }

    private func overlay(starred: Bool) throws -> Overlay {
        try JSONDecoder().decode(Overlay.self, from: Data(#"{"starred":\#(starred)}"#.utf8))
    }

    @Test("an overlay for an unknown row is stashed, and a snapshot clears the stash")
    func snapshotClears() throws {
        let s = HistoryStore(connect: false)
        s.apply(event: try event("overlay",
            #"{"id":1,"type":"overlay","ts":"ghost","overlay":{"starred":true}}"#))
        #expect(s.pendingOverlays.keys.sorted() == ["ghost"])
        s.apply(event: try event("snapshot",
            #"{"id":2,"type":"snapshot","progress":{},"overlays":{},"history":[]}"#))
        #expect(s.pendingOverlays.isEmpty)
    }

    @Test("after a fetch: older stashes drop, newer ones apply to a present row or wait")
    func settleAfterFetch() throws {
        let on = try overlay(starred: true)
        let pending = ["old-present": on, "old-absent": on, "new-present": on, "new-absent": on]
        let settled = HistoryStore.settledPendingOverlays(
            pending,
            stashedBeforeFetch: ["old-present", "old-absent"],
            present: ["old-present", "new-present"])
        #expect(settled.apply.keys.sorted() == ["new-present"])
        #expect(settled.keep.keys.sorted() == ["new-absent"])
    }
}
