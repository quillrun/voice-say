// Swift Testing coverage for HistoryStore.jumpNeedsFilterClear — the pure
// core behind the pinned Now Playing / Last Played card's jump-to-row: filters
// must be cleared exactly when they hide the jump target.

import Testing
@testable import VoiceSay

@Suite("PinnedCardJump")
struct PinnedCardJumpTests {

    @Test("target visible under current filters — no clear")
    func visibleTargetKeepsFilters() {
        #expect(HistoryStore.jumpNeedsFilterClear(targetID: "b",
                                                  filteredIDs: ["a", "b", "c"]) == false)
    }

    @Test("target hidden by filters — clear required")
    func hiddenTargetClearsFilters() {
        #expect(HistoryStore.jumpNeedsFilterClear(targetID: "z",
                                                  filteredIDs: ["a", "b", "c"]) == true)
    }

    @Test("empty filtered list — clear required")
    func emptyListClearsFilters() {
        #expect(HistoryStore.jumpNeedsFilterClear(targetID: "a",
                                                  filteredIDs: []) == true)
    }
}
