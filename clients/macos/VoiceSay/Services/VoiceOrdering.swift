// VoiceOrdering — pure ordering helpers for the voice picker grid. Kept
// state-free and dependency-free so they're unit-testable in isolation
// (Tests/VoiceOrderingTests.swift) without standing up a HistoryStore or
// AudioPlayer. The picker (VoicePickerSheet) floats the now-playing /
// most-recently-played voice to the first card; the "which voice" and the
// "move it to front" decisions both live here.

enum VoiceOrdering {
    /// Return `voices` with `pin` moved to the front, preserving the order of
    /// the remaining elements. No-op when `pin` is nil, already first, or not
    /// present in the list (so a voice that doesn't belong to the open backend
    /// tab leaves that tab in catalog order).
    static func pinnedFirst(_ voices: [String], pin: String?) -> [String] {
        guard let pin, let idx = voices.firstIndex(of: pin), idx != 0 else { return voices }
        var out = voices
        out.remove(at: idx)
        out.insert(pin, at: 0)
        return out
    }

    /// The voice of the play event with the greatest `lastPlayed` timestamp.
    /// `lastPlayed` is the daemon's ISO-8601 `last_played` string, which sorts
    /// lexically — so a plain string `max` is correct. Entries missing a voice
    /// or a `lastPlayed` (rendered but never played) are ignored; returns nil
    /// when nothing has been played.
    static func mostRecentlyPlayedVoice(_ plays: [(voice: String?, lastPlayed: String?)]) -> String? {
        plays
            .compactMap { p -> (lastPlayed: String, voice: String)? in
                guard let v = p.voice, let lp = p.lastPlayed else { return nil }
                return (lp, v)
            }
            .max(by: { $0.lastPlayed < $1.lastPlayed })?
            .voice
    }
}
