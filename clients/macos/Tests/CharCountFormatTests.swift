// Character counts read the same on every screen: Compose, the live reader
// and the stat tiles all go through fmtCompactChars, whose grouping is pinned
// to a comma so a count never looks like the "." decimals elsewhere.

import Testing
@testable import VoiceSay

@Suite("Character count format")
struct CharCountFormatTests {
    @Test("thousands group with a comma whatever the system locale")
    func commaGrouping() {
        #expect(fmtCompactChars(2491) == "2,491")
        #expect(fmtCompactChars(16_472) == "16,472")
        #expect(fmtCompactChars(999) == "999")
    }

    @Test("counts past eight digits abbreviate to millions")
    func abbreviates() {
        #expect(fmtCompactChars(123_456_789) == "123M")
    }
}
