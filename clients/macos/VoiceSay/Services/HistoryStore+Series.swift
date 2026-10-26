// HistoryStore+Series — what plays next and what to resume: auto-advance to
// the next episode of a series, and the sidebar's Continue entry.

import Foundation

extension HistoryStore {
    /// UserDefaults key for auto-advance (Settings toggle). Absent = on.
    nonisolated static let autoAdvanceKey = "autoAdvanceSeries"

    var autoAdvanceSeries: Bool {
        UserDefaults.standard.object(forKey: Self.autoAdvanceKey) as? Bool ?? true
    }

    /// The next playable episode after `e` in its series (episode order), or
    /// nil when `e` is in no series, is the last, or the rest have no audio.
    func nextInSeries(after e: VoiceEntry) -> VoiceEntry? {
        guard let name = e.overlay?.series?.lowercased(), !name.isEmpty else { return nil }
        let episodes = entries
            .filter { !deletedKeys.contains(tagKey(for: $0)) && isComplete($0)
                      && $0.overlay?.series?.lowercased() == name }
            .sorted(by: Self.seriesOrder)
        return Self.next(after: e.id, in: episodes) { $0.resolvedAudioURL() != nil }
    }

    /// Pure core of nextInSeries: the first playable entry after `id`.
    nonisolated static func next(after id: String, in ordered: [VoiceEntry],
                                 playable: (VoiceEntry) -> Bool) -> VoiceEntry? {
        guard let i = ordered.firstIndex(where: { $0.id == id }) else { return nil }
        return ordered[(i + 1)...].first(where: playable)
    }

    /// Auto-advance: play the next episode and, if the reader was open on the
    /// one that ended, move the reader along with it.
    func playNextInSeries(after e: VoiceEntry) {
        guard autoAdvanceSeries, let next = nextInSeries(after: e) else { return }
        audioPlayer?.play(next)
        if router?.screen == .transcript(e.id) { router?.open(.transcript(next.id)) }
    }

    /// Continue listening: the most recently played entry that was started
    /// but not finished (nil when there is none).
    var continueEntry: VoiceEntry? {
        Self.continueCandidate(entries.filter { !deletedKeys.contains(tagKey(for: $0)) && isComplete($0) })
    }

    nonisolated static func continueCandidate(_ es: [VoiceEntry]) -> VoiceEntry? {
        es.filter { e in
            guard let p = e.progress, !p.completed, p.playedS > 1, p.lastPlayed != nil else { return false }
            return true
        }
        .max { ($0.progress?.lastPlayed ?? "") < ($1.progress?.lastPlayed ?? "") }
    }
}
