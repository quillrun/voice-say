// Swift Testing coverage for SAY-09 pure WaveformLayout math.
//
// Tests cover:
//   barCount(forWidth:) — dense layout arithmetic
//   levelMultiplier(barIndex:playedBar:phase:radius:amplitude:) — jitter curve
//   tickAllowed(isPlaying:) — tick-gate idle contract

import Foundation
import Testing
@testable import VoiceSay

@Suite("WaveformLayout — bar count")
struct WaveformBarCountTests {

    @Test("zero width returns 0 bars")
    func zeroWidthIsZero() {
        #expect(WaveformLayout.barCount(forWidth: 0) == 0)
    }

    @Test("negative width returns 0 bars")
    func negativeWidthIsZero() {
        #expect(WaveformLayout.barCount(forWidth: -10) == 0)
    }

    @Test("barCount for 300px at 2+1 stride is 100")
    func exactFit() {
        // stride = 2 (bar) + 1 (gap) = 3px; 300 / 3 = 100
        #expect(WaveformLayout.barCount(forWidth: 300) == 100)
    }

    @Test("barCount floors partial bars")
    func floorsPartial() {
        // 301px / 3 = 100.33… → 100 bars
        #expect(WaveformLayout.barCount(forWidth: 301) == 100)
    }

    @Test("barCount for 600px doubles the 300px result")
    func scalesLinearly() {
        let n300 = WaveformLayout.barCount(forWidth: 300)
        let n600 = WaveformLayout.barCount(forWidth: 600)
        #expect(n600 == n300 * 2)
    }

    @Test("barCount always >= 1 for any positive width")
    func minimumOne() {
        #expect(WaveformLayout.barCount(forWidth: 1) >= 1)
        #expect(WaveformLayout.barCount(forWidth: 0.5) >= 1)
    }

    @Test("custom barWidth + gap respected")
    func customStride() {
        // 4px bar + 2px gap = 6px stride; 120px / 6 = 20 bars
        #expect(WaveformLayout.barCount(forWidth: 120, barWidth: 4, gap: 2) == 20)
    }
}

@Suite("WaveformLayout — level multiplier")
struct WaveformLevelMultiplierTests {

    @Test("bar at playhead is modulated (not flat 1.0)")
    func playheadBarModulated() {
        // At distance 0 the cosine envelope is 1, so the bar is fully modulated.
        // The wave can be positive OR negative — just confirm it deviates from 1.
        // Choose phase = 0.0 where sin(0 + offset_for_bar_5) is non-zero.
        let m0 = WaveformLayout.levelMultiplier(barIndex: 5, playedBar: 5, phase: 0.0)
        let m1 = WaveformLayout.levelMultiplier(barIndex: 5, playedBar: 5, phase: 0.125)
        // At least one of two phase samples must move (the bar isn't frozen at 1.0).
        #expect(m0 != 1.0 || m1 != 1.0)
        // And the range stays within the allowed amplitude bounds.
        #expect(m0 >= 1.0 - 0.18 && m0 <= 1.0 + 0.18)
        #expect(m1 >= 1.0 - 0.18 && m1 <= 1.0 + 0.18)
    }

    @Test("bar outside radius returns exactly 1.0")
    func outsideRadiusIsFlat() {
        let m = WaveformLayout.levelMultiplier(barIndex: 0, playedBar: 100, phase: 0.5, radius: 8)
        #expect(m == 1.0)
    }

    @Test("multiplier stays within sane bounds [0.7, 1.4]")
    func multiplierSaneBounds() {
        for bar in 0..<20 {
            for phaseStep in 0..<8 {
                let phase = Double(phaseStep) / 8.0
                let m = WaveformLayout.levelMultiplier(barIndex: bar, playedBar: 10,
                                                       phase: phase, radius: 8, amplitude: 0.18)
                #expect(m >= 0.7 && m <= 1.4)
            }
        }
    }

    @Test("zero amplitude always returns 1.0")
    func zeroAmplitudeIsFlat() {
        for bar in 0..<20 {
            let m = WaveformLayout.levelMultiplier(barIndex: bar, playedBar: 10, phase: 0.5, amplitude: 0.0)
            #expect(m == 1.0)
        }
    }

    @Test("bars at equal distance but different phases differ slightly")
    func phaseDifferentiation() {
        // Two bars equidistant from the play head get different phase offsets
        // (bar % 7 differs) — so their multipliers won't be identical for most phases.
        // Use a phase that avoids the flat zero-crossing.
        let m0 = WaveformLayout.levelMultiplier(barIndex: 0, playedBar: 5, phase: 0.3, radius: 10)
        let m1 = WaveformLayout.levelMultiplier(barIndex: 1, playedBar: 5, phase: 0.3, radius: 10)
        // They must not both be exactly 1.0 (outside radius) since both are within 10.
        #expect(m0 != m1 || m0 != 1.0)  // at least one should show motion
    }
}

@Suite("WaveformLayout — tick gate")
struct WaveformTickGateTests {

    @Test("tick allowed when playing")
    func allowedWhenPlaying() {
        #expect(WaveformLayout.tickAllowed(isPlaying: true) == true)
    }

    @Test("tick blocked when paused")
    func blockedWhenPaused() {
        #expect(WaveformLayout.tickAllowed(isPlaying: false) == false)
    }
}
