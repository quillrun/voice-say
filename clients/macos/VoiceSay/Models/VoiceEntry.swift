// Mirrors the entry shape the voice-say daemon serves at /history and /search.
// Optional fields stay optional — smoke-test entries lack archive_path, and
// progress/overlay are absent until VoiceSay / bash / MCP write them. The
// daemon now serves the FULL transcript inline as `text`, so the app never
// reads files off disk for transcripts.

import Foundation

// MARK: - Decoding helper

extension KeyedDecodingContainer {
    /// Numeric field that may be encoded as Int or Double. Older JSONL
    /// rows wrote `duration_s` as Int; the daemon now writes Double.
    /// Returns 0 when missing or the wrong type.
    func decodeNumeric(forKey key: Key) -> Double {
        if let d = try? decode(Double.self, forKey: key) { return d }
        if let i = try? decode(Int.self, forKey: key) { return Double(i) }
        return 0
    }
}

// MARK: - VoiceEntry

struct VoiceEntry: Codable, Identifiable, Sendable {
    let ts: String
    let backend: String
    let voice: String?
    let speed: Double?
    let chars: Int
    let words: Int
    let durationS: Double
    /// Wall-clock seconds the daemon took to render this entry (TTS + archive +
    /// probe). nil for rows written before render-timing existed — surfaced as
    /// "Unknown", never synthesized.
    let renderElapsedS: Double?
    let bytes: Int
    let archiveName: String?
    let archivePath: String?
    /// Full transcript, served inline by the daemon. nil only for
    /// legacy/smoke rows.
    let text: String?
    /// "say" (short utterance ≤ threshold) or "render". Backs the Says
    /// category. nil for legacy rows the daemon hasn't reclassified.
    let kind: String?
    let tags: [String]?
    /// Resume boundary, set ONLY on a save-and-stop draft: the joined full
    /// text the render was chunked from + the clean chunk-boundary char offset
    /// it reached. Both nil for every normal render. Drive `isResumableDraft`
    /// + the "Continue render" button (POST /episode/resume).
    let resumeFullText: String?
    let resumeCharOffset: Int?
    /// Per-chunk read-along seams `[[audio_s, char_offset], ...]` in finished-file
    /// coordinates (audio scaled to the true duration). Lets the karaoke read-head
    /// piecewise-interpolate each chunk's real pace instead of one uniform
    /// chars/sec. nil for a single render (uniform is exact) or a pre-seam-map row.
    let seamMap: [[Double]]?
    var progress: ProgressInfo?
    var overlay: Overlay?

    var id: String { ts }

    enum CodingKeys: String, CodingKey {
        case ts, backend, voice, speed, chars, words, bytes, tags, text, kind
        case durationS   = "duration_s"
        case renderElapsedS = "render_elapsed_s"
        case archiveName = "archive_name"
        case archivePath = "archive_path"
        case resumeFullText  = "resume_full_text"
        case resumeCharOffset = "resume_char_offset"
        case seamMap = "seam_map"
        case progress, overlay
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts          = try c.decode(String.self, forKey: .ts)
        backend     = try c.decode(String.self, forKey: .backend)
        voice       = try c.decodeIfPresent(String.self, forKey: .voice)
        speed       = try c.decodeIfPresent(Double.self, forKey: .speed)
        chars       = try c.decodeIfPresent(Int.self, forKey: .chars) ?? 0
        words       = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
        durationS   = c.decodeNumeric(forKey: .durationS)
        renderElapsedS = try c.decodeIfPresent(Double.self, forKey: .renderElapsedS)
        bytes       = try c.decodeIfPresent(Int.self, forKey: .bytes) ?? 0
        archiveName = try c.decodeIfPresent(String.self, forKey: .archiveName)
        archivePath = try c.decodeIfPresent(String.self, forKey: .archivePath)
        text        = try c.decodeIfPresent(String.self, forKey: .text)
        kind        = try c.decodeIfPresent(String.self, forKey: .kind)
        tags        = try c.decodeIfPresent([String].self, forKey: .tags)
        resumeFullText   = try c.decodeIfPresent(String.self, forKey: .resumeFullText)
        resumeCharOffset = try c.decodeIfPresent(Int.self, forKey: .resumeCharOffset)
        seamMap          = try c.decodeIfPresent([[Double]].self, forKey: .seamMap)
        progress    = try c.decodeIfPresent(ProgressInfo.self, forKey: .progress)
        overlay     = try c.decodeIfPresent(Overlay.self, forKey: .overlay)
    }
}

// Hash + equality keyed off ts only — `progress` and `overlay` are
// mutable and shouldn't change the row's identity for SwiftUI diffing.
// Without this, a 4 Hz progress tick reissues the row's hash and
// SwiftUI tears down + rebuilds the CommitRow instead of updating it.
extension VoiceEntry: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(ts) }
    static func == (a: VoiceEntry, b: VoiceEntry) -> Bool { a.ts == b.ts }
}

// MARK: - Overlay

struct Overlay: Codable, Hashable, Sendable {
    var starred: Bool
    var deleted: Bool
    var tags: [String]
    /// Tags the user deleted from this entry. Subtracted from the effective
    /// tag set so "delete tag" works even on immutable server (render-time)
    /// tags. See HistoryStore.tagsFor.
    var removedTags: [String]
    var bookmarks: [Bookmark]
    /// User-set display title; overrides the derived (first-sentence) row
    /// title when non-empty. nil = fall back to derivedTitle().
    var title: String?
    /// Series this entry belongs to (nil = none) and its episode number; a
    /// series lists in episode order (sidebar SERIES).
    var series: String?
    var episode: Int?

    enum CodingKeys: String, CodingKey {
        case starred, deleted, tags, bookmarks, title, series, episode
        case removedTags = "removed_tags"
    }

    static let empty = Overlay(starred: false, deleted: false, tags: [], removedTags: [], bookmarks: [], title: nil)

    init(starred: Bool, deleted: Bool, tags: [String], removedTags: [String] = [],
         bookmarks: [Bookmark], title: String? = nil,
         series: String? = nil, episode: Int? = nil) {
        self.starred = starred
        self.deleted = deleted
        self.tags = tags
        self.removedTags = removedTags
        self.bookmarks = bookmarks
        self.title = title
        self.series = series
        self.episode = episode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        starred      = try c.decodeIfPresent(Bool.self, forKey: .starred) ?? false
        deleted      = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        tags         = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        removedTags  = try c.decodeIfPresent([String].self, forKey: .removedTags) ?? []
        bookmarks    = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        title        = try c.decodeIfPresent(String.self, forKey: .title)
        series       = try c.decodeIfPresent(String.self, forKey: .series)
        episode      = try c.decodeIfPresent(Int.self, forKey: .episode)
    }
}

// MARK: - Bookmark

struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let position: Double
    let note: String
}

// MARK: - ProgressInfo

struct ProgressInfo: Codable, Hashable, Sendable {
    let playedS: Double
    let durationS: Double
    let playCount: Int
    let completed: Bool
    let lastPlayed: String?

    enum CodingKeys: String, CodingKey {
        case playedS    = "played_s"
        case durationS  = "duration_s"
        case playCount  = "play_count"
        case lastPlayed = "last_played"
        case completed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playedS    = c.decodeNumeric(forKey: .playedS)
        durationS  = c.decodeNumeric(forKey: .durationS)
        playCount  = try c.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        completed  = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        lastPlayed = try c.decodeIfPresent(String.self, forKey: .lastPlayed)
    }
}

extension VoiceEntry {
    /// "Series A · 012" for an entry in a series (episode zero-padded to
    /// three digits; the series alone when unnumbered); nil otherwise.
    var seriesLabel: String? {
        Self.seriesLabel(series: overlay?.series, episode: overlay?.episode)
    }

    /// The series label from bare fields — shared with the live render card
    /// and the queued rows, which have no VoiceEntry yet.
    static func seriesLabel(series: String?, episode: Int?) -> String? {
        guard let s = series, !s.isEmpty else { return nil }
        guard let n = episode else { return s }
        return "\(s) · \(String(format: "%03d", n))"
    }

    /// The first sentence of `text` (8–120 chars, ending . ! or ?) with inline
    /// [emotion]/<angle> markup and <|control|> tokens stripped, or nil when
    /// there is none. The title fallback for a row, a queued render and the
    /// live render card.
    static func firstSentence(of text: String) -> String? {
        // Strip inline [emotion]/<angle> markup (backends with emotion tags keep it
        // in the stored text) and `voice-say render`'s <|prosody:pause|>-style tokens before picking
        // the first sentence, so the title isn't "[whispering] The secret is
        // out." EmotionMarkup constrains the angle arm so prose comparison
        // operators like "x < 5 and y > 3" survive.
        let text = EmotionMarkup.displayText(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: #"^(.{8,120}?[.!?])(\s|$)"#, options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The two-line row preview: the transcript after its title (when the
    /// title is the transcript's own first sentence), markup stripped, as one
    /// flowing line. Only the head is shown, so only the head is walked.
    static func preview(of text: String, title: String) -> String {
        var text = EmotionMarkup.displayText(String(text.prefix(600)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(title) {
            // Only the separator after the title goes; trimming both ends
            // also ate a short preview's closing period.
            let separators = CharacterSet(charactersIn: " .—-")
            text = String(text.dropFirst(title.count)
                .drop { $0.unicodeScalars.allSatisfy(separators.contains) })
        }
        // Blank lines and paragraph breaks would open an empty gap in the card.
        return text.prefix(400).split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The series label unless the title already starts with it (titles like
    /// "Series A · 012 · …" would show it twice).
    var seriesLabelIfNotInTitle: String? {
        guard let label = seriesLabel else { return nil }
        return derivedTitle().hasPrefix(label) ? nil : label
    }

    /// Display title for the row. A user-set overlay title wins; otherwise
    /// the first sentence of the transcript, then a humanized archive name.
    func derivedTitle() -> String {
        if let t = overlay?.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !t.isEmpty {
            return t
        }
        if let sentence = Self.firstSentence(of: text ?? "") { return sentence }
        if let name = archiveName {
            return name
                .replacingOccurrences(of: #"\.[^.]+$"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"^voice-"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "-", with: " ")
                .replacingOccurrences(of: "_", with: " ")
        }
        return "(no title)"
    }

    /// Best on-disk path; uses the canonical voice-archive root when the
    /// recorded path is a stale host reference. The fallback recursive scan
    /// caches hits (one stat to re-check) and misses (no walk at all until
    /// the list reloads or `missRetryS` passes): view bodies call this
    /// several times per redraw, and a purged file would otherwise re-walk
    /// the whole archive tree on the main thread each time.
    func resolvedAudioURL() -> URL? {
        guard let name = archiveName else { return nil }
        if let raw = archivePath {
            let p = URL(fileURLWithPath: raw)
            if FileManager.default.isReadableFile(atPath: p.path) { return p }
        }
        return Self.archiveLookup(name: name, root: AppPaths.voiceArchive)
    }

    private static let lookupLock = NSLock()
    nonisolated(unsafe) private static var lookupCache: [String: URL] = [:]
    /// Names the last walk didn't find, keyed by root + name, with when.
    nonisolated(unsafe) private static var missCache: [String: Date] = [:]
    /// How long a miss is trusted before the tree is walked again, for a file
    /// put back by hand while nothing reloads the list.
    static let missRetryS: TimeInterval = 60

    /// Forget every cached miss: the list reloaded, so files may be back.
    static func forgetMissingAudio() {
        lookupLock.lock()
        missCache.removeAll()
        lookupLock.unlock()
    }

    /// A cached hit is re-checked on disk: a file moved to the Trash (or
    /// deleted by hand) is evicted and looked up again, not handed back.
    static func archiveLookup(name: String, root: URL, now: Date = Date()) -> URL? {
        let missKey = root.path + "\u{0}" + name
        lookupLock.lock()
        let cached = lookupCache[name]
        let missedAt = missCache[missKey]
        lookupLock.unlock()
        if cached == nil, let missedAt, now.timeIntervalSince(missedAt) < missRetryS {
            return nil
        }
        if let cached {
            if FileManager.default.isReadableFile(atPath: cached.path) { return cached }
            lookupLock.lock()
            if lookupCache[name] == cached { lookupCache[name] = nil }
            lookupLock.unlock()
        }
        let found = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap({ $0 as? URL })
            .first(where: { $0.lastPathComponent == name })
        lookupLock.lock()
        if let found {
            lookupCache[name] = found
            missCache[missKey] = nil
        } else {
            missCache[missKey] = now
        }
        lookupLock.unlock()
        return found
    }

    /// Prefer the duration reported by progress (real, set on first
    /// playback) over the JSONL value (`0` for entries rendered before
    /// the progress feature shipped).
    func bestDurationS() -> Double {
        if let p = progress, p.durationS > 0 { return p.durationS }
        return durationS
    }

    /// Return a copy of this entry with its progress field replaced.
    func withProgress(_ progress: ProgressInfo?) -> VoiceEntry {
        var copy = self; copy.progress = progress; return copy
    }

    /// Return a copy with overlay replaced.
    func withOverlay(_ overlay: Overlay?) -> VoiceEntry {
        var copy = self; copy.overlay = overlay; return copy
    }

    /// True when this is a save-and-stop draft that still has un-rendered text
    /// to continue: it carries the daemon "draft" tag AND a resume boundary
    /// that has NOT reached the end of the stored full text. Gates the
    /// "Continue render" button (POST /episode/resume). Reads the server tag
    /// directly — the daemon sets "draft" at render time.
    var isResumableDraft: Bool {
        (tags?.contains("draft") ?? false)
            && resumeFullText != nil
            && (resumeCharOffset ?? 0) < (resumeFullText?.count ?? 0)
    }

    /// For a resumable draft, the fraction of the FULL intended text that has
    /// been rendered to audio (`resumeCharOffset / resumeFullText.count`). The
    /// audio file holds only this rendered prefix, so a visualizer maps the
    /// existing audio onto `[0, draftRenderedFraction]` of the full-draft
    /// timeline and dims the un-rendered remainder (an amber frontier marks the
    /// boundary), making it clear how much of the draft is rendered. nil for a
    /// normal entry, or a degenerate offset (0 or ≥ the full length).
    var draftRenderedFraction: Double? {
        guard isResumableDraft,
              let full = resumeFullText, !full.isEmpty,
              let off = resumeCharOffset else { return nil }
        let f = Double(off) / Double(full.count)
        return (f > 0 && f < 1) ? f : nil
    }

    /// The draft↔audio coordinate map for this entry's scrubber. Single source
    /// for the delicate draft-prefix math the inline PlayerPanel and the
    /// full-screen reader both need (was copy-pasted verbatim in both).
    var draftSeekMap: DraftSeekMap { DraftSeekMap(draftFrac: draftRenderedFraction) }
}

/// Maps a resumable draft's full-draft-space positions onto its rendered-prefix
/// audio timeline and back. The draft's audio file holds only the rendered
/// prefix `[0, draftFrac]`, so the visualizer shows played head / bookmarks in
/// full-draft space and seeks must un-scale to the audio timeline. For a normal
/// entry (`draftFrac == nil`) every method is the identity — byte-identical to
/// the pre-extraction inline code.
struct DraftSeekMap {
    let draftFrac: Double?
    /// Played head: full-space fraction → audio fraction.
    func played(_ frac: Double) -> Double { draftFrac.map { frac * $0 } ?? frac }
    /// Bookmarks scaled into full-draft space (for display on the dimmed bar).
    func marks(_ bms: [Bookmark]) -> [Bookmark] {
        draftFrac.map { df in bms.map { Bookmark(id: $0.id, position: $0.position * df, note: $0.note) } } ?? bms
    }
    /// A bookmark's full-space position → audio position (for its timestamp).
    func audioPos(_ p: Double) -> Double { draftFrac.map { p / $0 } ?? p }
    /// A seek fraction, clamped to the rendered prefix, → audio fraction.
    func seekTarget(_ f: Double) -> Double { draftFrac.map { min(f, $0) / $0 } ?? f }
}
