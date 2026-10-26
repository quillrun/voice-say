// Transcript — pure segmentation model for the reader (TranscriptScreen).
// A transcript splits into reading segments the karaoke read-head and
// auto-scroll can track; the math is view-free so it lives with the models
// (and stays trivially unit-testable).

enum Transcript {
    /// One reading segment. `start`/`end` are absolute char offsets into the
    /// full text so the read-head maps cleanly; `text` is the display slice
    /// (trailing newlines and leading spaces trimmed;
    /// `start` is past the trimmed spaces).
    struct Segment: Identifiable, Equatable {
        let id: Int; let text: String; let start: Int; let end: Int
    }

    /// Split the transcript into reading segments — on newlines (paragraphs),
    /// with any long run further broken at a sentence end past a soft cap so a
    /// single unbroken blob still gives the auto-scroll something to track.
    /// Empty/whitespace-only slices are dropped.
    static func segments(_ full: String) -> [Segment] {
        let chars = Array(full)
        var segs: [Segment] = []
        var id = 0
        var segStart = 0
        let softCap = 360
        func flush(_ end: Int) {
            guard end > segStart else { return }
            // A soft-cap split leaves the sentence's trailing space at the head
            // of the next segment: start after it, so `start` is the absolute
            // offset of the first displayed character.
            var start = segStart
            while start < end, chars[start] == " " { start += 1 }
            var display = String(chars[start..<end])
            while display.hasSuffix("\n") { display.removeLast() }
            if !display.trimmingCharacters(in: .whitespaces).isEmpty {
                segs.append(Segment(id: id, text: display, start: start, end: end)); id += 1
            }
            segStart = end
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let atSentenceEnd = (c == "." || c == "!" || c == "?")
                && (i + 1 >= chars.count || chars[i + 1] == " " || chars[i + 1] == "\n")
            if c == "\n" {
                flush(i + 1)
            } else if atSentenceEnd && (i + 1 - segStart) >= softCap {
                flush(i + 1)
            }
            i += 1
        }
        flush(chars.count)
        return segs
    }

    /// The read head snapped to a word: `n` characters into `text`, moved
    /// forward to the end of the word it falls in, so the read-along lights
    /// whole words as each one starts instead of creeping letter by letter.
    static func wordEnd(in text: String, at n: Int) -> Int {
        let chars = Array(text)
        var i = min(max(0, n), chars.count)
        guard i > 0 else { return 0 }
        while i < chars.count, !chars[i].isWhitespace, !chars[i - 1].isWhitespace { i += 1 }
        return i
    }
}
