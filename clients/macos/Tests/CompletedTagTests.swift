// The virtual "#completed" tag tracks PLAYBACK completion, not render
// completion. A freshly-rendered clip the user hasn't listened to must NOT
// carry #completed; once played to the end (the daemon's progress.completed =
// played_s >= duration), it must.
// Guards the split between `isComplete` (fully RENDERED — drives the New inbox
// / totals / visualizer) and `hasFinishedPlayback` (listened to the end —
// gates only this tag). Production code under test (`@testable import VoiceSay`).
//
// `.serialized` + `@MainActor`: HistoryStore is a @MainActor @Observable type.
// `connect: false` keeps the store off the daemon: tagsFor reads the synthetic
// entry's own fields + the (empty) overlay mirrors.

import Foundation
import Testing
@testable import VoiceSay

@Suite("Completed tag tracks playback", .serialized)
@MainActor
struct CompletedTagTests {

    /// Decode a minimal fully-rendered VoiceEntry. `completed` seeds the
    /// `progress.completed` playback flag (nil = no progress row yet, i.e.
    /// never played).
    private func entry(completed: Bool?) throws -> VoiceEntry {
        try TestSupport.entry(progress: completed.map {
            ["completed": $0, "duration_s": 10, "played_s": $0 ? 10 : 2]
        })
    }

    @Test("freshly rendered but unplayed render does NOT carry #completed")
    func unplayedHasNoCompleted() throws {
        let store = HistoryStore(connect: false)
        let e = try entry(completed: false)
        #expect(store.isComplete(e))                 // fully RENDERED…
        #expect(!store.hasFinishedPlayback(e))       // …but not listened to the end
        #expect(!store.tagsFor(e).contains(HistoryStore.completedTag))
    }

    @Test("render with no progress row yet does NOT carry #completed")
    func noProgressHasNoCompleted() throws {
        let store = HistoryStore(connect: false)
        let e = try entry(completed: nil)
        #expect(!store.hasFinishedPlayback(e))
        #expect(!store.tagsFor(e).contains(HistoryStore.completedTag))
    }

    @Test("played-to-the-end render carries #completed")
    func playedToEndHasCompleted() throws {
        let store = HistoryStore(connect: false)
        let e = try entry(completed: true)
        #expect(store.hasFinishedPlayback(e))
        #expect(store.tagsFor(e).contains(HistoryStore.completedTag))
    }
}
