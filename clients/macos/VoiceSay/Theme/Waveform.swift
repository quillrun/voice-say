// Waveform — deterministic synthetic peaks for the redesign's mini
// waveforms (the voice-sample preview and the transcript LIVE-READ
// player). Same seeded-PRNG idea as PlayerPanel.computePeaks, but
// standalone so the new screens don't reach into PlayerPanel's private
// state (and so the streaming session's PlayerPanel stays untouched).

import Foundation

enum WaveformSynth {
    /// Shared bar count for an entry's waveform across every surface (inline
    /// player, streaming card, transcript reader) so the same seed renders the
    /// same shape at the same resolution everywhere.
    static let entryBarCount = 96

    /// `count` bar heights in (0, 1], deterministic per `seed` so a given
    /// voice / entry always renders the same shape across redraws.
    static func peaks(seed: String, count: Int) -> [Double] {
        let n = max(1, count)
        var s: UInt32 = 0
        for ch in seed.utf8 { s = (s &* 31) &+ UInt32(ch) }
        var x: UInt32 = s ^ 0x9e3779b9
        if x == 0 { x = 1 }
        func rand() -> Double {
            x ^= x << 13; x ^= x >> 17; x ^= x << 5
            return Double(x % 1000) / 1000.0
        }
        return (0..<n).map { i in
            let f = Double(i) / Double(n)
            let env = 0.5 + 0.5 * sin(f * .pi * 4 + Double(s) * 0.02)
            return max(0.16, min(1.0, 0.4 * env + 0.5 * rand()))
        }
    }
}
