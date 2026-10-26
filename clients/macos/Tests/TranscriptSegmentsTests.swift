// Reader segmentation: a long paragraph split at a sentence end must not
// start the next segment with the separating space.

import Testing
@testable import VoiceSay

@Suite("Transcript segments")
struct TranscriptSegmentsTests {

    @Test("soft-cap split: next segment has no leading space and starts at its first letter")
    func softCapSplit() {
        let first = String(repeating: "word ", count: 80) + "end."
        let full = first + " Next sentence here."
        let segs = Transcript.segments(full)
        #expect(segs.count == 2)
        #expect(segs[1].text == "Next sentence here.")
        #expect(segs[1].start == first.count + 1)  // first displayed character
        #expect(segs[1].end == full.count)
    }

    @Test("newline paragraphs keep their text")
    func paragraphs() {
        let segs = Transcript.segments("One.\nTwo.\n")
        #expect(segs.map(\.text) == ["One.", "Two."])
    }

    @Test("the read head lights whole words")
    func wordSnap() {
        let t = "One two three"
        #expect(Transcript.wordEnd(in: t, at: 0) == 0)
        #expect(Transcript.wordEnd(in: t, at: 1) == 3)      // inside "One" → all of it
        #expect(Transcript.wordEnd(in: t, at: 3) == 3)      // at its end
        #expect(Transcript.wordEnd(in: t, at: 4) == 4)      // after the space, before "two"
        #expect(Transcript.wordEnd(in: t, at: 5) == 7)      // into "two"
        #expect(Transcript.wordEnd(in: t, at: 99) == 13)
        #expect(Transcript.wordEnd(in: t, at: -2) == 0)
    }
}
