// SamplePreviewPlayer — a tiny, self-contained AVAudioPlayer for the voice
// picker's per-voice sample preview. Deliberately separate from the shared
// AudioPlayer so a short preview never disturbs the main playback/streaming
// queue (macOS allows concurrent AVAudioPlayers; no shared audio session).
//
// Plays a FIXED per-voice clip from disk (VoiceMeta.sampleURL: the .app's
// bundled samples first, then <archive_root>/_samples/<voice>.mp3);
// `progress` drives the card's mini-waveform fill, `remainingS` the countdown.

import Foundation
import Observation
import AVFoundation

@MainActor
@Observable
final class SamplePreviewPlayer {
    var playingVoice: String? = nil
    var progress: Double = 0      // 0…1 of the sample clip
    var remainingS: Double = 0    // seconds left in the clip

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    func play(url: URL, voice: String) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.play()
        playingVoice = voice
        progress = 0
        remainingS = p.duration
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let pl = self.player else { return }
                self.progress = pl.duration > 0 ? pl.currentTime / pl.duration : 0
                self.remainingS = max(0, pl.duration - pl.currentTime)
                if !pl.isPlaying { self.stop() }
            }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        playingVoice = nil
        progress = 0
        remainingS = 0
    }
}
