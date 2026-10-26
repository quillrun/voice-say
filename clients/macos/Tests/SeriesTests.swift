// Series view: overlay series/episode decode, the "Series · NNN" label, and
// episode ordering (numbered ascending, unnumbered last by time).

import Foundation
import Testing
@testable import VoiceSay

@Suite("Series")
struct SeriesTests {

    private func entry(_ ts: String, series: String? = "Series A", episode: Int? = nil) -> VoiceEntry {
        var e = try! TestSupport.entry(ts: ts)
        e.overlay = Overlay(starred: false, deleted: false, tags: [], bookmarks: [],
                            series: series, episode: episode)
        return e
    }

    @Test("overlay decodes series and episode; old payloads still decode")
    func decode() throws {
        let new = try JSONDecoder().decode(Overlay.self, from: Data(
            #"{"starred":false,"deleted":false,"tags":[],"bookmarks":[],"series":"Series A","episode":12}"#.utf8))
        #expect(new.series == "Series A" && new.episode == 12)
        let old = try JSONDecoder().decode(Overlay.self, from: Data(#"{"starred":true}"#.utf8))
        #expect(old.series == nil && old.episode == nil)
    }

    @Test("label pads the episode to three digits")
    func label() {
        #expect(entry("t", episode: 7).seriesLabel == "Series A · 007")
        #expect(entry("t", episode: nil).seriesLabel == "Series A")
        #expect(entry("t", series: nil).seriesLabel == nil)
    }

    @Test("label is left out when the title already starts with it")
    func labelNotTwice() {
        var e = entry("t", episode: 12)
        #expect(e.seriesLabelIfNotInTitle == "Series A · 012")
        e.overlay?.title = "Series A · 012 · Attention"
        #expect(e.seriesLabelIfNotInTitle == nil)
    }

    @Test("episode order: numbered ascending, then unnumbered oldest-first")
    func order() {
        let es = [entry("2026-01-05", episode: nil), entry("2026-01-01", episode: 10),
                  entry("2026-01-03", episode: 2), entry("2026-01-02", episode: nil)]
        let sorted = es.sorted(by: HistoryStore.seriesOrder)
        #expect(sorted.map(\.ts) == ["2026-01-03", "2026-01-01", "2026-01-02", "2026-01-05"])
    }

    @Test("auto-advance picks the next playable episode, none after the last")
    func nextEpisode() {
        let es = [entry("a", episode: 1), entry("b", episode: 2), entry("c", episode: 3)]
        #expect(HistoryStore.next(after: "a", in: es, playable: { _ in true })?.ts == "b")
        #expect(HistoryStore.next(after: "a", in: es, playable: { $0.ts != "b" })?.ts == "c")
        #expect(HistoryStore.next(after: "c", in: es, playable: { _ in true }) == nil)
        #expect(HistoryStore.next(after: "zz", in: es, playable: { _ in true }) == nil)
    }

    @Test("continue = most recently played, started, unfinished")
    func continueCandidate() throws {
        func played(_ ts: String, _ s: Double, done: Bool, at: String) throws -> VoiceEntry {
            try TestSupport.entry(ts: ts, progress: ["played_s": s, "duration_s": 100,
                                                     "completed": done, "last_played": at])
        }
        let es = [try played("old", 50, done: false, at: "2026-10-01T00:00:00Z"),
                  try played("new", 30, done: false, at: "2026-10-03T00:00:00Z"),
                  try played("done", 100, done: true, at: "2026-10-04T00:00:00Z"),
                  try played("barely", 0.5, done: false, at: "2026-10-05T00:00:00Z")]
        #expect(HistoryStore.continueCandidate(es)?.ts == "new")
        #expect(HistoryStore.continueCandidate([]) == nil)
    }
}

@Suite("Sleep timer")
struct SleepTimerTests {
    @Test("volume holds, then ramps to silence over the fade")
    func fade() {
        #expect(AudioPlayer.sleepVolume(remaining: 60, fade: 10) == 1)
        #expect(AudioPlayer.sleepVolume(remaining: 5, fade: 10) == 0.5)
        #expect(AudioPlayer.sleepVolume(remaining: 0, fade: 10) == 0)
        #expect(AudioPlayer.sleepVolume(remaining: -3, fade: 10) == 0)
    }

    @Test("the countdown runs only while playing, a stalled tick counts one second")
    func countdown() {
        #expect(AudioPlayer.sleepCountdown(900, elapsed: 0.25, playing: true) == 899.75)
        #expect(AudioPlayer.sleepCountdown(900, elapsed: 1200, playing: false) == 900)
        #expect(AudioPlayer.sleepCountdown(900, elapsed: 1200, playing: true) == 899)
    }

    @Test("a timed sleep sets its minutes; end-of-episode and off clear them")
    @MainActor
    func state() {
        let p = AudioPlayer(socketPath: TestSupport.socketPath())
        p.setSleepTimer(.minutes(15))
        #expect(p.sleepRemaining == 900)
        p.setSleepTimer(.endOfEpisode)
        #expect(p.sleepRemaining == nil && p.sleepTimer == .endOfEpisode)
        p.setSleepTimer(nil)
        #expect(p.sleepTimer == nil)
    }
}

@Suite("Player finish callback")
struct PlayerFinishTests {
    @Test("a finish from a replaced player is ignored; the current one marks, sleeps or advances")
    func finishAction() {
        #expect(AudioPlayer.finishAction(isCurrentPlayer: false, hasEntry: true,
                                         sleepAtEndOfEpisode: false, successfully: true) == .ignore)
        #expect(AudioPlayer.finishAction(isCurrentPlayer: true, hasEntry: false,
                                         sleepAtEndOfEpisode: false, successfully: true) == .ignore)
        #expect(AudioPlayer.finishAction(isCurrentPlayer: true, hasEntry: true,
                                         sleepAtEndOfEpisode: false, successfully: true) == .markAndAdvance)
        #expect(AudioPlayer.finishAction(isCurrentPlayer: true, hasEntry: true,
                                         sleepAtEndOfEpisode: true, successfully: true) == .markAndSleep)
        #expect(AudioPlayer.finishAction(isCurrentPlayer: true, hasEntry: true,
                                         sleepAtEndOfEpisode: false, successfully: false) == .mark)
    }
}
