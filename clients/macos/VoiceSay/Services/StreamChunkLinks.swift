// StreamChunkLinks — the app's own hold on play-while-rendering chunk files.
//
// chunk_ready names a transient wav the daemon deletes right after the final
// concat, before episode_complete (engine.py `_render_longform_stream`
// finally). Rendering runs ahead of playback, so the queue still holds items
// for chunks the player hasn't opened yet; from a deleted path they would
// fail. The daemon can't know when the listener is done (a pause can last
// any time), so the app keeps a hard link to each chunk as it is queued (same
// per-user temp volume: no copy) and drops its links when the stream is torn
// down. The daemon's unlink then removes only its own name.

import Foundation

enum StreamChunkLinks {
    /// Per process, so a second app build streaming beside this one keeps
    /// its own links.
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("voicesay-stream-\(ProcessInfo.processInfo.processIdentifier)",
                                isDirectory: true)

    /// A link to `chunk` inside `dir` (a copy if a link can't be made); the
    /// chunk's own URL if neither works, e.g. the daemon already removed it.
    static func retain(_ chunk: URL, in dir: URL = directory) -> URL {
        let fm = FileManager.default
        let dest = dir.appendingPathComponent(chunk.lastPathComponent)
        if fm.fileExists(atPath: dest.path) { return dest }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if (try? fm.linkItem(at: chunk, to: dest)) != nil { return dest }
        if (try? fm.copyItem(at: chunk, to: dest)) != nil { return dest }
        return chunk
    }

    /// Drop every link (stream torn down). The daemon's chunk files are not
    /// touched: these are separate names for them.
    static func release(in dir: URL = directory) {
        try? FileManager.default.removeItem(at: dir)
    }
}
