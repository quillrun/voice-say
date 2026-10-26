// Swift Testing coverage for HistoryStore.prunedNewIDs — the pure core of the
// New-inbox prune in load() / the snapshot reconcile. The prune may only drop
// ids CONFIRMED deleted (present pre-fetch, absent from the payload); a
// degenerate empty payload or an id inserted mid-fetch must never cost a badge
// (the old intersection prune wiped both).

import Foundation
import Testing
@testable import VoiceSay

@Suite("PrunedNewIDs")
struct PrunedNewIDsTests {

    @Test("confirmed-deleted id (present pre-fetch, absent from payload) is pruned")
    func confirmedDeletedIsPruned() {
        let kept = HistoryStore.prunedNewIDs(["t1", "t2"],
                                             preFetch: ["t1", "t2", "old"],
                                             fetched: ["t2", "old"])
        #expect(kept == ["t2"])
    }

    @Test("empty payload (daemon mid-restart) prunes nothing")
    func emptyPayloadPrunesNothing() {
        let kept = HistoryStore.prunedNewIDs(["t1", "t2"],
                                             preFetch: ["t1", "t2"],
                                             fetched: [])
        #expect(kept == ["t1", "t2"])
    }

    @Test("id inserted by SSE mid-fetch (in neither snapshot) survives")
    func midFetchInsertSurvives() {
        // episodeComplete added "fresh" while the fetch was in flight: it is
        // absent from the payload AND from the pre-fetch snapshot — kept.
        let kept = HistoryStore.prunedNewIDs(["fresh", "gone"],
                                             preFetch: ["gone", "other"],
                                             fetched: ["other"])
        #expect(kept == ["fresh"])
    }

    @Test("ids present in the payload always survive")
    func presentIdsSurvive() {
        let kept = HistoryStore.prunedNewIDs(["a", "b"],
                                             preFetch: ["a", "b"],
                                             fetched: ["a", "b", "c"])
        #expect(kept == ["a", "b"])
    }

    @Test("a row SSE inserted mid-fetch survives the reload, on top; a deleted one doesn't")
    func mergedAfterFetch() throws {
        let fetched = [try TestSupport.entry(ts: "b"), try TestSupport.entry(ts: "a")]
        let current = [try TestSupport.entry(ts: "new"), try TestSupport.entry(ts: "gone"),
                       try TestSupport.entry(ts: "b")]
        let merged = HistoryStore.mergedAfterFetch(current: current, preFetch: ["gone", "b"],
                                                   fetched: fetched)
        #expect(merged.map(\.ts) == ["new", "b", "a"])
    }
}
