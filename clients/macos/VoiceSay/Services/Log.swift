// Log — THE logging surface for the app: one os.Logger subsystem with a
// category per concern. Diagnostics go through os.log (visible in
// Console.app / `log stream`),
// never print/NSLog. Messages are marked .public at call sites — they carry
// localhost diagnostics, not user content.
//
// `log stream --predicate 'subsystem == "local.voicesay.VoiceSay"'`

import Foundation
import os

enum Log {
    /// The app's CFBundleIdentifier (a share build has its own).
    private static let subsystem = Bundle.main.bundleIdentifier ?? "local.voicesay.VoiceSay"
    /// Daemon HTTP writes and failures (overlays, config).
    static let daemon = Logger(subsystem: subsystem, category: "daemon")
    /// Playback + progress persistence.
    static let player = Logger(subsystem: subsystem, category: "player")
    /// MpvCompatServer unix-socket IPC.
    static let ipc = Logger(subsystem: subsystem, category: "ipc")
    /// SSE event stream.
    static let sse = Logger(subsystem: subsystem, category: "sse")
}
