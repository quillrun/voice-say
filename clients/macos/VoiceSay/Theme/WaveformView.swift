import SwiftUI

// MARK: - Pure layout / level math (nonisolated static — testable, zero-UI)

enum WaveformLayout {
    /// Number of bars for a given available pixel width. Dense pack:
    /// 2px bar + 1px gap = 3px per bar. Floor so we never exceed bounds.
    nonisolated static func barCount(forWidth width: CGFloat, barWidth: CGFloat = 2, gap: CGFloat = 1) -> Int {
        guard width > 0 else { return 0 }
        let stride = barWidth + gap
        return max(1, Int(width / stride))
    }

    /// Animated level multiplier for bar `i` given the playhead bar `played`
    /// and a time phase [0, 1). Bars within `radius` of the playhead pulse
    /// with a small sinusoidal jitter; bars outside the radius return 1.0.
    /// Pure function — no side effects, fully deterministic.
    nonisolated static func levelMultiplier(
        barIndex i: Int,
        playedBar played: Int,
        phase: Double,         // [0, 1) from TimelineView context
        radius: Int = 8,
        amplitude: Double = 0.18
    ) -> Double {
        let dist = abs(i - played)
        guard dist <= radius else { return 1.0 }
        // Cosine envelope tapers to zero at the radius boundary.
        let envelope = cos(Double(dist) / Double(radius) * .pi * 0.5)
        // Each bar has a slightly different phase offset so they don't all
        // move in lockstep — gives an organic "breathing" look.
        let offset = Double(i % 7) / 7.0
        let wave = sin((phase + offset) * .pi * 2)
        return 1.0 + amplitude * envelope * wave
    }

    /// Gate a TimelineView tick: returns true only when `isPlaying` is true.
    /// Extracted as a pure function so tests can verify the idle contract
    /// without spinning up a live TimelineView.
    nonisolated static func tickAllowed(isPlaying: Bool) -> Bool {
        isPlaying
    }
}

// MARK: - WaveformView

struct WaveformView: View {
    let audioURL: URL?
    let seed: String
    let playedFraction: Double
    var renderedFraction: Double? = nil
    var bookmarks: [Bookmark] = []
    var bookmarkHelp: ((Bookmark) -> String)? = nil
    var showBuffering: Bool = false
    var height: CGFloat = 44
    /// Live-playback flag — drives TimelineView animation and bar jitter.
    /// Defaulted off so static surfaces (previews, collapsed rows) are untouched.
    var isPlaying: Bool = false
    let onSeek: (Double) -> Void

    @State private var bars: [Double] = []
    // Window/scene activity — if the scene is not active, we skip animation
    // to avoid competing with TTS renders running in the background.
    @Environment(\.scenePhase) private var scenePhase

    // True when animation should fire: playing AND scene is active. The
    // playing gate goes through the tested pure function (WaveformLayout
    // .tickAllowed) so the production path IS the covered contract.
    private var shouldAnimate: Bool {
        WaveformLayout.tickAllowed(isPlaying: isPlaying) && scenePhase == .active
    }

    var body: some View {
        // TimelineView is paused when shouldAnimate is false (static bar grid,
        // zero CPU). The minimumInterval cap keeps the tick rate at ≤15 Hz.
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: !shouldAnimate)) { ctx in
            // Phase: fractional seconds mod 1 — drives per-bar level jitter.
            let phase = shouldAnimate
                ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.0)
                : 0.0
            waveformBody(phase: phase)
        }
        .task(id: audioURL?.path ?? seed) {
            bars = WaveformSynth.peaks(seed: seed, count: WaveformSynth.entryBarCount)
            guard let url = audioURL else { return }
            let real = await Task.detached(priority: .utility) {
                WaveformAnalyzer.envelope(url: url, count: WaveformSynth.entryBarCount)
            }.value
            if !Task.isCancelled, let real { bars = real }
        }
    }

    @ViewBuilder
    private func waveformBody(phase: Double) -> some View {
        let peaks = bars.isEmpty
            ? WaveformSynth.peaks(seed: seed, count: WaveformSynth.entryBarCount)
            : bars
        let playedBars  = Int(Double(peaks.count) * playedFraction)
        let level = peaks.isEmpty ? 0 : peaks[min(peaks.count - 1, max(0, playedBars))]

        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Dense bar grid — 2px bars, 1px gaps.
                let nBars = WaveformLayout.barCount(forWidth: geo.size.width)
                // Resample `peaks` (WaveformSynth.entryBarCount length) into nBars.
                let resampledPeaks = resample(peaks, to: nBars)
                let barW: CGFloat = 2
                let gap:  CGFloat = 1
                let stride = barW + gap

                HStack(spacing: gap) {
                    ForEach(0..<nBars, id: \.self) { i in
                        let playedBar = Int(Double(nBars) * playedFraction)
                        let renderedBar = renderedFraction.map { Int(Double(nBars) * $0) } ?? playedBar
                        // Animate bars near the playhead only while playing.
                        let mult = shouldAnimate
                            ? WaveformLayout.levelMultiplier(barIndex: i, playedBar: playedBar, phase: phase)
                            : 1.0
                        let rawH = barHeight(resampledPeaks[i], maxH: geo.size.height, mult: mult)
                        Capsule()
                            .fill(barColor(i, played: playedBar, rendered: renderedBar))
                            .frame(width: barW, height: rawH)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    }
                }
                .frame(width: CGFloat(nBars) * stride - gap, height: geo.size.height, alignment: .leading)

                // Bookmark markers
                ForEach(bookmarks) { bm in
                    BookmarkMarker()
                        .offset(x: geo.size.width * bm.position - 1)
                        .help(bookmarkHelp?(bm) ?? "")
                }

                // Rendered-but-not-played amber frontier line
                if let rf = renderedFraction, rf > playedFraction {
                    ZStack(alignment: .top) {
                        Rectangle().fill(Tokens.warn).frame(width: 2.5)
                        Circle().fill(Tokens.warn).frame(width: 7, height: 7).offset(y: -3)
                    }
                    .frame(width: 7)
                    .offset(x: geo.size.width * rf - 3.5)
                }

                // Playhead — solid while playing, level-modulated glow; dimmed when paused.
                Rectangle()
                    .fill(Tokens.accent.opacity(isPlaying ? 0.95 : 0.5))
                    .frame(width: 2)
                    .shadow(color: Tokens.accent.opacity(isPlaying ? 0.3 + 0.5 * level : 0),
                            radius: isPlaying ? 3 + 5 * level : 0)
                    .offset(x: geo.size.width * playedFraction - 1)

                if showBuffering {
                    HStack(spacing: Spacing.xs) {
                        ProgressView().controlSize(.small).tint(Tokens.accent)
                        Text("buffering…").font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.dim)
                    }
                    .offset(x: min(geo.size.width - 90, geo.size.width * playedFraction + 4), y: -16)
                }
            }
            // Glide the playhead between the player's ~4 Hz ticks while playing.
            .animation(isPlaying ? .linear(duration: 0.25) : nil, value: playedFraction)
            .contentShape(Rectangle())
            .onTapGesture { loc in onSeek(max(0, min(1, loc.x / geo.size.width))) }
        }
        .frame(height: height)
        // The scrubber is a bare tap-Rectangle — without these it never
        // enters the accessibility tree, so VoiceOver/Switch Control users
        // could not seek at all.
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int((playedFraction * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            switch direction {
            case .increment: onSeek(min(1, playedFraction + step))
            case .decrement: onSeek(max(0, playedFraction - step))
            @unknown default: break
            }
        }
    }

    // MARK: - Helpers

    private func barColor(_ i: Int, played: Int, rendered: Int) -> Color {
        if i < played  { return Tokens.accent }
        if i < rendered { return Tokens.accent.opacity(0.45) }
        return Tokens.borderStrong
    }

    private func barHeight(_ peak: Double, maxH: CGFloat, mult: Double) -> CGFloat {
        let base = max(4, maxH * peak)
        return min(maxH, base * mult)
    }

    /// Nearest-neighbour resample: map `src` array into exactly `count` slots.
    /// Used to project the fixed-size peaks array onto the dynamic bar count
    /// without distortion.
    private func resample(_ src: [Double], to count: Int) -> [Double] {
        guard count > 0 else { return [] }
        guard !src.isEmpty else { return Array(repeating: 0.5, count: count) }
        return (0..<count).map { i in
            let srcIdx = Int(Double(i) / Double(count) * Double(src.count))
            return src[min(src.count - 1, srcIdx)]
        }
    }
}
