//
//  ReadAlong.swift
//  VoiceSay
//
//  The reader's play-head → character map. Points are (audio seconds, char
//  offset): the chunk seams, plus a point at each spoken word once the daemon
//  has measured the finished audio (align.py, the row's seam_map). Between two
//  points the highlight moves at an even pace, so with word points it follows
//  the voice word by word. Until then the reader lights the whole paragraph
//  under the play-head: the even pace is off by about 1.4 s (median), right to
//  the paragraph but not to the word.
//

import Foundation

enum ReadAlong {
    /// The character the play-head `p` has reached. `points` are sorted and
    /// increase in both coordinates; binary search, since an aligned episode
    /// has a point per word (thousands) and this runs on every play-head tick.
    static func char(at p: Double, points: [(Double, Double)]) -> Double {
        guard let first = points.first, let last = points.last else { return 0 }
        if p <= first.0 { return first.1 }
        if p >= last.0 { return last.1 }
        var lo = 0, hi = points.count - 1      // points[lo].0 <= p < points[hi].0
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if points[mid].0 <= p { lo = mid } else { hi = mid }
        }
        let (a0, c0) = points[lo], (a1, c1) = points[hi]
        return c0 + (p - a0) / max(a1 - a0, 0.0001) * (c1 - c0)
    }

    /// Whether the map is good to the word: the daemon has aligned the audio
    /// (a point per few words; chunk seams alone are a handful), or the render
    /// is shorter than the daemon's 15 s alignment floor, where the even pace
    /// is already within a word.
    static func isWordLevel(seamMap: [[Double]]?, words: Int, durationS: Double) -> Bool {
        durationS < 15 || (seamMap?.count ?? 0) >= max(2, words / 4)
    }

    /// How many characters of a segment the highlight lights, with the read
    /// head `n` characters into it: up to the end of the word it is in, or the
    /// whole segment once the head is inside it when the map is not word-level.
    static func litEnd(in text: String, at n: Int, wordLevel: Bool) -> Int {
        guard n > 0 else { return 0 }
        return wordLevel ? Transcript.wordEnd(in: text, at: n) : text.count
    }
}
