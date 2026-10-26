// The live render card's two answers, as pure functions on the models:
// WHAT is rendering (title + its fallback, the identity meta line, the same
// on queued jobs) and HOW LONG until it is done (the measured pace and ETA).

import Foundation
import Testing
@testable import VoiceSay

@Suite("Live render — identity and pace")
@MainActor
struct StreamingEpisodePaceTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func mk(total: Int = 10, text: String = "First sentence here. Second one.",
                    title: String? = nil, series: String? = nil, episode: Int? = nil,
                    foreign: Bool = false, prefixAudioS: Double = 0) -> StreamingEpisode {
        StreamingEpisode(id: "t", predictedTotalS: 100, totalChunks: total, chars: 1000,
                         backend: "qwen3", voice: "af_alloy", fullText: text,
                         prefixAudioS: prefixAudioS, isForeign: foreign,
                         title: title, series: series, episodeNumber: episode)
    }

    /// Date arithmetic at 1.8e9 s isn't exact to the last bit.
    private func approx(_ a: Double?, _ b: Double) -> Bool {
        guard let a else { return false }
        return abs(a - b) < 1e-3
    }

    /// Land chunk `seq` at t0 + `at` seconds.
    private func land(_ ep: StreamingEpisode, _ seq: Int, at: Double) {
        ep.chunks.append(StreamChunk(seq: seq, path: "/tmp/\(seq).wav", durationS: 60,
                                     cumulativeChars: seq * 100, landedAt: t0.addingTimeInterval(at)))
    }

    // MARK: - Title

    @Test("a set title is the heading; blank or missing falls back to the first sentence, dimmed")
    func titleFallback() {
        #expect(mk(title: "Attention from Scratch").displayTitle == "Attention from Scratch")
        #expect(mk(title: "Attention from Scratch").hasTitle)
        let untitled = mk(title: "   ")
        #expect(!untitled.hasTitle)
        #expect(untitled.displayTitle == "First sentence here.")
        #expect(mk(text: "[whispering] The secret is out. Then more.").displayTitle == "The secret is out.")
        #expect(mk(text: "no full stop on this first line\nsecond line").displayTitle == "no full stop on this first line")
        #expect(mk(text: "").displayTitle == "Untitled")
    }

    @Test("identity meta line: series · episode only when set, the source only when foreign")
    func identityMeta() {
        let full = mk(series: "Series A", episode: 181, foreign: true)
        #expect(full.identityMetaLine ==
                "Series A · 181 · af_alloy · qwen3 · \(fmtCompactChars(full.totalChars)) chars · from the CLI")
        let bare = mk()
        #expect(bare.identityMetaLine == "af_alloy · qwen3 · \(fmtCompactChars(bare.totalChars)) chars")
        #expect(mk(series: "S").identityMetaLine.hasPrefix("S · af_alloy"))
        #expect(mk(episode: 4).identityMetaLine.hasPrefix("af_alloy"))   // an episode without a series isn't shown
    }

    @Test("queued jobs read the same way: title fallback and series · episode · chars")
    func queuedJob() {
        let text = "Hello there, friend. And more."
        let titled = RenderJob(source: .fresh(text: text), backendID: "b", voice: "v", title: "T",
                               overlay: RenderOverlay(title: "T", series: "Series A", episode: 7))
        #expect(titled.hasTitle && titled.displayTitle == "T")
        #expect(titled.metaLine(withETA: false) == "Series A · 007 · \(fmtCompactChars(text.count)) chars")
        #expect(titled.metaLine(withETA: true).hasSuffix(" · ~0:01"))

        let untitled = RenderJob(source: .fresh(text: text), backendID: "b", voice: "v",
                                 title: RenderJob.title(fromText: text))
        #expect(!untitled.hasTitle && untitled.displayTitle == "Hello there, friend.")

        let resume = RenderJob(source: .resume(fromTS: "1"), backendID: "b", voice: "v", title: "Draft first.",
                               overlay: RenderOverlay(series: "S", episode: 2))
        #expect(!resume.hasTitle && resume.displayTitle == "Draft first.")
        #expect(resume.metaLine(withETA: true) == "S · 002 · continue draft")
    }

    // MARK: - Pace

    @Test("estimating until two chunks land; then pace = wall time between first and last over the gaps")
    func paceNeedsTwoChunks() {
        let ep = mk(total: 10)
        #expect(ep.secondsPerChunk == nil)
        #expect(ep.remainingLabel(at: t0) == "estimating…")
        land(ep, 1, at: 30)                     // warm-up + chunk 1: not a pace sample on its own
        #expect(ep.secondsPerChunk == nil)
        #expect(ep.remainingS(at: t0.addingTimeInterval(40)) == nil)
        #expect(ep.remainingLabel(at: t0.addingTimeInterval(40)) == "estimating…")
        land(ep, 2, at: 90)
        land(ep, 3, at: 150)
        #expect(approx(ep.secondsPerChunk, 60))
        // At the moment chunk 3 lands: 7 chunks left × 60 s.
        #expect(approx(ep.remainingS(at: t0.addingTimeInterval(150)), 420))
        #expect(ep.remainingLabel(at: t0.addingTimeInterval(150)) == "about 7:00 left")
    }

    @Test("the estimate counts down between chunks and never goes below the chunks not yet started")
    func countsDownBetweenChunks() {
        let ep = mk(total: 5)
        land(ep, 1, at: 0); land(ep, 2, at: 60)
        // 3 left: the in-flight one has run 20 s of its 60.
        #expect(approx(ep.remainingS(at: t0.addingTimeInterval(80)), 40 + 2 * 60))
        // The in-flight chunk overruns its pace: floor at the two not yet started.
        #expect(approx(ep.remainingS(at: t0.addingTimeInterval(500)), 2 * 60))
    }

    @Test("every chunk in: 0 left and 'finishing up…'")
    func allChunksIn() {
        let ep = mk(total: 2)
        land(ep, 1, at: 0); land(ep, 2, at: 50)
        #expect(ep.remainingS(at: t0.addingTimeInterval(55)) == 0)
        #expect(ep.remainingLabel(at: t0.addingTimeInterval(55)) == "finishing up…")
    }

    @Test("chunk count, elapsed and rendered-so-far labels")
    func labels() {
        let ep = mk(total: 12, prefixAudioS: 100)
        land(ep, 1, at: 10); land(ep, 2, at: 70); land(ep, 3, at: 130)
        ep.renderHeadS = 660                     // 11:00 streamed + 1:40 draft prefix
        #expect(ep.chunkCountLabel == "chunk 3 of 12")
        #expect(ep.renderedLabel == "12:40 rendered")
        #expect(ep.elapsedLabel(at: ep.startedAt.addingTimeInterval(242.7)) == "elapsed 4:02")
        #expect(ep.elapsedLabel(at: ep.startedAt.addingTimeInterval(-5)) == "elapsed 0:00")
    }
}
