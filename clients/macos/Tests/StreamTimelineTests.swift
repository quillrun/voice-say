// Play-while-rendering time mapping: the queue player reports the current
// chunk's own time, so the episode playhead and every seek go through
// StreamTimeline (production code, `@testable import VoiceSay`).

import Testing
@testable import VoiceSay

@Suite("Stream timeline")
struct StreamTimelineTests {
    /// Three chunks of 10, 20 and 5 s, fresh render.
    private let fresh = StreamTimeline(base: 0, durations: [10, 20, 5])

    @Test("the playhead keeps counting across chunks instead of restarting at each one")
    func positionAcrossChunks() {
        #expect(fresh.position(chunk: 0, itemTime: 4) == 4)
        #expect(fresh.position(chunk: 1, itemTime: 0) == 10)
        #expect(fresh.position(chunk: 1, itemTime: 7) == 17)
        #expect(fresh.position(chunk: 2, itemTime: 3) == 33)
        #expect(fresh.head == 35)
    }

    @Test("an item clock past its chunk, negative or not finite is clamped into the chunk")
    func positionClamps() {
        #expect(fresh.position(chunk: 0, itemTime: 12) == 10)
        #expect(fresh.position(chunk: 1, itemTime: -1) == 10)
        #expect(fresh.position(chunk: 1, itemTime: .nan) == 10)
    }

    @Test("a seek target in an earlier or later chunk lands in that chunk")
    func locateOtherChunks() throws {
        let back = try #require(fresh.locate(5))
        #expect(back.chunk == 0 && back.offset == 5)
        let ahead = try #require(fresh.locate(32))
        #expect(ahead.chunk == 2 && ahead.offset == 2)
        let mid = try #require(fresh.locate(29.5))
        #expect(mid.chunk == 1 && mid.offset == 19.5)
    }

    @Test("a target on a seam starts the later chunk")
    func locateSeam() throws {
        let seam = try #require(fresh.locate(10))
        #expect(seam.chunk == 1 && seam.offset == 0)
    }

    @Test("a target past the rendered head clamps to the end of the last chunk; before 0 to the start")
    func locateClamps() throws {
        let past = try #require(fresh.locate(500))
        #expect(past.chunk == 2 && past.offset == 5)
        let before = try #require(fresh.locate(-8))
        #expect(before.chunk == 0 && before.offset == 0)
    }

    @Test("a resume's prefix shifts every chunk and can't be seeked into")
    func resumeBase() throws {
        let resumed = StreamTimeline(base: 60, durations: [10, 20])
        #expect(resumed.position(chunk: 0, itemTime: 2) == 62)
        #expect(resumed.position(chunk: 1, itemTime: 5) == 75)
        #expect(resumed.start(ofChunk: 2) == 90)
        let intoPrefix = try #require(resumed.locate(30))
        #expect(intoPrefix.chunk == 0 && intoPrefix.offset == 0)
        let second = try #require(resumed.locate(85))
        #expect(second.chunk == 1 && second.offset == 15)
    }

    @Test("nothing enqueued: no seek target; appended chunks extend the head")
    func appending() {
        var t = StreamTimeline(base: 0)
        #expect(t.locate(3) == nil)
        t.append(4)
        t.append(6)
        #expect(t.head == 10)
        #expect(t.locate(7)?.chunk == 1)
    }
}
