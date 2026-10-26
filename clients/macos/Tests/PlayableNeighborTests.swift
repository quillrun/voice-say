// Swift Testing coverage for HistoryStore.neighborIndex — the pure index walk
// behind the player's prev/next transport. Playability is injected, so no
// filesystem, no stores: just the walk + skip logic.

import Foundation
import Testing
@testable import VoiceSay

@Suite("PlayableNeighbor")
struct PlayableNeighborTests {

    private let ids = ["a", "b", "c", "d", "e"]

    @Test("next (+1) returns the adjacent older entry; prev (-1) the newer one")
    func adjacent() {
        #expect(HistoryStore.neighborIndex(ids: ids, of: "c", direction: 1, playable: { _ in true }) == 3)
        #expect(HistoryStore.neighborIndex(ids: ids, of: "c", direction: -1, playable: { _ in true }) == 1)
    }

    @Test("ends of the list have no neighbor in that direction")
    func ends() {
        #expect(HistoryStore.neighborIndex(ids: ids, of: "a", direction: -1, playable: { _ in true }) == nil)
        #expect(HistoryStore.neighborIndex(ids: ids, of: "e", direction: 1, playable: { _ in true }) == nil)
    }

    @Test("unplayable rows are skipped in the walk direction")
    func skipsUnplayable() {
        // c -> next: d unplayable, lands on e.
        #expect(HistoryStore.neighborIndex(ids: ids, of: "c", direction: 1, playable: { $0 != 3 }) == 4)
        // c -> prev: b unplayable, lands on a.
        #expect(HistoryStore.neighborIndex(ids: ids, of: "c", direction: -1, playable: { $0 != 1 }) == 0)
        // everything unplayable -> nil.
        #expect(HistoryStore.neighborIndex(ids: ids, of: "c", direction: 1, playable: { _ in false }) == nil)
    }

    @Test("an id outside the current filter (or direction 0) yields nil")
    func missingOrZero() {
        #expect(HistoryStore.neighborIndex(ids: ids, of: "zz", direction: 1, playable: { _ in true }) == nil)
        #expect(HistoryStore.neighborIndex(ids: ids, of: "c", direction: 0, playable: { _ in true }) == nil)
    }
}
