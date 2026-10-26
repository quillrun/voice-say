// StreamingEpisode — client-side model for a "play while rendering"
// session. The daemon, in stream mode, emits three SSE events:
//   episode_start  → one StreamingEpisode is created
//   chunk_ready    → one StreamChunk appended; renderHeadS advances
//   episode_complete → the canonical render row exists; we hand the
//                      selection to it and drop this provisional model.
//
// While alive, HistoryStore holds the active StreamingEpisode and renders
// a provisional card at the top of the list (it has no voice.db row / ts
// yet). On episode_complete the canonical VoiceEntry (delivered via the
// `render` SSE event, ordering guaranteed by the daemon) is already in the
// store keyed by the event's `ts`, so we swap selection onto it and clear
// this provisional model.

import Foundation
import Observation

@MainActor
@Observable
final class StreamingEpisode: Identifiable {
    let id: String                 // = episode_start.episode_id
    let predictedTotalS: Double    // episode_start.predicted_total_s (chars/17.8)
    let totalChunks: Int
    let chars: Int
    let backend: String
    let voice: String
    /// The full chunked transcript (episode_start.text). Read-while-rendering
    /// displays this and grays past `renderedChars`. Empty if the daemon is
    /// too old to send it.
    let fullText: String
    /// Audio seconds already rendered into the draft prefix on a RESUME
    /// (episode_start.prefix_audio_s). The prefix is concatenated server-side,
    /// never streamed as chunks, so the player seeds its render-head + playhead
    /// here to keep both in full-text space. 0 for a fresh render.
    let prefixAudioS: Double

    /// The play intent captured at episode_start. `episode_complete` finalizes
    /// against THIS — not the live `HistoryStore.pendingPlayIntent`, which the
    /// render-queue pump may have already advanced to the next job by the time
    /// completion is processed (a play-while-render episode could otherwise
    /// be stopped, or a silent batch episode played).
    let playIntent: HistoryStore.StreamPlayIntent

    /// Started by another client (the CLI, a script on the HTTP API): shown with its
    /// progress under Rendering, but never armed in the player — it must not
    /// stop or replace what's playing. It plays from its row once it lands.
    let isForeign: Bool

    /// True when this episode drives the player: this app's own render with
    /// play-while-rendering on. A silent batch render or another client's
    /// render never arms the player, so it never stops or replaces what's
    /// playing, never opens the reader, and shows no transport.
    var armsPlayer: Bool { !isForeign && playIntent == .whileRendering }

    /// The row-to-be's title / series / episode number (episode_start; nil
    /// when the render sets none or the daemon predates them). The card's
    /// identity block reads them so the user sees WHAT is rendering.
    let title: String?
    let series: String?
    let episodeNumber: Int?

    /// Wall-clock the episode was born (episode_start). Drives the pre-first-
    /// chunk step cycler in `statusLabel` so the "preparing" stages advance on
    /// the clock rather than jumping. Set once, at creation.
    let startedAt = Date()

    /// = last chunk_ready.cumulative_audio_s — the render-head, i.e. how
    /// many seconds of audio have been rendered and are safe to play.
    var renderHeadS: Double = 0
    /// = last chunk_ready.rendered_chars — char offset into `fullText` rendered
    /// so far. Text beyond this is not-yet-rendered (grayed in the reader).
    var renderedChars: Int = 0
    /// Appended once per chunk_ready event.
    var chunks: [StreamChunk] = []
    /// Set true once episode_complete arrives.
    var done: Bool = false

    init(id: String, predictedTotalS: Double, totalChunks: Int,
         chars: Int, backend: String, voice: String, fullText: String = "",
         prefixAudioS: Double = 0,
         playIntent: HistoryStore.StreamPlayIntent = .whileRendering,
         isForeign: Bool = false,
         title: String? = nil, series: String? = nil, episodeNumber: Int? = nil) {
        self.id = id
        self.predictedTotalS = predictedTotalS
        self.totalChunks = totalChunks
        self.chars = chars
        self.backend = backend
        self.voice = voice
        self.fullText = fullText
        self.prefixAudioS = prefixAudioS
        self.playIntent = playIntent
        self.isForeign = isForeign
        self.title = title
        self.series = series
        self.episodeNumber = episodeNumber
    }
}

extension StreamingEpisode {
    /// Phase labels for the pre-first-chunk gap. Shown in sequence (and held on
    /// the last) while the daemon splits the text, warms the voice, and renders
    /// chunk 1 — there's no audio to play yet, so this occupies the wait with
    /// what is actually happening rather than a static "Rendering…". The stages
    /// are real and ordered (split → warm → first chunk); the cycler approximates
    /// their timing since the daemon emits no per-stage event, and holds on the
    /// last step (no loop-back) so it never implies a precise progress bar.
    static let prepSteps = ["Preparing…", "Warming up the voice…", "Rendering the first chunk…"]
    /// Seconds each prep step holds before advancing to the next.
    static let prepStepInterval: TimeInterval = 2.4

    /// The primary live-render status line, derived purely from client-
    /// observable state (chunk count, predicted total, the finalizing flag) —
    /// no daemon phase events needed. `now` drives the pre-first-chunk step
    /// cycler; pass a TimelineView tick so it advances on the clock. Single
    /// source of the label text so the streaming card + transcript agree.
    func statusLabel(at now: Date, isFinalizing: Bool, isForcingStop: Bool = false) -> String {
        if isForcingStop { return "Stopping…" }
        if isFinalizing { return "Finishing current chunk…" }
        if chunks.count == 0 {
            let elapsed = max(0, now.timeIntervalSince(startedAt))
            let i = min(Int(elapsed / Self.prepStepInterval), Self.prepSteps.count - 1)
            return Self.prepSteps[i]
        }
        // All predicted chunks rendered but episode_complete hasn't landed —
        // the daemon is concatenating + encoding the final file.
        if chunks.count >= totalChunks { return "Finishing up…" }
        return "Rendering chunk \(min(chunks.count + 1, totalChunks)) of \(totalChunks)…"
    }

    /// Render-completion fraction from CHUNKS — the authoritative, type-agnostic
    /// progress signal. The daemon sends an exact `total_chunks` up front and
    /// one `chunk_ready` per chunk, for EVERY backend and every render type
    /// (single/multi-chunk, mock, resume), so completed/total is exact work-
    /// done. Unlike `renderHeadS / predictedTotalS` (a coarse chars/17.8
    /// estimate that saturates on the first chunk of an audio-heavy render),
    /// this never lies — the determinate render-progress bar reads from it.
    var renderFractionByChunks: Double {
        totalChunks > 0 ? min(1, Double(chunks.count) / Double(totalChunks)) : 0
    }


    /// Whole-episode audio length extrapolated from the MEASURED pace, or nil
    /// before the first chunk. `renderedChars` counts from the start of the
    /// full text, while `renderHeadS` (chunk_ready.cumulative_audio_s) counts
    /// only the streamed remainder — on a resume the draft prefix's audio is
    /// added back so both sides cover the same span. Seconds per char so far
    /// × all chars.
    var estimatedTotalS: Double? {
        let basis = fullText.isEmpty ? chars : fullText.count
        guard renderedChars > 0, basis > 0 else { return nil }
        return (prefixAudioS + renderHeadS) * Double(basis) / Double(renderedChars)
    }

    // MARK: Identity — what is rendering

    /// True when the render carries a set title; the card dims the fallback.
    var hasTitle: Bool {
        !(title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// The card heading: the set title, else the text's first sentence (the
    /// same fallback the queued rows and history rows use).
    var displayTitle: String {
        if hasTitle, let t = title { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
        return RenderJob.title(fromText: fullText)
    }

    /// Characters in the whole episode: the full text when the daemon sent it
    /// (a resume's `chars` covers only the remainder), else `chars`.
    var totalChars: Int { fullText.isEmpty ? chars : fullText.count }

    /// "Series A · 181 · voice · backend · 16,472 chars · from the CLI" —
    /// the identity meta line (series · episode only when set; the source only
    /// when another client started it).
    var identityMetaLine: String {
        var parts: [String] = []
        if let s = VoiceEntry.seriesLabel(series: series, episode: episodeNumber) { parts.append(s) }
        parts += [voice, backend, "\(fmtCompactChars(totalChars)) char\(totalChars == 1 ? "" : "s")"]
        if isForeign { parts.append("from the CLI") }
        return parts.joined(separator: " · ")
    }

    // MARK: Pace — how long until it is done

    /// "chunk K of N".
    var chunkCountLabel: String {
        "chunk \(min(chunks.count, totalChunks)) of \(totalChunks)"
    }

    /// "12:40 rendered" — audio landed so far (a resume's draft prefix
    /// included), the tangible output of the wait.
    var renderedLabel: String {
        "\(fmtDuration(Int((prefixAudioS + renderHeadS).rounded(.down)))) rendered"
    }

    /// Wall time since episode_start.
    func elapsedS(at now: Date) -> Double { max(0, now.timeIntervalSince(startedAt)) }

    /// "elapsed m:ss".
    func elapsedLabel(at now: Date) -> String {
        "elapsed \(fmtDuration(Int(elapsedS(at: now).rounded(.down))))"
    }

    /// Measured seconds per chunk: the wall time between the first and the last
    /// chunk landing over the chunks landed between them. nil until two chunks
    /// have landed — the first chunk also carries the warm-up, so it can't set
    /// the pace on its own.
    var secondsPerChunk: Double? {
        guard chunks.count >= 2, let first = chunks.first, let last = chunks.last else { return nil }
        return max(0, last.landedAt.timeIntervalSince(first.landedAt)) / Double(chunks.count - 1)
    }

    /// Seconds until the last chunk lands at the measured pace: the chunk in
    /// flight (its pace less the time it has already run, never below zero)
    /// plus a full pace for each chunk after it. 0 once every chunk is in; nil
    /// while `secondsPerChunk` is.
    func remainingS(at now: Date) -> Double? {
        let left = totalChunks - chunks.count
        if left <= 0 { return 0 }
        guard let pace = secondsPerChunk, let last = chunks.last else { return nil }
        let inFlight = max(0, pace - now.timeIntervalSince(last.landedAt))
        return pace * Double(left - 1) + inFlight
    }

    /// "about m:ss left"; "estimating…" until the pace is measured;
    /// "finishing up…" once every chunk is in and the file is being joined.
    func remainingLabel(at now: Date) -> String {
        guard let r = remainingS(at: now) else { return "estimating…" }
        if totalChunks - chunks.count <= 0 { return "finishing up…" }
        return "about \(fmtDuration(Int(r.rounded()))) left"
    }

    /// True before the first chunk lands — there's no exact fraction yet, so the
    /// progress bar shows an honest INDETERMINATE state (not a fabricated %)
    /// while the daemon splits the text + warms the voice.
    var isPreparing: Bool { chunks.isEmpty }
}

/// One rendered chunk in a streaming episode. `id == seq` (1-based), so
/// SwiftUI ForEach diffing is stable as chunks append.
struct StreamChunk: Identifiable, Hashable, Sendable {
    let seq: Int            // 1-based
    let path: String        // absolute chunk_path, playable now
    let durationS: Double
    /// Cumulative char offset into fullText rendered THROUGH this chunk
    /// (= chunk_ready.rendered_chars). Drives the live read-along's piecewise
    /// play-head → char interpolation so the highlight tracks each chunk's pace.
    let cumulativeChars: Int
    /// Wall-clock the chunk_ready arrived — the samples the pace/ETA is measured from.
    var landedAt: Date = Date()
    var id: Int { seq }
}
