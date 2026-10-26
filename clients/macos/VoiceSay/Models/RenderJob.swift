// RenderJob — one unit of work in the render queue (Services/RenderQueue).
//
// A value type so the queue can freely copy + reorder it. The queue's serial
// pump turns each job into exactly one daemon render: `.fresh` text →
// POST /render_longform (stream mode), `.resume` → POST /episode/resume.
// Each job carries its OWN backend + voice, so a queue can mix models
// (qwen3 then kokoro then …) — the "swap between models" requirement.

import Foundation

/// Display fields the daemon sets on the new row with the render (its
/// title / series / episode; nil = not set).
struct RenderOverlay: Equatable, Sendable {
    var title: String? = nil
    var series: String? = nil
    var episode: Int? = nil
    static let none = RenderOverlay()
}

struct RenderJob: Identifiable, Equatable, Sendable {
    /// What this job renders.
    enum Source: Equatable, Sendable {
        /// Fresh text → POST /render_longform (stream mode).
        case fresh(text: String)
        /// Continue a save-and-stop draft → POST /episode/resume. The daemon
        /// re-chunks the draft's STORED text with its original settings, so
        /// `backendID`/`voice` here are display-only (the row's chip), not sent.
        case resume(fromTS: String)
    }

    let id: UUID
    var source: Source
    /// Backend + voice this render runs on. For `.fresh` these ARE the render
    /// settings and are editable while the job waits (model swap). For
    /// `.resume` they're the draft's settings, shown on the chip only.
    var backendID: String
    var voice: String
    var speed: Double
    var tags: [String]
    /// Silent batch by default; when true THIS render plays while it streams
    /// (the per-item override). A draining queue otherwise renders silently.
    var playWhileRendering: Bool
    /// Display title — first line of the text, or the draft's title for resume.
    var title: String
    /// Title / series / episode the daemon sets on the new row.
    var overlay: RenderOverlay
    /// Why the last attempt failed; set only on a job in `RenderQueue.failed`.
    var failure: String? = nil

    init(id: UUID = UUID(),
         source: Source,
         backendID: String,
         voice: String,
         speed: Double = 1.0,
         tags: [String] = [],
         playWhileRendering: Bool = false,
         title: String,
         overlay: RenderOverlay = .none) {
        self.id = id
        self.source = source
        self.backendID = backendID
        self.voice = voice
        self.speed = speed
        self.tags = tags
        self.playWhileRendering = playWhileRendering
        self.title = title
        self.overlay = overlay
    }

    /// Approx audio chars/second — the daemon's `predicted_total_s` constant
    /// (engine.CHARS_PER_SECOND). Drives the "up next" ETA, which is a coarse
    /// estimate by construction and is always labelled "~".
    static let charsPerSecond: Double = 17.8

    /// Characters to render — known for fresh text, unknown (0) for a resume
    /// whose remaining length lives server-side.
    var charCount: Int {
        if case .fresh(let text) = source { return text.count }
        return 0
    }

    /// Rough render-time estimate (seconds) for the waiting-row ETA, or nil
    /// when unknown (resume).
    var estDurationS: Double? {
        guard charCount > 0 else { return nil }
        return Double(charCount) / Self.charsPerSecond
    }

    var isResume: Bool {
        if case .resume = source { return true }
        return false
    }

    /// The draft ts this job continues, or nil for a fresh render. (Lets a queued
    /// resume card open the source draft's details directly.)
    var resumeTS: String? {
        if case let .resume(ts) = source { return ts }
        return nil
    }

    /// The text a fresh job will render, or nil for a resume (its text lives
    /// server-side). Backs the read-only details preview of a queued fresh render.
    var freshText: String? {
        if case let .fresh(text) = source { return text }
        return nil
    }

    /// The fallback title for untitled text: its first sentence (as a history
    /// row derives it), else its first line, trimmed to a row-friendly length.
    /// The queue + the live streaming card derive it the same way.
    static func title(fromText text: String) -> String {
        if let sentence = VoiceEntry.firstSentence(of: text) { return sentence }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "Untitled" }
        let firstLine = t.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? t
        return String(firstLine.prefix(120))
    }

    /// True when the render carries a set title (the daemon puts it on the
    /// row); the rows dim the first-sentence fallback otherwise.
    var hasTitle: Bool {
        !(overlay.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// The row heading: the set title, else the fallback.
    var displayTitle: String {
        if hasTitle, let t = overlay.title { return t.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let text = freshText { return Self.title(fromText: text) }
        return title.isEmpty ? "Untitled" : title
    }

    /// "Series A · 181 · 16,472 chars" — series · episode (when set), then
    /// the size; a resume's remaining length lives server-side, so it reads
    /// "continue draft". `withETA` appends the coarse "~m:ss" estimate.
    func metaLine(withETA: Bool) -> String {
        var parts: [String] = []
        if let s = VoiceEntry.seriesLabel(series: overlay.series, episode: overlay.episode) { parts.append(s) }
        if isResume {
            parts.append("continue draft")
        } else {
            parts.append("\(fmtCompactChars(charCount)) char\(charCount == 1 ? "" : "s")")
            if withETA, let est = estDurationS { parts.append("~\(fmtDuration(Int(est)))") }
        }
        return parts.joined(separator: " · ")
    }
}
