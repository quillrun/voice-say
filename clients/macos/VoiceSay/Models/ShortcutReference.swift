// ShortcutReference — the one list of the app's keys, shown by Help ▸
// Keyboard Shortcuts (⌘/). Grouped by the room a key works in, because the
// same key changes meaning by room: Esc is Back on a full screen and Cancel
// over the list, ⌘⌫ trashes only with the list in front. The keys read as
// the menus show them, modifiers in the order ⌃⌥⇧⌘ (hig/keyboards.md ›
// Custom keyboard shortcuts); the player rows also carry the key the
// PlaybackKeys monitor sees, and ShortcutReferenceTests holds the two
// together (every monitor action listed once, every listed key mapping to
// its action).

import AppKit

enum ShortcutReference {
    /// A key the PlaybackKeys monitor takes, as the monitor sees it.
    struct PlayerKey {
        let keyCode: UInt16
        let chars: String
        let flags: NSEvent.ModifierFlags
        let action: PlaybackKeys.Action
    }

    struct Row: Identifiable {
        /// Key caps, two spaces between alternatives ("←  →").
        let keys: String
        let action: String
        var player: [PlayerKey] = []
        var id: String { keys + action }
        var caps: [String] { keys.components(separatedBy: "  ") }
    }

    struct Group: Identifiable {
        let room: String
        let rows: [Row]
        var id: String { room }
    }

    static let groups: [Group] = [
        Group(room: "Everywhere", rows: [
            Row(keys: "⌘N", action: "New render"),
            Row(keys: "⌘F", action: "Find in the library"),
            Row(keys: "⌘R", action: "Reload the library"),
            Row(keys: "⌘,", action: "Settings"),
            Row(keys: "⌥⌘S", action: "Show or hide the sidebar"),
            Row(keys: "⌘+  ⌘−", action: "Reader text bigger or smaller"),
            Row(keys: "⌘0", action: "Reader text back to default"),
            Row(keys: "⌘/", action: "This list"),
        ]),
        Group(room: "Player, in the list and the reader", rows: [
            Row(keys: "Space", action: "Play or pause",
                player: [PlayerKey(keyCode: 49, chars: " ", flags: [], action: .toggle)]),
            Row(keys: "←  →", action: "Back \(Int(PlaybackKeys.backS)) s or forward \(Int(PlaybackKeys.forwardS)) s",
                player: [PlayerKey(keyCode: 123, chars: "", flags: [], action: .back),
                         PlayerKey(keyCode: 124, chars: "", flags: [], action: .forward)]),
            Row(keys: "⇧←  ⇧→", action: "Previous or next episode",
                player: [PlayerKey(keyCode: 123, chars: "", flags: .shift, action: .previous),
                         PlayerKey(keyCode: 124, chars: "", flags: .shift, action: .next)]),
            Row(keys: "[  ]", action: "Slower or faster",
                player: [PlayerKey(keyCode: 33, chars: "[", flags: [], action: .slower),
                         PlayerKey(keyCode: 30, chars: "]", flags: [], action: .faster)]),
            Row(keys: "B", action: "Bookmark at the playhead (finished renders)",
                player: [PlayerKey(keyCode: 11, chars: "b", flags: [], action: .bookmark)]),
        ]),
        Group(room: "Library list", rows: [
            Row(keys: "⌘Y", action: "Read the open row's transcript"),
            Row(keys: "⌘⌫", action: "Move the open row to the Trash"),
            Row(keys: "Esc", action: "Leave the search, or cancel a bookmark note"),
        ]),
        Group(room: "Reader", rows: [
            Row(keys: "⌘↩", action: "Save the bookmark note"),
            Row(keys: "Esc", action: "Back to the list"),
        ]),
        Group(room: "Compose", rows: [
            Row(keys: "⌘↩", action: "Render, or add to the queue"),
            Row(keys: "⌘O", action: "Open a script file"),
            Row(keys: "Esc", action: "Back to the list"),
        ]),
        Group(room: "Settings", rows: [
            Row(keys: "Esc", action: "Back to the list"),
        ]),
    ]

    static var playerKeys: [PlayerKey] { groups.flatMap(\.rows).flatMap(\.player) }
}
