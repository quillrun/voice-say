// StreamingEpisodeCard — the provisional "play while rendering" card.
// Shown at the top of the history list by ContentView while an episode is
// rendering and being played, before any canonical voice.db row exists.
// It binds to AudioPlayer's streaming published state (currentTime,
// renderHeadS, episodeTotalS, isBuffering, isPlaying) and the
// StreamingEpisode model. On episode_complete HistoryStore clears
// `streamingEpisode`, this card disappears, and the canonical row takes over.

import SwiftUI

struct StreamingEpisodeCard: View {
    @Environment(AudioPlayer.self) var player
    @Environment(HistoryStore.self) var store
    @Environment(UIRouter.self) var router
    var episode: StreamingEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            renderProgressBar
            // A render that isn't in the player (silent batch, another
            // client's): progress only; it plays from its row once it lands.
            if episode.armsPlayer {
                HStack(spacing: Spacing.md) {
                    StreamingPlayButton()
                    StreamingScrubber(episodeID: episode.id)
                    timeBlock
                }
            }
            // "read" sits bottom-RIGHT; the stop/delete controls are top-right.
            if !episode.fullText.isEmpty {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    readButton
                }
            }
        }
        .padding(Spacing.md)
        .background(Tokens.accent.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(Tokens.accent.opacity(0.35)))
    }


    // Identity on the left — WHAT is rendering, readable across the room —
    // the stop/delete controls (+ the "Finishing current chunk…" status) ride
    // the top-right. Live STATE is carried by the progress block and the
    // accent border, so no "STREAMING" eyebrow.
    private var header: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            StreamingEpisodeIdentity(episode: episode)
                .layoutPriority(-1)
            Spacer(minLength: Spacing.sm)
            StreamingRenderControls()
        }
    }

    // Read-along — opens the transcript reader (the live read/render/not-yet
    // 3-state view; the merged details+reader surface). Bottom-right
    // now, reused as the "Read Transcript" entry into that one surface.
    private var readButton: some View {
        Button(action: { router.open(.transcript(episode.id)) }) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "text.alignleft").font(.system(size: 11))
                Text("Read Transcript").font(.system(size: 11, design: .monospaced))
            }
            .fixedSize()
            .foregroundStyle(Tokens.accent)
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.accent.opacity(0.5)))
        }
        .buttonStyle(.plain).help("Read the transcript / read along while it renders — same surface as the details screen")
    }

    /// The card's single render-progress readout — HOW LONG until it is done.
    /// Before the first chunk: an honest indeterminate spinner + the live phase
    /// cycler (Preparing… / Warming up the voice… / Rendering the first chunk…).
    /// Once chunks land: a determinate bar (StreamingEpisode.
    /// renderFractionByChunks — the accurate, type-agnostic signal) over one
    /// line of facts (StreamingProgressFacts). The scrubber's amber render-head
    /// is the separate "how much is playable" axis.
    private var renderProgressBar: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            if episode.isPreparing {
                ProgressView().controlSize(.small).tint(Tokens.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StreamStatusLabel(episode: episode, isFinalizing: store.finalizing, isForcingStop: store.forcingStop,
                                  font: .system(size: 11, design: .monospaced),
                                  color: Tokens.dim)
            } else {
                ProgressView(value: episode.renderFractionByChunks).tint(Tokens.accent)
                StreamingProgressFacts(episode: episode,
                                       showsRemaining: !store.finalizing && !store.forcingStop)
            }
        }
    }

    // Elapsed / total playback only (shared TimeReadout). The "playable
    // frontier" % moved out — the scrubber's amber render-head marker already
    // shows how much is buffered, so the number was a duplicate of a visible cue.
    private var timeBlock: some View {
        TimeReadout(current: Int(player.currentTime), total: Int(player.episodeTotalS))
    }

}

/// The card's identity block: the title (the set one, else the text's first
/// sentence, dimmed so it doesn't pass for a real title) over one dim
/// monospaced meta line — series · episode · voice · backend · chars · source.
struct StreamingEpisodeIdentity: View {
    var episode: StreamingEpisode

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(episode.displayTitle)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(episode.hasTitle ? Tokens.text : Tokens.dim)
                .lineLimit(1).truncationMode(.tail)
                .help(episode.displayTitle)
            Text(episode.identityMetaLine)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.dim)
                .lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The line under the determinate bar: "chunk K of N · 12:40 rendered" on the
/// left, "elapsed m:ss · about m:ss left" on the right, the estimate in accent
/// (it answers "do I wait?"). Ticks once a second for the clock facts; the
/// pace maths lives on StreamingEpisode. `showsRemaining` is off while a
/// Pause/Stop Now is winding the render down — the estimate no longer applies.
struct StreamingProgressFacts: View {
    var episode: StreamingEpisode
    var showsRemaining: Bool = true

    var body: some View {
        TimelineView(.periodic(from: episode.startedAt, by: 1)) { ctx in
            HStack(spacing: Spacing.xs) {
                fact("\(episode.chunkCountLabel) · \(episode.renderedLabel)", color: Tokens.dim)
                    .layoutPriority(-1)
                Spacer(minLength: Spacing.sm)
                fact(episode.elapsedLabel(at: ctx.date), color: Tokens.dim)
                if showsRemaining {
                    fact("·", color: Tokens.dim)
                    fact(episode.remainingLabel(at: ctx.date), color: Tokens.accent, weight: .semibold)
                }
            }
        }
    }

    private func fact(_ s: String, color: Color, weight: Font.Weight = .regular) -> some View {
        Text(s)
            .font(.system(size: 11, weight: weight, design: .monospaced))
            .foregroundStyle(color)
            .lineLimit(1).truncationMode(.tail)
    }
}

/// The live render's stop controls — shared by the streaming card's header
/// (top-right) AND the live-render reader (so the reader carries controls too,
/// #7). While rendering: Pause (finish the current chunk → resumable draft) +
/// Delete. While that chunk finishes (finalizing): "Finishing current chunk…" +
/// Stop Now (drop the in-flight chunk, keep what's done) + Delete. Content-
/// hugging (no leading Spacer) so it sits flush wherever it's placed. Acts on
/// the single active streaming episode via HistoryStore, so it needs no episode
/// parameter.
struct StreamingRenderControls: View {
    @Environment(HistoryStore.self) var store

    var body: some View {
        HStack(spacing: Spacing.sm) {
            if store.finalizing && !store.forcingStop {
                ProgressView().controlSize(.small).tint(Tokens.warn)
                Text("Finishing current chunk…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.warn)
                    .fixedSize()
            }
            if store.forcingStop {
                Text("stopping…").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.dim).fixedSize()
            } else if store.finalizing {
                stopNowButton
                deleteButton
            } else {
                pauseButton
                deleteButton
            }
        }
    }

    private var pauseButton: some View {
        Button(action: { store.finalizeEpisode() }) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "pause.fill").font(.system(size: 11))
                Text("Pause").font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Tokens.accent)
            .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs)
            .background(Tokens.accent.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.accent.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .help("Pause — finish the current chunk, then keep what's rendered as a resumable draft")
    }

    private var stopNowButton: some View {
        Button(action: { store.forceFinalizeEpisode() }) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "stop.fill").font(.system(size: 11))
                Text("Stop Now").font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Tokens.warn)
            .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs)
            .background(Tokens.warn.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.warn.opacity(0.6)))
        }
        .buttonStyle(.plain)
        .help("Stop now — skip the chunk being rendered and keep what's already done")
    }

    private var deleteButton: some View {
        ArmedDeleteControl(onDelete: { store.cancelEpisode() },
                           help: "Delete — cancel this render, keep nothing",
                           label: "Delete")
    }
}

/// The live-render seekable scrubber — shared by the streaming card and the
/// reader's control bar so the played/render fractions and the seek-clamp (never
/// past the render head) live in ONE place. Denominator is the explicit episode
/// total (predicted, then snapped on episode_complete) — never the player's
/// duration, which only covers the chunks rendered so far.
struct StreamingScrubber: View {
    @Environment(AudioPlayer.self) var player
    let episodeID: String

    var body: some View {
        let total = max(player.episodeTotalS, 0.001)
        let renderFraction = min(1, max(0, player.renderHeadS / total))
        WaveformView(
            audioURL: nil,
            seed: episodeID,
            playedFraction: min(1, max(0, player.currentTime / total)),
            renderedFraction: renderFraction,
            isPlaying: player.isPlaying,
            onSeek: { f in player.seek(toFraction: min(f, renderFraction)) }
        )
    }
}

/// The live-render status line — the phase-aware replacement for a static
/// "Rendering…". Wraps a TimelineView so the pre-first-chunk steps advance on
/// the clock; once chunks land it shows "chunk K of N", then "Finishing up…".
/// Pulls its text from `StreamingEpisode.statusLabel` so the streaming card and
/// the transcript header always agree (one source of truth). Shared by both.
struct StreamStatusLabel: View {
    var episode: StreamingEpisode
    let isFinalizing: Bool
    var isForcingStop: Bool = false
    var font: Font = .system(size: 14, weight: .bold)
    var color: Color = Tokens.text

    var body: some View {
        // The periodic clock is only needed for the pre-first-chunk cycler.
        // Once a chunk lands (or we're finalizing) the label is chunk/flag-driven
        // and statusLabel ignores `date`, so drop the timer and let the
        // @ObservedObject refresh it — no 2.4s wake-ups for the whole render.
        if episode.chunks.isEmpty && !isFinalizing && !isForcingStop {
            TimelineView(.periodic(from: episode.startedAt, by: StreamingEpisode.prepStepInterval)) { ctx in
                labelText(episode.statusLabel(at: ctx.date, isFinalizing: isFinalizing, isForcingStop: isForcingStop))
            }
        } else {
            labelText(episode.statusLabel(at: episode.startedAt, isFinalizing: isFinalizing, isForcingStop: isForcingStop))
        }
    }

    @ViewBuilder private func labelText(_ s: String) -> some View {
        Text(s)
            .font(font)
            .foregroundStyle(color)
            .contentTransition(.opacity)
            .animation(Motion.standard, value: s)
    }
}

/// The streaming play/pause control shared by the streaming card + the reader
/// header: a buffering spinner until the buffer lead is met, then a play/pause
/// glyph; disabled (with an explanatory tooltip) while buffering or finalizing.
/// Env-driven (AudioPlayer + HistoryStore.finalizing) so both surfaces agree;
/// only the size + the ready-state tooltip phrase vary.
struct StreamingPlayButton: View {
    @Environment(AudioPlayer.self) var player
    @Environment(HistoryStore.self) var store
    var diameter: CGFloat = 38
    var glyphSize: CGFloat = 13
    var readyHelp: String = "Streaming — play/pause"

    private var canPlay: Bool { player.streamPlayable }   // single source on AudioPlayer

    var body: some View {
        Button(action: { player.togglePlay() }) {
            ZStack {
                Circle().fill(Tokens.accent).frame(width: diameter, height: diameter)
                if player.isBuffering && !player.isPlaying {
                    ProgressView().controlSize(.small).tint(Tokens.bg)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: glyphSize)).foregroundStyle(Tokens.bg)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!canPlay || store.finalizing)
        .opacity(canPlay && !store.finalizing ? 1.0 : 0.4)
        .help(store.finalizing ? "Wrapping up — finishing current chunk…"
              : (canPlay ? readyHelp : "Buffering — waiting for audio…"))
    }
}

// Mock every render phase without a daemon, audio, or SSE — including the
// multi-chunk "Rendering chunk K of N" a 1-chunk live render can never show.
// Chunks land 40 s apart, the last one 10 s ago, so the ETA line has a pace.
// Eyeball these in the Xcode canvas before reaching for a real render.
@MainActor
private func mockStreamingEpisode(total: Int, rendered: Int, titled: Bool = true) -> StreamingEpisode {
    let text = "The attention mechanism, from scratch. We start with a single query and a handful of keys."
    let ep = StreamingEpisode(id: "preview", predictedTotalS: 90, totalChunks: total,
                              chars: 16_472, backend: "qwen3", voice: "af_alloy", fullText: text,
                              title: titled ? "Attention from Scratch" : nil,
                              series: titled ? "Series A" : nil,
                              episodeNumber: titled ? 181 : nil)
    if rendered > 0 {
        let now = Date()
        for i in 1...rendered {
            ep.chunks.append(StreamChunk(seq: i, path: "/tmp/\(i).mp3", durationS: 95, cumulativeChars: i * 100,
                                         landedAt: now.addingTimeInterval(-10 - Double(rendered - i) * 40)))
        }
        ep.renderHeadS = Double(rendered) * 95
    }
    return ep
}

#Preview("Stream status — every phase") {
    VStack(alignment: .leading, spacing: 18) {
        StreamStatusLabel(episode: mockStreamingEpisode(total: 8, rendered: 0), isFinalizing: false)  // Preparing… (cycles)
        StreamStatusLabel(episode: mockStreamingEpisode(total: 8, rendered: 3), isFinalizing: false)  // Rendering chunk 4 of 8…
        StreamStatusLabel(episode: mockStreamingEpisode(total: 8, rendered: 8), isFinalizing: false)  // Finishing up…
        StreamStatusLabel(episode: mockStreamingEpisode(total: 8, rendered: 3), isFinalizing: true)   // Finishing current chunk…
    }
    .padding(24)
    .frame(width: 360, alignment: .leading)
    .background(Tokens.bg)
}

#Preview("Identity + progress facts") {
    VStack(alignment: .leading, spacing: 18) {
        StreamingEpisodeIdentity(episode: mockStreamingEpisode(total: 12, rendered: 3))                // titled, in a series
        StreamingEpisodeIdentity(episode: mockStreamingEpisode(total: 12, rendered: 3, titled: false)) // first-sentence fallback, dimmed
        StreamingProgressFacts(episode: mockStreamingEpisode(total: 12, rendered: 1))                  // estimating…
        StreamingProgressFacts(episode: mockStreamingEpisode(total: 12, rendered: 5))                  // about m:ss left
        StreamingProgressFacts(episode: mockStreamingEpisode(total: 12, rendered: 12))                 // finishing up…
    }
    .padding(24)
    .frame(width: 520, alignment: .leading)
    .background(Tokens.bg)
}
