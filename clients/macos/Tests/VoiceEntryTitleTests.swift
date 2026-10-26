// Swift Testing coverage for VoiceEntry.derivedTitle()'s markup strip. The
// angle-tag arm must remove emotion tags (<laugh>, </whisper>, <sigh/>) while
// leaving prose comparison operators ("x < 5 and y > 3") intact — the prior
// loose `<[^>]*>` ate everything between the first '<' and '>', collapsing
// "x < 5 and y > 3." to "x 3." (and then failing the 8-char sentence floor).
// Production code under test (`@testable import VoiceSay`).

import Foundation
import Testing
@testable import VoiceSay

@Suite("VoiceEntry.derivedTitle markup strip")
struct VoiceEntryTitleTests {

    /// Decode a minimal VoiceEntry carrying just `text` (ts/backend are the only
    /// required keys; the rest default). derivedTitle reads `text` + overlay,
    /// and with no overlay it derives from the first sentence of `text`.
    private func entry(text: String) throws -> VoiceEntry {
        try TestSupport.entry(text: text, durationS: 0)
    }

    @Test("comparison operators in prose survive (regression: 'x < 5 and y > 3')")
    func proseComparisonSurvives() throws {
        let e = try entry(text: "x < 5 and y > 3. More text follows here.")
        #expect(e.derivedTitle() == "x < 5 and y > 3.")
    }

    @Test("angle emotion tags are still stripped")
    func angleEmotionTagsStripped() throws {
        #expect(try entry(text: "<whisper>The secret is out.</whisper> Then more.")
                    .derivedTitle() == "The secret is out.")
        #expect(try entry(text: "Wait<sigh/> for the reveal now please.")
                    .derivedTitle() == "Wait for the reveal now please.")
    }

    @Test("bracket emotion tags are still stripped")
    func bracketEmotionTagsStripped() throws {
        #expect(try entry(text: "[whispering] The secret is out now.")
                    .derivedTitle() == "The secret is out now.")
    }

    @Test("voice-say render <|control|> tokens are stripped from the title")
    func controlTokensStripped() throws {
        #expect(try entry(text: "<|emotion:enthusiasm|>Great news, everyone. More.")
                    .derivedTitle() == "Great news, everyone.")
        // A pause between sentences becomes a space, not glue.
        #expect(try entry(text: "First part here.<|prosody:pause|>Second part here.")
                    .derivedTitle() == "First part here.")
        #expect(try entry(text: "Mid <|style:calm|> sentence title here. Next.")
                    .derivedTitle() == "Mid sentence title here.")
    }

    @Test("the row preview drops the title and every kind of markup")
    func previewStripsMarkup() {
        let text = "<|emotion:joy|>Great news, everyone.<|prosody:pause|> [laughs] We shipped <|sfx:bell|>it."
        let title = VoiceEntry.firstSentence(of: text) ?? ""
        #expect(title == "Great news, everyone.")
        #expect(VoiceEntry.preview(of: text, title: title) == "We shipped it.")
        // Prose with a real '|' or '<' is left alone.
        #expect(VoiceEntry.preview(of: "a | b and x < 5.", title: "none") == "a | b and x < 5.")
    }
}

@Suite("Title edits")
struct TitleWriteTests {
    @Test("saving the shown title writes nothing, so an auto title keeps following the text")
    func unchangedIsNoWrite() {
        #expect(HistoryStore.titleWrite("Hello world.", shown: "Hello world.") == nil)
        #expect(HistoryStore.titleWrite(" Hello world. ", shown: "Hello world.") == nil)
        #expect(HistoryStore.titleWrite("My title", shown: "Hello world.") == "My title")
        #expect(HistoryStore.titleWrite("  ", shown: "Set title") == "")   // clear → auto
    }
}
