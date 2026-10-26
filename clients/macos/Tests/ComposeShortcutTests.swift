// Compose's render shortcut and the "⌘↩ to render" hint come from one value.

import SwiftUI
import Testing
@testable import VoiceSay

@MainActor
@Suite("Compose render shortcut")
struct ComposeShortcutTests {
    @Test("render is ⌘↩ (not plain Return), and the hint says so")
    func renderShortcut() {
        #expect(ComposeScreen.renderShortcut.key == .return)
        #expect(ComposeScreen.renderShortcut.modifiers == .command)
        #expect(ComposeScreen.renderShortcutGlyph == "⌘↩")
        #expect(ComposeScreen.glyph(.defaultAction) == "↩")
        #expect(ComposeScreen.glyph(KeyboardShortcut("o", modifiers: [.command, .shift])) == "⇧⌘O")
    }
}

@MainActor
@Suite("Compose voice seeding")
struct ComposeVoiceSeedTests {
    private func backends() throws -> [Backend] {
        let json = #"""
        [{"id":"kokoro","label":"Kokoro","port":8880,"default_voice":"af_alloy",
          "voices":["af_alloy","am_adam"],"supports_speed":true,"accent":"blue"},
         {"id":"qwen3","label":"Qwen3","port":8881,"default_voice":"ryan",
          "voices":["ryan","vivian"],"supports_speed":false,"accent":"green"}]
        """#
        return try JSONDecoder().decode([Backend].self, from: Data(json.utf8))
    }

    @Test("a late /config never replaces the user's pick")
    func userPickWins() throws {
        #expect(ComposeScreen.seededPick(defaultBackend: "qwen3", defaultVoice: "vivian",
                                         userPicked: true, backends: try backends()) == nil)
    }

    @Test("before a pick: the daemon default, its voice only if that backend has it")
    func seedsDefaults() throws {
        let b = try backends()
        let a = ComposeScreen.seededPick(defaultBackend: "qwen3", defaultVoice: "vivian", userPicked: false, backends: b)
        #expect(a?.backend == "qwen3" && a?.voice == "vivian")
        let c = ComposeScreen.seededPick(defaultBackend: "qwen3", defaultVoice: "af_alloy", userPicked: false, backends: b)
        #expect(c?.backend == "qwen3" && c?.voice == "ryan")
        let d = ComposeScreen.seededPick(defaultBackend: nil, defaultVoice: nil, userPicked: false, backends: b)
        #expect(d?.backend == "kokoro" && d?.voice == "af_alloy")
    }
}
