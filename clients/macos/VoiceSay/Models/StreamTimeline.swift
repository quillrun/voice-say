// StreamTimeline — whole-episode time for play-while-rendering.
//
// The queue player holds one item per rendered chunk, and its clock reports
// the CURRENT ITEM's time (it restarts at 0 for each chunk). The episode's
// playhead is the start of that chunk plus the item time; the start is the
// resume prefix plus every earlier chunk's duration. Durations are the
// daemon's chunk_duration_s, the same values renderHeadS and the read-along
// seams add up, so the scrubber, the time readout and the read head agree.

import Foundation

struct StreamTimeline: Equatable {
    /// Audio before the first streamed chunk (a resume's draft prefix, which
    /// the daemon concatenates server-side and never streams). 0 when fresh.
    var base: TimeInterval = 0
    /// Each enqueued chunk's duration, in queue order.
    private(set) var durations: [TimeInterval] = []

    init(base: TimeInterval = 0, durations: [TimeInterval] = []) {
        self.base = base
        self.durations = durations
    }

    mutating func append(_ durationS: TimeInterval) {
        durations.append(max(0, durationS))
    }

    /// End of the rendered audio: base plus every chunk.
    var head: TimeInterval { base + durations.reduce(0, +) }

    /// Episode time at which chunk `index` starts (`head` past the last one).
    func start(ofChunk index: Int) -> TimeInterval {
        base + durations.prefix(max(0, index)).reduce(0, +)
    }

    /// Episode time for `itemTime` seconds into chunk `index`.
    func position(chunk index: Int, itemTime: TimeInterval) -> TimeInterval {
        let t = itemTime.isFinite ? max(0, itemTime) : 0
        let d = durations.indices.contains(index) ? durations[index] : 0
        return start(ofChunk: index) + min(t, d)
    }

    /// The chunk and the offset inside it for episode time `s`, clamped to
    /// the rendered audio [base, head]. A time on a seam lands at the start of
    /// the later chunk; the head lands at the end of the last chunk. nil
    /// while nothing is enqueued.
    func locate(_ s: TimeInterval) -> (chunk: Int, offset: TimeInterval)? {
        guard !durations.isEmpty else { return nil }
        let target = max(base, min(head, s.isFinite ? s : base))
        var start = base
        for (i, d) in durations.enumerated() {
            if target < start + d || i == durations.count - 1 {
                return (i, max(0, min(d, target - start)))
            }
            start += d
        }
        return nil
    }
}
