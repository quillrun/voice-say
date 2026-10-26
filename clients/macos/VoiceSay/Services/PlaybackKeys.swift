// PlaybackKeys — single-key player control while the list or reader has
// focus: Space play/pause, ←/→ −15/+30 s, ⇧←/⇧→ previous/next entry in the
// current list order, [ ] slower/faster, B bookmark at the playhead. Also
// ⌘⌫ (Move to Trash) for the expanded row, only while the list is in front.
//
// The monitor is the only path a key takes to these actions. Any key goes to
// a focused text field, a keyboard-focused control (Space presses a focused
// button), a panel or a sheet first, and ⌘/⌃/⌥ combinations are never taken,
// except ⌘⌫. The player keys act only on the list and in the reader, never
// under Compose or Settings or with a dialog (tags, taxonomy) open over the
// list; ⌘⌫ only with the list in front (the list stays mounted under Compose,
// Settings and the reader, so ⌘⌫ while typing there opened the trash dialog
// for a row nobody could see).
//
// The Playback and Episode menus show the same keys as key equivalents, so
// the commands can be found (hig/the-menu-bar.md › App-specific menus). Two
// rules keep the menus from becoming a second key path: a menu item invoked
// by one of these keys does nothing (`menuShouldAct`: the monitor already
// saw the key and passed), and a key AppKit offers the menu before the
// focused view (arrows and ⌘⌫, even to a disabled item) goes straight to that
// view when the monitor passes, so ← still moves the caret.

import AppKit

@MainActor
final class PlaybackKeys {
    enum Action: Equatable, CaseIterable { case toggle, back, forward, previous, next, slower, faster, bookmark }

    nonisolated static let backS: TimeInterval = 15
    nonisolated static let forwardS: TimeInterval = 30

    weak var player: AudioPlayer?
    weak var store: HistoryStore?
    weak var router: UIRouter?
    private var monitor: Any?

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if self.handle(event) { return nil }
            if let responder = NSApp.keyWindow?.firstResponder,
               Self.bypassesMenu(keyCode: event.keyCode, flags: event.modifierFlags,
                                 textHasFocus: responder is NSText) {
                responder.keyDown(with: event)
                return nil
            }
            return event
        }
    }

    /// The monitor's own work; true when the key was used.
    private func handle(_ event: NSEvent) -> Bool {
        guard !Self.yields(window: NSApp.keyWindow, modal: NSApp.modalWindow != nil),
              let router else { return false }
        let overlayOpen = router.overlayOpen
        if Self.isTrashKey(keyCode: event.keyCode, flags: event.modifierFlags) {
            guard let id = Self.trashTarget(screen: router.screen, overlayOpen: overlayOpen,
                                            expandedID: store?.expandedEntryID)
            else { return false }
            router.requestTrash(id)
            return true
        }
        guard Self.playerKeysLive(screen: router.screen, overlayOpen: overlayOpen),
              let action = Self.action(keyCode: event.keyCode,
                                       chars: event.charactersIgnoringModifiers ?? "",
                                       flags: event.modifierFlags)
        else { return false }
        return perform(action)
    }

    /// A passed-on key the menu bar would take before the focused view: the
    /// arrow equivalents (function keys reach menus first) always, ⌘⌫ only
    /// when text has focus (it is delete-to-line-start there; elsewhere the
    /// menu may have it and `menuShouldAct` stops it).
    nonisolated static func bypassesMenu(keyCode: UInt16, flags: NSEvent.ModifierFlags,
                                         textHasFocus: Bool) -> Bool {
        if isTrashKey(keyCode: keyCode, flags: flags) { return textHasFocus }
        return (keyCode == 123 || keyCode == 124)
            && flags.intersection([.command, .control, .option]).isEmpty
    }

    /// One of the monitor's keys (a player key or ⌘⌫).
    nonisolated static func isMonitorKey(keyCode: UInt16, chars: String,
                                         flags: NSEvent.ModifierFlags) -> Bool {
        action(keyCode: keyCode, chars: chars, flags: flags) != nil
            || isTrashKey(keyCode: keyCode, flags: flags)
    }

    /// False when a Playback or Episode menu item was reached by one of the
    /// monitor's keys rather than a click or menu navigation: the monitor
    /// already passed on that key, so it isn't meant for the player here.
    func menuShouldAct() -> Bool {
        guard let e = NSApp.currentEvent, e.type == .keyDown else { return true }
        return !Self.isMonitorKey(keyCode: e.keyCode, chars: e.charactersIgnoringModifiers ?? "",
                                  flags: e.modifierFlags)
    }

    /// ⌘⌫ exactly (51 = Delete/backspace; no ⇧/⌃/⌥).
    nonisolated static func isTrashKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        keyCode == 51 && flags.intersection([.command, .control, .option, .shift]) == .command
    }

    /// The row ⌘⌫ may trash: the expanded one, and only while the list itself
    /// is in front (not Compose, Settings, the reader, or a dialog over it).
    nonisolated static func trashTarget(screen: UIRouter.Screen, overlayOpen: Bool,
                                        expandedID: String?) -> String? {
        UIRouter.listInFront(screen: screen, overlayOpen: overlayOpen) ? expandedID : nil
    }

    /// Where the player keys apply: the list and the reader, with no dialog
    /// over them (Compose and Settings have their own controls and pickers).
    nonisolated static func playerKeysLive(screen: UIRouter.Screen, overlayOpen: Bool) -> Bool {
        guard !overlayOpen else { return false }
        if case .transcript = screen { return true }
        return screen == .list
    }

    /// True when the key belongs to someone else: a text field / text view
    /// has the keyboard, a control has keyboard focus (Full Keyboard Access:
    /// Space presses the focused button or checkbox), or the key window isn't
    /// the main window (an open or save panel, a modal, a sheet) — Space
    /// there is Quick Look, not play. A table (SwiftUI List) is a control too
    /// but has nothing to press with Space, so it keeps the keys.
    static func yields(window: NSWindow?, modal: Bool) -> Bool {
        guard let window, !modal else { return true }
        let responder = window.firstResponder
        return window is NSPanel || window.attachedSheet != nil
            || responder is NSText
            || (responder is NSControl && !(responder is NSTableView))
    }

    /// Pure key → action map (nil = not ours). 49 Space, 123 ←, 124 →.
    nonisolated static func action(keyCode: UInt16, chars: String,
                                   flags: NSEvent.ModifierFlags) -> Action? {
        let mods = flags.intersection([.command, .control, .option])
        guard mods.isEmpty else { return nil }
        let shift = flags.contains(.shift)
        switch keyCode {
        case 49: return shift ? nil : .toggle
        case 123: return shift ? .previous : .back
        case 124: return shift ? .next : .forward
        default: break
        }
        switch chars.lowercased() {
        case "[": return .slower
        case "]": return .faster
        case "b": return .bookmark
        default: return nil
        }
    }

    /// What a live render (play-while-rendering) can take: transport and
    /// speed. It has no row yet, so no neighbours to step to and nothing to
    /// hold a bookmark.
    nonisolated static func actsOnStream(_ action: Action) -> Bool {
        switch action {
        case .toggle, .back, .forward, .slower, .faster: return true
        case .previous, .next, .bookmark: return false
        }
    }

    /// Runs the action; false when there's nothing to act on (key passes on).
    /// Also the Playback menu's action, so a click and a key do the same.
    @discardableResult
    func perform(_ action: Action) -> Bool {
        guard let player else { return false }
        if player.streamMode {
            guard Self.actsOnStream(action) else { return false }
            switch action {
            case .toggle: player.togglePlay()
            case .back: player.skip(by: -Self.backS)
            case .forward: player.skip(by: Self.forwardS)
            case .slower: player.bumpSpeed(-1)
            case .faster: player.bumpSpeed(+1)
            case .previous, .next, .bookmark: break
            }
            return true
        }
        guard let entry = player.activeEntry else { return false }
        switch action {
        case .toggle: player.togglePlay()
        case .back: player.skip(by: -Self.backS)
        case .forward: player.skip(by: Self.forwardS)
        case .slower: player.bumpSpeed(-1)
        case .faster: player.bumpSpeed(+1)
        case .previous, .next:
            guard let target = store?.playableNeighbor(of: entry.id,
                                                       direction: action == .next ? 1 : -1)
            else { return true }
            player.play(target)
            store?.markSeenIfNew(target.id)
        case .bookmark:
            guard player.duration > 0 else { return true }
            store?.addBookmark(entry, position: min(1, player.currentTime / player.duration), note: "")
        }
        return true
    }
}
