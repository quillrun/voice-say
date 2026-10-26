// Renderer — UI-facing wrapper over DaemonClient.render. Errors surface
// via DaemonError directly — no parallel error type. Empty-text
// precondition is mapped to `pipelineFailed(stage: "tts", …)` so the
// existing UI path renders it like any other validation failure.
// (Busy-state for the UI lives on RenderQueue.isRendering, not here.)

import Foundation

/// Seam over the render entry points so RenderQueue's serial pump can be
/// unit-tested with a fake. `Renderer` is the production conformer; both
/// methods return the canonical archive name (or throw `DaemonError`).
@MainActor
protocol RenderRunning: AnyObject {
    func render(text: String, backend: Backend, voice: String, speed: Double,
                tags: [String], overlay: RenderOverlay) async throws -> String
    func resume(fromTS ts: String) async throws -> String
}

@MainActor
final class Renderer: RenderRunning {
    /// POSTs to the voice-say daemon and returns the archive name on success.
    /// Throws `DaemonError` (already a LocalizedError) on any failure.
    func render(text: String,
                backend: Backend,
                voice: String,
                speed: Double,
                tags: [String],
                overlay: RenderOverlay) async throws -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            throw DaemonError.pipelineFailed(stage: "tts", message: "empty text")
        }
        // All fresh renders go through /render_longform: it's the only route the
        // daemon broadcasts the episode_* SSE on (the streaming UI + cancel /
        // save-stop hang off it), and the client always streams. The plain
        // /render route had no live caller and was removed.
        let resp = try await DaemonClient.shared.renderLongform(
            text: clean, backend: backend.id, voice: voice,
            speed: backend.supportsSpeed ? speed : 1.0, tags: tags, overlay: overlay)
        if resp.cancelled == true {
            throw DaemonError.cancelled(episodeID: resp.episodeID ?? "")
        }
        guard let name = resp.archiveName else {
            throw DaemonError.pipelineFailed(stage: "decode", message: "missing archive_name")
        }
        return name
    }

    /// Continue a save-and-stop draft (POST /episode/resume). Like `render`,
    /// the POST stays open until the merged render completes and drives the
    /// streaming SSE lifecycle; this just unwraps the response. Routing resume
    /// through here lets RenderQueue serialize it with any in-flight render so
    /// two renders never run at once (which would clobber `streamingEpisode`).
    func resume(fromTS ts: String) async throws -> String {
        let resp = try await DaemonClient.shared.resumeEpisode(fromTS: ts)
        if resp.cancelled == true {
            throw DaemonError.cancelled(episodeID: resp.episodeID ?? "")
        }
        guard let name = resp.archiveName else {
            throw DaemonError.pipelineFailed(stage: "decode", message: "missing archive_name")
        }
        return name
    }
}
