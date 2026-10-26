// Swift Testing port of StreamingEpisode.statusLabel phase coverage. The phase
// logic under test IS the production code (`@testable import VoiceSay`). Covers
// every phase deterministically — including the multi-chunk "Rendering chunk K
// of N" case a 1-chunk live render can never exercise (mock the variation;
// don't test the degenerate).

import Foundation
import Testing
@testable import VoiceSay

@Suite("StreamingEpisode.statusLabel")
@MainActor
struct StreamStatusLabelTests {

    /// Build an episode with `totalChunks` predicted and `rendered` already
    /// completed (each a 1s mock chunk).
    private func mk(totalChunks: Int, rendered: Int) -> StreamingEpisode {
        let ep = StreamingEpisode(id: "t", predictedTotalS: 100, totalChunks: totalChunks,
                                  chars: 1000, backend: "qwen3", voice: "af_alloy", fullText: "x")
        if rendered > 0 {
            for i in 1...rendered { ep.chunks.append(StreamChunk(seq: i, path: "/tmp/\(i).mp3", durationS: 1, cumulativeChars: i * 100)) }
        }
        return ep
    }

    @Test("prep cycler advances on the clock and holds on the last step")
    func prepCyclerAdvancesAndHolds() {
        let prep = mk(totalChunks: 8, rendered: 0)
        let t0 = prep.startedAt
        #expect(prep.statusLabel(at: t0, isFinalizing: false) == "Preparing…")
        #expect(prep.statusLabel(at: t0.addingTimeInterval(2.5), isFinalizing: false) == "Warming up the voice…")
        #expect(prep.statusLabel(at: t0.addingTimeInterval(5.0), isFinalizing: false) == "Rendering the first chunk…")
        #expect(prep.statusLabel(at: t0.addingTimeInterval(60), isFinalizing: false) == "Rendering the first chunk…")
    }

    @Test("multi-chunk renders report 'chunk K of N', capped at N")
    func multiChunkLabel() {
        let mid = mk(totalChunks: 8, rendered: 3)
        #expect(mid.statusLabel(at: mid.startedAt, isFinalizing: false) == "Rendering chunk 4 of 8…")

        let near = mk(totalChunks: 3, rendered: 2)
        #expect(near.statusLabel(at: near.startedAt, isFinalizing: false) == "Rendering chunk 3 of 3…")
    }

    @Test("all predicted chunks rendered (completion not yet landed) → Finishing up")
    func finishingUp() {
        let fin = mk(totalChunks: 8, rendered: 8)
        #expect(fin.statusLabel(at: fin.startedAt, isFinalizing: false) == "Finishing up…")
    }

    @Test("finalizing wins over every other phase")
    func finalizingWinsOverEveryPhase() {
        let mid = mk(totalChunks: 8, rendered: 3)
        #expect(mid.statusLabel(at: mid.startedAt, isFinalizing: true) == "Finishing current chunk…")

        let prep = mk(totalChunks: 8, rendered: 0)
        #expect(prep.statusLabel(at: prep.startedAt, isFinalizing: true) == "Finishing current chunk…")
    }
}
