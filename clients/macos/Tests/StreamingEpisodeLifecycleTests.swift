// Streaming-episode lifecycle through HistoryStore.apply — the SSE events the
// daemon sends, decoded by the production decoder. No AudioPlayer: its init
// unlinks the live app's IPC socket, so `store.audioPlayer` stays nil and
// these tests assert what the store and the router do.

import Foundation
import Testing
@testable import VoiceSay

@MainActor
@Suite("Streaming episode lifecycle", .serialized)
struct StreamingEpisodeLifecycleTests {

    private func event(_ name: String, _ json: String) throws -> DaemonEvent {
        try #require(EventStreamReader.decodeEvent(name: name, data: json))
    }

    /// episode_start for this app run (client_ref = ours).
    private func ownStart(_ id: String) throws -> DaemonEvent {
        try event("episode_start", #"""
        {"id":1,"type":"episode_start","episode_id":"\#(id)","total_chunks":2,
         "predicted_total_s":10,"chars":20,"backend":"b","voice":"v",
         "text":"hello there, friend.","client_ref":"\#(DaemonClient.clientRef)"}
        """#)
    }

    /// The canonical row's render event, so episode_complete finds it and
    /// doesn't reach for /history.
    private func render(_ ts: String) throws -> DaemonEvent {
        try event("render", #"{"id":2,"type":"render","ts":"\#(ts)","entry":{"ts":"\#(ts)","backend":"b","duration_s":10,"text":"x"}}"#)
    }

    private func complete(_ id: String, ts: String, saveAndStop: Bool = false) throws -> DaemonEvent {
        try event("episode_complete", #"{"id":3,"type":"episode_complete","episode_id":"\#(id)","ts":"\#(ts)","archive_path":"/a/b.mp3","duration_s":10,"save_and_stop":\#(saveAndStop)}"#)
    }

    private func store(router: UIRouter) -> HistoryStore {
        let s = HistoryStore(connect: false)
        s.router = router
        return s
    }

    // MARK: - Silent render leaves the user and the player alone

    @Test("a silent episode_start keeps the expanded row and the screen, and doesn't arm the player")
    func silentStartLeavesSelectionAndScreen() throws {
        let router = UIRouter()
        let s = store(router: router)
        var signals: [HistoryStore.EpisodeSignal] = []
        s.onEpisodeSignal = { signals.append($0) }
        s.expandedEntryID = "row-being-listened-to"
        s.pendingPlayIntent = .none

        s.apply(event: try ownStart("ep-silent"))

        #expect(s.expandedEntryID == "row-being-listened-to")
        #expect(router.screen == .list)
        #expect(s.streamingEpisode?.armsPlayer == false)
        #expect(signals == [.ownStarted("ep-silent")])   // the queue still hears it
    }

    @Test("a play-while-rendering episode_start arms the player and opens the reader")
    func armedStartOpensReader() throws {
        let router = UIRouter()
        let s = store(router: router)
        s.pendingPlayIntent = .whileRendering

        s.apply(event: try ownStart("ep-live"))

        #expect(s.streamingEpisode?.armsPlayer == true)
        #expect(s.expandedEntryID == "ep-live")
        #expect(router.screen == .transcript("ep-live"))
    }

    // MARK: - Reader across completion

    @Test("episode_complete swaps a reader open on the live episode to the finished row")
    func completionSwapsReaderToRow() throws {
        let router = UIRouter()
        let s = store(router: router)
        s.pendingPlayIntent = .whileRendering
        s.apply(event: try ownStart("ep-read"))
        #expect(router.screen == .transcript("ep-read"))

        s.apply(event: try render("t-done"))
        s.apply(event: try complete("ep-read", ts: "t-done"))

        #expect(s.streamingEpisode == nil)
        #expect(router.screen == .transcript("t-done"))
    }

    @Test("a save-and-stop completion leaves the reader on the episode (the screen then closes it)")
    func saveAndStopDoesNotSwap() throws {
        let router = UIRouter()
        let s = store(router: router)
        s.pendingPlayIntent = .whileRendering
        s.apply(event: try ownStart("ep-stop"))

        s.apply(event: try render("t-draft"))
        s.apply(event: try complete("ep-stop", ts: "t-draft", saveAndStop: true))

        #expect(router.screen == .transcript("ep-stop"))
    }

    @Test("episode_complete doesn't move a user reading something else")
    func completionLeavesOtherScreens() throws {
        let router = UIRouter()
        let s = store(router: router)
        s.pendingPlayIntent = .whileRendering
        s.apply(event: try ownStart("ep-bg"))
        router.open(.transcript("older-row"))

        s.apply(event: try render("t-bg"))
        s.apply(event: try complete("ep-bg", ts: "t-bg"))

        #expect(router.screen == .transcript("older-row"))
    }

    // MARK: - Estimated total

    @Test("estimatedTotalS: nil before the first chunk; fresh render extrapolates the measured pace")
    func estimatedTotalFresh() {
        let ep = StreamingEpisode(id: "e", predictedTotalS: 50, totalChunks: 4, chars: 1000,
                                  backend: "b", voice: "v")
        #expect(ep.estimatedTotalS == nil)
        ep.renderHeadS = 30
        ep.renderedChars = 250
        #expect(ep.estimatedTotalS == 120)      // 30 s per 250 chars × 1000
    }

    @Test("estimatedTotalS on a resume counts the draft prefix's audio, not just the remainder")
    func estimatedTotalResume() {
        // 1000 chars; the draft already holds 500 chars = 60 s. The first resumed
        // chunk adds 250 chars = 30 s: rendered_chars 750, cumulative_audio_s 30.
        let ep = StreamingEpisode(id: "e", predictedTotalS: 50, totalChunks: 2, chars: 1000,
                                  backend: "b", voice: "v", prefixAudioS: 60)
        ep.renderHeadS = 30
        ep.renderedChars = 750
        #expect(ep.estimatedTotalS == 120)      // (60 + 30) s per 750 chars × 1000
    }

    @Test("armsPlayer: only this app's play-while-rendering episode")
    func armsPlayerTruthTable() {
        func ep(_ intent: HistoryStore.StreamPlayIntent, foreign: Bool) -> StreamingEpisode {
            StreamingEpisode(id: "e", predictedTotalS: 1, totalChunks: 1, chars: 1,
                             backend: "b", voice: "v", playIntent: intent, isForeign: foreign)
        }
        #expect(ep(.whileRendering, foreign: false).armsPlayer)
        #expect(!ep(.none, foreign: false).armsPlayer)
        #expect(!ep(.whileRendering, foreign: true).armsPlayer)
        #expect(!ep(.none, foreign: true).armsPlayer)
    }
}
