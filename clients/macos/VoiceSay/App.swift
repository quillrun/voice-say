// VoiceSay — native macOS surface for the voice-say daemon.
//
// Three roles, one app:
//   1. Browse: git-log-style history of every TTS render.
//   2. Play:   native AVAudioPlayer + MPNowPlayingInfoCenter so media keys,
//              Control Center, Touch Bar, and headphone buttons all work.
//   3. Render: compose pane — type text, pick backend/voice, hit Render →
//              POST /render_longform to the voice-say daemon, which owns the
//              canonical TTS pipeline (TTS POST + archive + store append). Same
//              chain as `voice-say render`, different surface.
//
// Source of truth is the voice-say daemon at 127.0.0.1:8890. The app does
// NOT keep its own DB; it consumes /history and the /events SSE stream
// from the daemon, which projects voice.db into memory.
//
// Directory convention:
//   Models/   — pure data + pure logic (no SwiftUI, no IO)
//   Services/ — @Observable state, IO, daemon HTTP/SSE, and stateless helpers
//               with system-framework deps (AVFoundation, Network, …)
//   Theme/    — design tokens + reusable visual atoms (SwiftUI, view-free math OK)
//   Views/    — screens and components (SwiftUI)

import SwiftUI
import AppKit

@main
struct VoiceSayApp: App {
    @State private var store = HistoryStore()
    @State private var player = AudioPlayer()
    @State private var renderer = Renderer()
    @State private var renderQueue = RenderQueue()
    @State private var categories = CategoryStore()
    @State private var declaredTags = DeclaredTagsStore()
    @State private var tagColors = TagColorStore()
    // Settings-panel services — app-level so they are genuinely long-lived
    // (their own doc contract): probe state survives Settings close/reopen.
    @State private var healthMonitor = HealthMonitor()
    @State private var daemonController = DaemonController()
    @State private var backendController = BackendController()
    // Full-screen routing (list / compose / settings / transcript) + the
    // tag dialog. Lets deep views drive window-level overlays without
    // prop-drilling. Replaces ContentView's local composeOpen/settingsOpen.
    @State private var router = UIRouter()
    @State private var keys = PlaybackKeys()
    // Reopen handler: macOS closes the last window but keeps the app
    // alive in the dock. Without this delegate, clicking the dock icon
    // (or `tell application "VoiceSay" to activate`) brings the app forward
    // but creates no window.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(ReaderType.key) private var readerSize = ReaderType.defaultSize

    var body: some Scene {
        WindowGroup("VoiceSay") {
            ContentView()
                .environment(store)
                .environment(player)
                .environment(renderQueue)
                .environment(categories)
                .environment(declaredTags)
                .environment(tagColors)
                .environment(router)
                .environment(healthMonitor)
                .environment(daemonController)
                .environment(backendController)
                .frame(minWidth: 760, idealWidth: 980, minHeight: 540, idealHeight: 760)
                .preferredColorScheme(.dark)
                // Wire the streaming bridge: the SSE apply loop in
                // HistoryStore drives the AudioPlayer's AVQueuePlayer
                // (startStreaming / enqueueChunk / markStreamComplete) for
                // play-while-render. Set here (not in init) because both are
                // @StateObject siblings. Idempotent; harmless if re-run on
                // a fresh window.
                // Explicit captures: the content closure would otherwise hold
                // `store` strongly while onFinished asks for it weakly.
                .onAppear { [store, player, router, keys, renderQueue, renderer] in
                    store.audioPlayer = player
                    // Same plumbing as audioPlayer: lets the store close a
                    // reader open on an episode that just ended.
                    store.router = router
                    // Auto-advance: an episode that plays to its end hands
                    // over to the next one in its series.
                    player.onFinished = { [weak store] e in store?.playNextInSeries(after: e) }
                    keys.player = player
                    keys.store = store
                    keys.router = router
                    keys.install()
                    // RenderQueue's serial pump drives renders through the
                    // Renderer and reports state/errors back to the store.
                    renderQueue.renderer = renderer
                    renderQueue.store = store
                    let queue = renderQueue
                    store.onEpisodeSignal = { [weak queue] signal in
                        queue?.noteEpisode(signal)
                    }
                }
                // HistoryStore.init() already kicks off load() via
                // startStreaming(); the SSE snapshot then reconciles.
                // A second view-side .task here produces a third full
                // rewrite of `entries` on cold launch (init load + this
                // task + snapshot) and a visible flicker. Removed.
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)
        // macOS auto-restores window frame across launches; nothing else needed.
        .commands {
            // The app has no help book; Help carries the one reference.
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { router.toggleShortcuts() }
                    .keyboardShortcut("/")
            }
            // Edit keeps the system's text items (Find, Spelling and Grammar,
            // Substitutions, Transformations, Speech) for the text views
            // (hig/the-menu-bar.md › Edit menu). Find in Library goes BEFORE
            // that group so it keeps ⌘F; the text system's Find… gives the
            // key up (measured: placed after, ours lost ⌘F).
            TextEditingCommands()
            CommandGroup(before: .textEditing) {
                Button("Find in Library") { router.requestSearch() }
                    .keyboardShortcut("f")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { router.open(.settings) }
                    .keyboardShortcut(",")
            }
            CommandGroup(after: .toolbar) {
                // The title says what choosing it does now (hig/the-menu-bar.md
                // › View menu).
                Button(router.sidebarShown ? "Hide Sidebar" : "Show Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Divider()
                Button("Bigger Reader Text") { readerSize = ReaderType.step(readerSize, by: 1) }
                    .keyboardShortcut("+")
                Button("Smaller Reader Text") { readerSize = ReaderType.step(readerSize, by: -1) }
                    .keyboardShortcut("-")
                Button("Default Reader Text") { readerSize = ReaderType.defaultSize }
                    .keyboardShortcut("0")
            }
            // Replacing (not adding after) the New group: SwiftUI's "New
            // VoiceSay Window" also claimed ⌘N and won, so ⌘N opened a second
            // window instead of New Render. Reopen-with-no-window doesn't use
            // the menu (AppDelegate.spawnWindow sends newWindowForTab).
            CommandGroup(replacing: .newItem) {
                Button("New Render") { router.open(.compose) }
                    .keyboardShortcut("n")
                Button("Reload History") { Task { await store.load() } }
                    .keyboardShortcut("r")
            }
            PlayerCommands(player: player, store: store, router: router, keys: keys)
        }
    }
}

/// Bridges AppKit signals that SwiftUI's `App` protocol doesn't expose.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Dark only: the whole app, including popovers,
    /// menus and open panels, ignores the system appearance.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // One window, no tabs: without this AppKit adds Show Tab Bar and
        // Show All Tabs to the View menu for a feature the app doesn't use.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Dock-click reopen path. macOS calls this when the user clicks the
    /// dock icon (or `open` is invoked) and the app has no visible windows.
    /// We forward to the standard "New" menu action, which the WindowGroup
    /// wires to a fresh window instance.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { spawnWindow() }
        return true
    }

    /// AppleScript `activate` path. `activate` doesn't trigger reopen, so
    /// we mirror the dock behaviour here: if the app becomes active with
    /// no visible windows, spawn one. Without this, scripts that use
    /// `tell application "VoiceSay" to activate` after closing the window
    /// silently no-op.
    func applicationDidBecomeActive(_ notification: Notification) {
        if NSApp.windows.allSatisfy({ !$0.isVisible }) {
            spawnWindow()
        }
    }

    /// Same intent for `open` with no document — fires on first launch
    /// when there's no SceneStorage to restore.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    private func spawnWindow() {
        // Standard AppKit "new document" action — SwiftUI's WindowGroup
        // registers as the handler so this produces a fresh window with
        // all our shared @StateObjects attached.
        NSApp.sendAction(#selector(NSWindow.newWindowForTab(_:)), to: nil, from: nil)
    }
}
