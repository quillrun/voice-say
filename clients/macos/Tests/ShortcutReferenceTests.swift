// The Keyboard Shortcuts sheet and the PlaybackKeys monitor cannot drift:
// every listed player key maps to the action its row names, and every
// monitor action is listed exactly once.

import AppKit
import Testing
@testable import VoiceSay

@Suite("Shortcut reference")
struct ShortcutReferenceTests {
    @Test("every listed player key maps to its row's action")
    func listedKeysMap() {
        for key in ShortcutReference.playerKeys {
            #expect(PlaybackKeys.action(keyCode: key.keyCode, chars: key.chars, flags: key.flags) == key.action,
                    "\(key.keyCode) \(key.chars) \(key.flags)")
        }
    }

    @Test("every monitor action is listed once")
    func everyActionListedOnce() {
        let listed = ShortcutReference.playerKeys.map(\.action)
        for action in PlaybackKeys.Action.allCases {
            #expect(listed.filter { $0 == action }.count == 1, "\(action)")
        }
    }

    @Test("⌘F brings the list in front and issues a fresh request each time")
    @MainActor func findRequest() {
        let router = UIRouter()
        router.open(.compose)
        router.requestSearch()
        #expect(router.screen == .list)
        let first = router.searchRequest
        router.requestSearch()
        #expect(first != nil && router.searchRequest != first)
    }

    @Test("modifiers read ⌃⌥⇧⌘, as menus list them")
    func modifierOrder() {
        let order: [Character] = ["⌃", "⌥", "⇧", "⌘"]
        for cap in ShortcutReference.groups.flatMap(\.rows).flatMap(\.caps) {
            let mods = cap.compactMap { order.firstIndex(of: $0) }
            #expect(mods == mods.sorted(), "\(cap)")
        }
        #expect(!ShortcutReference.groups.flatMap(\.rows).contains { $0.keys == "⌘O" && $0.action.contains("transcript") })
    }

    @Test("the trash key and the sheet's own key are listed")
    func trashAndSelf() {
        let rows = ShortcutReference.groups.flatMap(\.rows)
        #expect(rows.contains { $0.keys == "⌘⌫" })
        #expect(rows.contains { $0.keys == "⌘/" })
        for group in ShortcutReference.groups {      // ForEach ids are per group
            #expect(Set(group.rows.map(\.id)).count == group.rows.count, "\(group.room)")
        }
    }
}
