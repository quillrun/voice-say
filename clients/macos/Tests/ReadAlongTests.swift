// The reader's play-head → character map (ReadAlong): interpolation between
// points, and binary search on a word-dense map.

import Foundation
import Testing
@testable import VoiceSay

@Suite("Read-along map")
struct ReadAlongTests {

    @Test("between two points the char moves at an even pace; clamps at both ends")
    func interpolates() {
        let pts: [(Double, Double)] = [(0, 0), (2, 10), (4, 40)]
        #expect(ReadAlong.char(at: -1, points: pts) == 0)
        #expect(ReadAlong.char(at: 1, points: pts) == 5)
        #expect(ReadAlong.char(at: 2, points: pts) == 10)
        #expect(ReadAlong.char(at: 3, points: pts) == 25)
        #expect(ReadAlong.char(at: 9, points: pts) == 40)
        #expect(ReadAlong.char(at: 1, points: []) == 0)
    }

    @Test("binary search agrees with a linear scan on a word-dense map")
    func denseMap() {
        let pts = (0..<3000).map { (Double($0) * 0.37, Double($0) * 6) }
        for p in stride(from: 0.0, through: 1110.0, by: 13.7) {
            let i = pts.lastIndex(where: { $0.0 <= p })!
            let expected = i == pts.count - 1 ? pts[i].1
                : pts[i].1 + (p - pts[i].0) / (pts[i + 1].0 - pts[i].0) * (pts[i + 1].1 - pts[i].1)
            #expect(abs(ReadAlong.char(at: p, points: pts) - expected) < 1e-9)
        }
    }

    @Test("word-level once aligned or under 15 s; chunk seams alone are paragraph-level")
    func wordLevel() {
        let seams: [[Double]] = [[0, 0], [400, 6000], [900, 13000]]
        #expect(!ReadAlong.isWordLevel(seamMap: seams, words: 2400, durationS: 900))
        #expect(!ReadAlong.isWordLevel(seamMap: nil, words: 2400, durationS: 900))
        let aligned = (0..<2200).map { [Double($0) * 0.4, Double($0) * 6] }
        #expect(ReadAlong.isWordLevel(seamMap: aligned, words: 2400, durationS: 900))
        #expect(ReadAlong.isWordLevel(seamMap: nil, words: 20, durationS: 8))
    }

    @Test("lights to the end of the word, or the whole paragraph once inside it")
    func litEnd() {
        let t = "One two three."
        #expect(ReadAlong.litEnd(in: t, at: 5, wordLevel: true) == 7)
        #expect(ReadAlong.litEnd(in: t, at: 5, wordLevel: false) == t.count)
        #expect(ReadAlong.litEnd(in: t, at: 0, wordLevel: false) == 0)
    }
}
