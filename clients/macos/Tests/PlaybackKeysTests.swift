// Single-key player control: the key map, and that ⌘/⌃/⌥ combos and
// unrelated keys are never taken.

import AppKit
import Testing
@testable import VoiceSay

@Suite("Playback keys")
struct PlaybackKeysTests {
    private func act(_ code: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> PlaybackKeys.Action? {
        PlaybackKeys.action(keyCode: code, chars: chars, flags: flags)
    }

    @Test("map")
    func map() {
        #expect(act(49, " ") == .toggle)
        #expect(act(123) == .back && act(124) == .forward)
        #expect(act(123, "", .shift) == .previous && act(124, "", .shift) == .next)
        #expect(act(33, "[") == .slower && act(30, "]") == .faster)
        #expect(act(11, "b") == .bookmark && act(11, "B", .shift) == .bookmark)
    }

    @Test("⌘⌫ is the trash key; ⌫ alone and other ⌘⌫ combos are not")
    func trashKey() {
        #expect(PlaybackKeys.isTrashKey(keyCode: 51, flags: .command))
        #expect(!PlaybackKeys.isTrashKey(keyCode: 51, flags: []))
        #expect(!PlaybackKeys.isTrashKey(keyCode: 51, flags: [.command, .shift]))
        #expect(!PlaybackKeys.isTrashKey(keyCode: 51, flags: [.command, .option]))
        #expect(!PlaybackKeys.isTrashKey(keyCode: 117, flags: .command))   // forward delete
    }

    @Test("⌘⌫ targets the expanded row only while the list is in front")
    func trashTarget() {
        #expect(PlaybackKeys.trashTarget(screen: .list, overlayOpen: false, expandedID: "a") == "a")
        #expect(PlaybackKeys.trashTarget(screen: .list, overlayOpen: false, expandedID: nil) == nil)
        #expect(PlaybackKeys.trashTarget(screen: .list, overlayOpen: true, expandedID: "a") == nil)
        #expect(PlaybackKeys.trashTarget(screen: .compose, overlayOpen: false, expandedID: "a") == nil)
        #expect(PlaybackKeys.trashTarget(screen: .settings, overlayOpen: false, expandedID: "a") == nil)
        #expect(PlaybackKeys.trashTarget(screen: .transcript("a"), overlayOpen: false, expandedID: "a") == nil)
    }

    @Test("the list is in front only on .list with no dialog over it")
    func listInFront() {
        #expect(UIRouter.listInFront(screen: .list, overlayOpen: false))
        #expect(!UIRouter.listInFront(screen: .list, overlayOpen: true))
        #expect(!UIRouter.listInFront(screen: .compose, overlayOpen: false))
        #expect(!UIRouter.listInFront(screen: .settings, overlayOpen: false))
        #expect(!UIRouter.listInFront(screen: .transcript("a"), overlayOpen: false))
    }

    @Test("player keys act on the list and in the reader, not under Compose, Settings or a dialog")
    func playerKeysLive() {
        #expect(PlaybackKeys.playerKeysLive(screen: .list, overlayOpen: false))
        #expect(PlaybackKeys.playerKeysLive(screen: .transcript("a"), overlayOpen: false))
        #expect(!PlaybackKeys.playerKeysLive(screen: .list, overlayOpen: true))
        #expect(!PlaybackKeys.playerKeysLive(screen: .transcript("a"), overlayOpen: true))
        #expect(!PlaybackKeys.playerKeysLive(screen: .compose, overlayOpen: false))
        #expect(!PlaybackKeys.playerKeysLive(screen: .settings, overlayOpen: false))
    }

    @Test("passed-on arrows always skip the menu bar; ⌘⌫ only when text has focus")
    func bypassesMenu() {
        for text in [false, true] {
            #expect(PlaybackKeys.bypassesMenu(keyCode: 123, flags: [.numericPad, .function], textHasFocus: text))
            #expect(PlaybackKeys.bypassesMenu(keyCode: 124, flags: [.shift, .function], textHasFocus: text))
            #expect(!PlaybackKeys.bypassesMenu(keyCode: 123, flags: .command, textHasFocus: text))
            #expect(!PlaybackKeys.bypassesMenu(keyCode: 126, flags: .function, textHasFocus: text))   // ↑ isn't ours
            #expect(!PlaybackKeys.bypassesMenu(keyCode: 49, flags: [], textHasFocus: text))           // Space: views first anyway
        }
        #expect(PlaybackKeys.bypassesMenu(keyCode: 51, flags: .command, textHasFocus: true))
        #expect(!PlaybackKeys.bypassesMenu(keyCode: 51, flags: .command, textHasFocus: false))
    }

    @Test("the menu ignores its items' keys: every listed key is a monitor key, ⌘Y is not")
    func monitorKeys() {
        for key in ShortcutReference.playerKeys {
            #expect(PlaybackKeys.isMonitorKey(keyCode: key.keyCode, chars: key.chars, flags: key.flags))
        }
        #expect(PlaybackKeys.isMonitorKey(keyCode: 51, chars: "\u{7F}", flags: .command))
        #expect(!PlaybackKeys.isMonitorKey(keyCode: 16, chars: "y", flags: .command))
        #expect(!PlaybackKeys.isMonitorKey(keyCode: 36, chars: "\r", flags: []))   // Return in an open menu
    }

    @Test("command, control and option combos and other keys pass through")
    func passThrough() {
        #expect(act(49, " ", .command) == nil)
        #expect(act(123, "", .option) == nil)
        #expect(act(11, "b", .control) == nil)
        #expect(act(0, "a") == nil)
        #expect(act(49, " ", .shift) == nil)
    }
}

@Suite("Sidebar visibility")
struct SidebarVisibilityTests {
    @Test("wide: your choice; narrow: hidden unless shown for now")
    func visible() {
        #expect(ContentView.sidebarVisible(width: 1200, collapsed: false, showWhenNarrow: false))
        #expect(!ContentView.sidebarVisible(width: 1200, collapsed: true, showWhenNarrow: true))
        #expect(!ContentView.sidebarVisible(width: 800, collapsed: false, showWhenNarrow: false))
        #expect(ContentView.sidebarVisible(width: 800, collapsed: true, showWhenNarrow: true))
    }

    @Test("keys stay with panels and modals")
    @MainActor func yields() {
        let main = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        #expect(!PlaybackKeys.yields(window: main, modal: false))
        #expect(PlaybackKeys.yields(window: main, modal: true))
        #expect(PlaybackKeys.yields(window: nil, modal: false))
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        #expect(PlaybackKeys.yields(window: panel, modal: false))
    }

    /// A button that takes keyboard focus as it does under Full Keyboard Access.
    final class FocusableButton: NSButton {
        override var acceptsFirstResponder: Bool { true }
    }
    final class FocusableTable: NSTableView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test("Space goes to a keyboard-focused button, not the player; a focused table keeps the keys")
    @MainActor func yieldsToFocusedControl() {
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: true)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let button = FocusableButton(frame: NSRect(x: 0, y: 0, width: 80, height: 30))
        let table = FocusableTable(frame: NSRect(x: 100, y: 0, width: 100, height: 100))
        root.addSubview(button); root.addSubview(table)
        main.contentView = root
        #expect(main.makeFirstResponder(button))
        #expect(PlaybackKeys.yields(window: main, modal: false))
        #expect(main.makeFirstResponder(table))
        #expect(!PlaybackKeys.yields(window: main, modal: false))
    }

    @Test("keys (⌘⌫ included) go to a focused text view first")
    @MainActor func yieldsToTextField() {
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.titled], backing: .buffered, defer: true)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        main.contentView = text
        #expect(main.makeFirstResponder(text))
        #expect(PlaybackKeys.yields(window: main, modal: false))
    }

    @Test("a live render takes transport and speed keys; previous/next and bookmark pass on")
    func streamActions() {
        for a in [PlaybackKeys.Action.toggle, .back, .forward, .slower, .faster] {
            #expect(PlaybackKeys.actsOnStream(a))
        }
        for a in [PlaybackKeys.Action.previous, .next, .bookmark] {
            #expect(!PlaybackKeys.actsOnStream(a))
        }
    }
}
