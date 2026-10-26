// Swift Testing coverage for the transcript scroll widget pure logic.
//
// Transcript scroll widget visibility rules + follow-toggle state. Pure
// functions: TranscriptScreen.goToTopVisible / followToggleVisible /
// jumpToProgressVisible — all `nonisolated static`, so no SwiftUI host or live
// player is needed.
//
// (The former SAY-06 "AudioPlayer.loadAndSeekPaused exists" contract was
// removed: bug #4 changed the BookmarksListView tap to EXPAND in place rather
// than load+seek+navigate, so that method — and its test — no longer apply.)

import Foundation
import Testing
@testable import VoiceSay

// MARK: - SAY-07: Widget visibility rules

@Suite("ScrollWidget — visibility rules")
struct ScrollWidgetVisibilityTests {

    // go-to-top button

    @Test("go-to-top hidden when atTop == true")
    func goToTopHiddenAtTop() {
        #expect(TranscriptScreen.goToTopVisible(atTop: true) == false)
    }

    @Test("go-to-top visible when scrolled away from top")
    func goToTopVisibleWhenScrolledDown() {
        #expect(TranscriptScreen.goToTopVisible(atTop: false) == true)
    }

    // live-read follow toggle

    @Test("follow toggle visible when NOT streaming")
    func followToggleVisibleWhenFinished() {
        #expect(TranscriptScreen.followToggleVisible(isStreaming: false) == true)
    }

    @Test("follow toggle hidden during a streaming read")
    func followToggleHiddenWhenStreaming() {
        #expect(TranscriptScreen.followToggleVisible(isStreaming: true) == false)
    }

    // jump-to-playhead button (#6)

    @Test("jump-to-playhead hidden when there is no live read position")
    func jumpHiddenWhenIdle() {
        #expect(TranscriptScreen.jumpToProgressVisible(isStreaming: false, activeId: -1) == false)
    }

    @Test("jump-to-playhead visible when a read position exists")
    func jumpVisibleWithPosition() {
        #expect(TranscriptScreen.jumpToProgressVisible(isStreaming: false, activeId: 3) == true)
    }

    @Test("jump-to-playhead hidden during a streaming read")
    func jumpHiddenWhenStreaming() {
        #expect(TranscriptScreen.jumpToProgressVisible(isStreaming: true, activeId: 3) == false)
    }
}

// MARK: - SAY-07: UserDefaults follow-toggle persistence contract

@Suite("ScrollWidget — follow toggle persistence", .serialized)
struct ScrollWidgetPersistenceTests {

    private let key = "transcriptLiveReadFollow"

    /// Each test uses an isolated UserDefaults suite so it doesn't bleed into
    /// the app's real defaults.
    private func freshDefaults() -> UserDefaults { TestSupport.freshDefaults() }

    @Test("follow toggle defaults to false when no value stored")
    func defaultsToFalse() {
        let ud = freshDefaults()
        // bool(forKey:) returns false for missing keys.
        #expect(ud.bool(forKey: key) == false)
    }

    @Test("follow toggle roundtrips true through UserDefaults")
    func persistsTrue() {
        let ud = freshDefaults()
        ud.set(true, forKey: key)
        #expect(ud.bool(forKey: key) == true)
    }

    @Test("follow toggle roundtrips false through UserDefaults")
    func persistsFalse() {
        let ud = freshDefaults()
        ud.set(true, forKey: key)
        ud.set(false, forKey: key)
        #expect(ud.bool(forKey: key) == false)
    }
}

