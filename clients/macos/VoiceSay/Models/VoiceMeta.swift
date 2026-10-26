// VoiceMeta — per-voice presentation metadata for the interactive voice
// picker. The daemon's /config exposes only voice *ids* per backend
// (Backend.voices: [String]); it has no human label, descriptor, gender
// tint, or sample. This file supplies that presentation layer:
//   • a curated catalog for known voices, keyed by voice id, and
//   • a graceful derivation for unknown ids (tone from the af_/am_/bf_/bm_
//     prefix convention, a humanized label, a neutral descriptor).
//
// Sample audio: per-voice preview clips are BUNDLED in the .app at
// Contents/Resources/samples/<voice>.mp3 (copied in by build-app.sh from the
// VOICE_SAY_SAMPLES directory). `sampleURL` returns the bundled clip, falling
// back to an archive copy; the picker hides the preview when neither exists.

import Foundation

enum VoiceTone {
    case female, male, neutral
    // Avatar tint lives in Theme/Tokens.swift (`VoiceTone.tint`) — models
    // stay free of SwiftUI presentation types.
}

struct VoiceMeta {
    let id: String
    let label: String
    let descriptor: String       // two-word descriptor, e.g. "deep · steady"
    let tone: VoiceTone
    // Nominal per-voice clip length shown next to the preview bars in the
    // picker (VoicePickerSheet). It is a hand-set placeholder, NOT the measured
    // duration of sampleURL's audio — while a clip is actually playing the UI
    // shows samplePlayer.remainingS (the real countdown) instead.
    let sampleSeconds: Double

    /// A real per-voice preview clip, if one exists. Prefers the copy
    /// BUNDLED inside the .app (Contents/Resources/samples/<voice>.mp3), which
    /// nothing outside the build can change. Falls back to an archive copy
    /// (<archive_root>/_samples/<voice>.mp3) for any voice not bundled. nil
    /// when neither exists (the picker card then has no preview).
    var sampleURL: URL? {
        if let bundled = Bundle.main.url(
            forResource: id, withExtension: "mp3", subdirectory: "samples") {
            return bundled
        }
        let legacy = AppPaths.voiceArchive
            .appendingPathComponent("_samples")
            .appendingPathComponent("\(id).mp3")
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }
}

enum VoiceCatalog {
    /// Curated entries. Keys are real voice ids (Kokoro's, plus the speaker
    /// names of two other TTS models a catalog may add); unknown ids derive
    /// sensible defaults below. (label,
    /// descriptor, tone, sampleSeconds)
    private static let curated: [String: (String, String, VoiceTone, Double)] = [
        // kokoro — American English female (af_)
        "af_alloy":   ("Alloy",   "neutral · warm",        .female, 4),
        "af_aoede":   ("Aoede",   "lyrical · bright",      .female, 6),
        "af_bella":   ("Bella",   "bright · expressive",   .female, 5),
        "af_heart":   ("Heart",   "warm · friendly",       .female, 6),
        "af_jessica": ("Jessica", "clear · poised",        .female, 6),
        "af_kore":    ("Kore",    "calm · measured",       .female, 6),
        "af_nicole":  ("Nicole",  "soft · intimate",       .female, 4),
        "af_nova":    ("Nova",    "smooth · narration",    .female, 6),
        "af_river":   ("River",   "easy · conversational", .female, 6),
        "af_sarah":   ("Sarah",   "natural · everyday",    .female, 6),
        "af_sky":     ("Sky",     "light · airy",          .female, 6),
        // kokoro — American English male (am_)
        "am_adam":    ("Adam",    "deep · steady",         .male,   5),
        "am_echo":    ("Echo",    "even · neutral",        .male,   6),
        "am_eric":    ("Eric",    "crisp · upbeat",        .male,   6),
        "am_fenrir":  ("Fenrir",  "deep · resonant",       .male,   6),
        "am_liam":    ("Liam",    "easy · youthful",       .male,   6),
        "am_michael": ("Michael", "clear · narration",     .male,   6),
        "am_onyx":    ("Onyx",    "rich · cinematic",      .male,   6),
        "am_puck":    ("Puck",    "playful · bright",      .male,   6),
        "am_santa":   ("Santa",   "jolly · warm",          .male,   6),
        "bf_emma":    ("Emma",    "British · crisp",       .female, 4),
        // Qwen3-TTS CustomVoice speakers (English only)
        "Aiden":  ("Aiden",  "warm · conversational", .male,   4),
        "Ryan":   ("Ryan",   "deep · steady",         .male,   7),
        "Serena": ("Serena", "calm · poised",         .female, 5),
        "Vivian": ("Vivian", "bright · expressive",   .female, 6),
        // ElevenLabs voice names
        "rachel": ("Rachel", "natural · narration", .female, 5),
        "adam":   ("Adam",   "deep · cinematic",    .male,   6),
        "bella":  ("Bella",  "soft · friendly",     .female, 4),
        "antoni": ("Antoni", "warm · storytelling", .male,   5),
        // generic
        "default": ("Default", "balanced · neutral", .neutral, 4),
    ]

    static func meta(for id: String) -> VoiceMeta {
        if let c = curated[id] {
            return VoiceMeta(id: id, label: c.0, descriptor: c.1, tone: c.2, sampleSeconds: c.3)
        }
        return VoiceMeta(id: id, label: humanize(id), descriptor: "voice",
                         tone: derivedTone(id), sampleSeconds: 4)
    }

    /// Tone from the kokoro-style id prefix convention: af_/bf_ = female,
    /// am_/bm_ = male; anything else neutral.
    private static func derivedTone(_ id: String) -> VoiceTone {
        let l = id.lowercased()
        if l.hasPrefix("af_") || l.hasPrefix("bf_") { return .female }
        if l.hasPrefix("am_") || l.hasPrefix("bm_") { return .male }
        return .neutral
    }

    /// "am_michael" → "Michael", "af_heart" → "Heart", "freya" → "Freya".
    private static func humanize(_ id: String) -> String {
        var s = id
        for p in ["af_", "am_", "bf_", "bm_"] where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count)); break
        }
        s = s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return s.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

extension VoiceEntry {
    /// Spoken pace in words-per-minute, from the words/duration the daemon
    /// stored. 0 when duration is unknown.
    var wordsPerMinute: Int {
        let d = bestDurationS()
        guard d > 0, words > 0 else { return 0 }
        return Int((Double(words) / (d / 60.0)).rounded())
    }

    /// Silent reading time in seconds (≈230 wpm) — the transcript reader's
    /// "read time" stat tile. The design uses words / 230 * 60.
    var readSeconds: Double { Self.readSeconds(words: words) }

    /// Word-count → silent-read seconds (the single 230-wpm formula). Static so
    /// the live/queued READ TIME tile (no VoiceEntry yet) shares the exact basis.
    static func readSeconds(words: Int) -> Double { Double(words) / 230.0 * 60.0 }
}
