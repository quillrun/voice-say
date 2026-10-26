// PlayerCommands — the Playback and Episode menus: every player key and list
// key also sits in the menu bar, where people look for an app's commands and
// where Full Keyboard Access reaches them (hig/the-menu-bar.md › App-specific
// menus). The items run the same actions as the keys (PlaybackKeys.perform,
// the router's requests) and show the same keys as ShortcutReference.
//
// The key equivalents are for show and for clicks: PlaybackKeys stays the
// only key path (see its header), so each item invoked by one of its keys
// returns early through `keys.menuShouldAct()`. Items stay listed when they
// can't act and are disabled instead (hig/the-menu-bar.md › Best practices).

import SwiftUI

struct PlayerCommands: Commands {
    let player: AudioPlayer
    let store: HistoryStore
    let router: UIRouter
    let keys: PlaybackKeys

    var body: some Commands {
        CommandMenu("Playback") {
            let noEntry = player.activeEntry == nil
            // A live render has transport and speed, but no row yet.
            let noTransport = noEntry && !player.streamMode
            item(player.isPlaying ? "Pause" : "Play", .toggle, .space)
                .disabled(noTransport)
            Divider()
            item("Skip Back \(Int(PlaybackKeys.backS)) Seconds", .back, .leftArrow)
                .disabled(noTransport)
            item("Skip Forward \(Int(PlaybackKeys.forwardS)) Seconds", .forward, .rightArrow)
                .disabled(noTransport)
            item("Previous Episode", .previous, .leftArrow, .shift)
                .disabled(noEntry)
            item("Next Episode", .next, .rightArrow, .shift)
                .disabled(noEntry)
            Divider()
            item("Slower", .slower, "[")
                .disabled(noTransport)
            item("Faster", .faster, "]")
                .disabled(noTransport)
            Divider()
            item("Add Bookmark", .bookmark, "b")
                .disabled(noEntry)
            Menu("Sleep Timer") {
                ForEach([15, 30, 45, 60], id: \.self) { m in
                    Button("\(m) Minutes") { player.setSleepTimer(.minutes(m)) }
                }
                Button("End of Episode") { player.setSleepTimer(.endOfEpisode) }
                Divider()
                Button("Off") { player.setSleepTimer(nil) }
                    .disabled(player.sleepTimer == nil)
            }
        }
        CommandMenu("Episode") {
            let target = episodeTarget
            let isStar = target.map { store.starred.contains(store.tagKey(for: $0)) } ?? false
            Button(isStar ? "Unstar" : "Star") {
                if let target { store.toggleStar(target) }
            }
            .disabled(target == nil)
            Button("Tags & Category…") {
                if let target { router.openTagDialog(for: target.id) }
            }
            .disabled(target == nil)
            Divider()
            // ⌘Y, not ⌘O: ⌘O is Open, and here that is Compose's Open
            // Script… (hig/keyboards.md › Standard keyboard shortcuts).
            Button("Read Transcript") {
                if let id = listRowID { router.open(.transcript(id)) }
            }
            .keyboardShortcut("y")
            .disabled(listRowID == nil)
            Divider()
            Button("Move to Trash…") {
                guard keys.menuShouldAct(), let id = listRowID else { return }
                router.requestTrash(id)
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(listRowID == nil)
        }
    }

    /// A Playback item: its key as the menu shows it, the monitor's action.
    private func item(_ title: String, _ action: PlaybackKeys.Action,
                      _ key: KeyEquivalent, _ modifiers: EventModifiers = []) -> some View {
        Button(title) {
            guard keys.menuShouldAct() else { return }
            keys.perform(action)
        }
        .keyboardShortcut(key, modifiers: modifiers)
    }

    /// The expanded row, while the list itself is in front (Read Transcript
    /// and Move to Trash, as their keys).
    private var listRowID: String? {
        router.listInFront ? store.expandedEntryID : nil
    }

    /// The episode Star and Tags act on: the expanded row on the list, the
    /// open one in the reader; none under Compose, Settings or a dialog.
    private var episodeTarget: VoiceEntry? {
        guard !router.overlayOpen else { return nil }
        let id: String?
        switch router.screen {
        case .list: id = store.expandedEntryID
        case .transcript(let t): id = t
        case .compose, .settings: id = nil
        }
        guard let id else { return nil }
        return store.entries.first { $0.id == id }
    }
}
