// Swift Testing coverage for VoiceOrdering — the pure ordering helpers behind
// the voice picker's "float the now-playing / most-recently-played voice to
// the top" behaviour. No UI, no stores: just the reorder + recency logic.

import Foundation
import Testing
@testable import VoiceSay

@Suite("VoiceOrdering")
struct VoiceOrderingTests {

    // MARK: pinnedFirst

    @Test("pinnedFirst moves the pin to the front, preserving the order of the rest")
    func movesToFront() {
        #expect(VoiceOrdering.pinnedFirst(["a", "b", "c", "d"], pin: "c") == ["c", "a", "b", "d"])
    }

    @Test("pinnedFirst is a no-op when the pin is nil")
    func nilPin() {
        #expect(VoiceOrdering.pinnedFirst(["a", "b", "c"], pin: nil) == ["a", "b", "c"])
    }

    @Test("pinnedFirst is a no-op when the pin is absent from the list (wrong tab)")
    func absentPin() {
        #expect(VoiceOrdering.pinnedFirst(["a", "b", "c"], pin: "z") == ["a", "b", "c"])
    }

    @Test("pinnedFirst is a no-op when the pin is already first")
    func alreadyFirst() {
        #expect(VoiceOrdering.pinnedFirst(["a", "b", "c"], pin: "a") == ["a", "b", "c"])
    }

    @Test("pinnedFirst handles an empty list")
    func emptyList() {
        #expect(VoiceOrdering.pinnedFirst([], pin: "a") == [])
    }

    // MARK: mostRecentlyPlayedVoice

    @Test("mostRecentlyPlayedVoice picks the greatest ISO-8601 lastPlayed")
    func recentByTimestamp() {
        let plays: [(voice: String?, lastPlayed: String?)] = [
            ("af_heart", "2026-06-01T10:00:00Z"),
            ("am_adam",  "2026-06-02T09:30:00Z"),
            ("af_nova",  "2026-05-30T23:59:59Z"),
        ]
        #expect(VoiceOrdering.mostRecentlyPlayedVoice(plays) == "am_adam")
    }

    @Test("mostRecentlyPlayedVoice ignores entries with no lastPlayed or no voice")
    func ignoresIncomplete() {
        let plays: [(voice: String?, lastPlayed: String?)] = [
            ("af_heart", nil),                      // rendered, never played
            (nil,        "2026-06-02T09:30:00Z"),   // played but voice unknown
            ("am_adam",  "2026-06-01T10:00:00Z"),   // the only complete play
        ]
        #expect(VoiceOrdering.mostRecentlyPlayedVoice(plays) == "am_adam")
    }

    @Test("mostRecentlyPlayedVoice returns nil when nothing has been played")
    func returnsNilWhenEmpty() {
        #expect(VoiceOrdering.mostRecentlyPlayedVoice([]) == nil)
        #expect(VoiceOrdering.mostRecentlyPlayedVoice([("af_heart", nil)]) == nil)
    }

    // MARK: committedVoice (VoicePickerSheet Done)

    @Test("committedVoice keeps a selection that belongs to the tab's backend")
    func committedKeepsOwnVoice() {
        #expect(VoicePickerSheet.committedVoice(selected: "b", voices: ["a", "b"], defaultVoice: "a") == "b")
    }

    @Test("committedVoice swaps another backend's voice for this backend's default")
    func committedFallsBackToDefault() {
        #expect(VoicePickerSheet.committedVoice(selected: "Ryan", voices: ["af_heart", "am_adam"],
                                                defaultVoice: "am_adam") == "am_adam")
    }

    @Test("committedVoice falls back to the first voice when the backend names no default")
    func committedFallsBackToFirst() {
        #expect(VoicePickerSheet.committedVoice(selected: "Ryan", voices: ["af_heart", "am_adam"],
                                                defaultVoice: "") == "af_heart")
        #expect(VoicePickerSheet.committedVoice(selected: "Ryan", voices: [], defaultVoice: "") == "")
    }
}
