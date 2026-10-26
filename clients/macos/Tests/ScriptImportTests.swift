// Compose script import: heading → title (marker dropped from the spoken
// text), first line otherwise; and the render request carries title/series/
// episode only when set.

import Foundation
import Testing
@testable import VoiceSay

@Suite("Script import")
struct ScriptImportTests {

    @Test("a # heading is the title and is still spoken, without the marker")
    func heading() {
        let r = ScriptImport.parse("intro note\n# Attention from Scratch\n\nBody text.\n")
        #expect(r.title == "Attention from Scratch")
        #expect(r.text == "intro note\nAttention from Scratch\n\nBody text.")
    }

    @Test("a UTF-8 byte-order mark doesn't hide the heading")
    func bom() {
        let r = ScriptImport.parse("\u{FEFF}# Title\n\nBody.")
        #expect(r.title == "Title" && r.text == "Title\n\nBody.")
    }

    @Test("no heading: the first non-empty line")
    func firstLine() {
        let r = ScriptImport.parse("\n\n  Hello there.  \nMore.\r\n")
        #expect(r.title == "Hello there.")
        #expect(r.text == "Hello there.  \nMore.")
    }

    @Test("render request sends title/series/episode only when set")
    func wire() throws {
        let bare = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            RenderRequest(text: "t", backend: "b", voice: "v", speed: 1, tags: []))) as! [String: Any]
        #expect(bare["title"] == nil && bare["series"] == nil && bare["episode"] == nil)
        let full = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            RenderRequest(text: "t", backend: "b", voice: "v", speed: 1, tags: [],
                          title: "Ep", series: "S", episode: 4))) as! [String: Any]
        #expect(full["title"] as? String == "Ep" && full["series"] as? String == "S")
        #expect(full["episode"] as? Int == 4)
    }

    @Test("render timeout: ~1 s per 10 chars, at least 600 s, capped")
    func timeout() {
        #expect(DaemonClient.renderTimeout(chars: 100) == 600)
        #expect(DaemonClient.renderTimeout(chars: 40_000) == 4000)
        #expect(DaemonClient.renderTimeout(chars: 10_000_000) == DaemonClient.longestRenderS)
    }
}

@Suite("Compose estimate")
struct ComposeEstimateTests {
    @Test("minutes of audio from the char count; nothing under 30 s")
    func estimate() {
        #expect(ComposeScreen.estimate(chars: 100) == nil)
        #expect(ComposeScreen.estimate(chars: 1_068) == "≈ 1 min audio")      // 60 s
        #expect(ComposeScreen.estimate(chars: 40_000) == "≈ 37 min audio")
    }
}
