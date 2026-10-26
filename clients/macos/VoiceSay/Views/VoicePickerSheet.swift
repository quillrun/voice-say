// VoicePickerSheet — interactive voice gallery. A centered scrim + card
// over the current screen: backend tabs (BackendSelector) over a 2-column
// grid of voice cards (tone-tinted avatar, label + id, descriptor, sample
// preview, selection check). Shared by the New-render screen and Settings.
//
// Sample preview plays a real per-voice clip (VoiceMeta.sampleURL: bundled
// into the .app by build-app.sh from VOICE_SAY_SAMPLES, else
// <archive_root>/_samples) through its own SamplePreviewPlayer, so it never
// disturbs the shared AudioPlayer. A voice without a clip shows "no clip".

import SwiftUI

struct VoicePickerSheet: View {
    enum Context { case compose, settings }

    @Binding var isPresented: Bool
    let context: Context
    let initialBackendID: String
    let initialVoiceID: String
    /// Called when the user commits (Done). The caller owns syncing the
    /// selection back into its own state (+ persisting, for Settings).
    let onPick: (_ backendID: String, _ voiceID: String) -> Void

    // Shared stores (injected at the WindowGroup root in App.swift) — read so
    // the now-playing / most-recently-played voice can float to the top card.
    @Environment(AudioPlayer.self) private var player
    @Environment(HistoryStore.self) private var store

    @State private var tabBackendID: String = ""
    @State private var selectedVoice: String = ""
    @State private var samplePlayer = SamplePreviewPlayer()
    /// Most-recently-played voice, snapshotted once when the sheet opens. The
    /// now-playing voice (player.activeEntry) is read live; this is the
    /// fallback used when no track is loaded, so a one-shot read is enough.
    @State private var recentVoice: String? = nil

    private let columns = [GridItem(.flexible(), spacing: Spacing.md),
                           GridItem(.flexible(), spacing: Spacing.md)]

    var body: some View {
        ZStack {
            Tokens.scrim
                .ignoresSafeArea()
                .onTapGesture { close() }
            sheet
        }
        .onAppear {
            tabBackendID = initialBackendID.isEmpty ? (Backends.all.first?.id ?? "") : initialBackendID
            selectedVoice = initialVoiceID
            recentVoice = store.lastPlayedVoice
        }
        .onDisappear { samplePlayer.stop() }
    }

    private var currentBackend: Backend? { Backends.find(id: tabBackendID) }
    private var voices: [String] { currentBackend?.voices ?? [] }

    /// The voice to float to the top of the CURRENT tab: the now-playing voice
    /// wins over the most-recently-played one, and only when that voice is part
    /// of this backend's catalog (otherwise the tab stays in catalog order).
    private var pinnedVoice: String? {
        for candidate in [player.activeEntry?.voice, recentVoice] {
            if let v = candidate, voices.contains(v) { return v }
        }
        return nil
    }

    /// Grid order: pinned voice first, the rest in catalog order.
    private var orderedVoices: [String] { VoiceOrdering.pinnedFirst(voices, pin: pinnedVoice) }

    /// True when `v` is the live now-playing voice (vs. merely the most
    /// recently played) — switches the pin badge between its two labels.
    private func isNowPlaying(_ v: String) -> Bool { player.activeEntry?.voice == v }

    private var sheet: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Tokens.border)
            BackendSelector(selectedID: $tabBackendID,
                            backends: Backends.all,
                            onSelect: { _ in samplePlayer.stop() })
                .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.md)
            Divider().background(Tokens.border)
            ScrollView {
                LazyVGrid(columns: columns, spacing: Spacing.md) {
                    ForEach(orderedVoices, id: \.self) { v in card(v) }
                }
                .padding(Spacing.lg)
            }
            Divider().background(Tokens.border)
            footer
        }
        .frame(width: 640)
        .frame(maxHeight: 560)
        .background(Tokens.bg2)
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).stroke(Tokens.borderStrong))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .shadow(color: .black.opacity(0.6), radius: 40, x: 0, y: 24)
    }

    private var header: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 15)).foregroundStyle(Tokens.accent)
                .frame(width: 30, height: 30).background(Tokens.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Choose a voice").font(.system(size: 14, weight: .bold))
                Text(context == .settings ? "sets the daemon default" : "applies to this render")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.dim)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.md)
    }

    private func card(_ v: String) -> some View {
        let meta = VoiceCatalog.meta(for: v)
        let selected = v == selectedVoice
        return Button(action: { selectedVoice = v }) {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    avatar(meta)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(meta.label).font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Tokens.text)
                            .lineLimit(1).truncationMode(.tail)
                        Text(v).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Tokens.ultraDim)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    if v == pinnedVoice { pinBadge(isNowPlaying(v)) }
                    selectionCheck(selected)
                }
                Text(meta.descriptor).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(2).truncationMode(.tail)
                preview(v, meta)
            }
            .padding(Spacing.md)
            .background(selected ? Tokens.accentSoft : Tokens.bg2.opacity(0.4))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(selected ? Tokens.accent : Tokens.borderStrong))
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func avatar(_ meta: VoiceMeta) -> some View {
        Circle()
            .fill(meta.tone.tint.opacity(0.18))
            .frame(width: 34, height: 34)
            .overlay(Circle().stroke(meta.tone.tint.opacity(0.6), lineWidth: 1))
            .overlay(
                Text(meta.label.prefix(1))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(meta.tone.tint)
            )
    }

    // Accent pill marking the card that floated to the top: "Now playing"
    // for the live track, "Recent" for the most-recently-played voice.
    // .fixedSize keeps the pill intact and lets the voice label truncate
    // instead, so the two-column card never clips the badge.
    private func pinBadge(_ live: Bool) -> some View {
        Text(live ? "Now playing" : "Recent")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Tokens.accent)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, Spacing.xxs)
            .background(Tokens.accentSoft)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Tokens.accent.opacity(0.4), lineWidth: 1))
            .fixedSize()
    }

    private func selectionCheck(_ on: Bool) -> some View {
        ZStack {
            Circle().fill(on ? Tokens.accent : Color.clear)
            Circle().stroke(on ? Color.clear : Tokens.borderStrong, lineWidth: 1)
            if on {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Tokens.bg)
            }
        }
        .frame(width: 20, height: 20)
    }

    private func preview(_ v: String, _ meta: VoiceMeta) -> some View {
        let playing = samplePlayer.playingVoice == v
        let hasSample = meta.sampleURL != nil
        let bars = WaveformSynth.peaks(seed: v, count: 28)
        let prog = playing ? samplePlayer.progress : 0
        let filled = Int(Double(bars.count) * prog)
        return HStack(spacing: Spacing.md) {
            Button(action: { togglePreview(v) }) {
                ZStack {
                    Circle().fill(playing || !hasSample ? Tokens.bg2 : Tokens.accent)
                        .overlay(Circle().stroke(playing || !hasSample ? Tokens.borderStrong : Color.clear, lineWidth: 1))
                        .frame(width: 30, height: 30)
                    Image(systemName: playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(playing ? Tokens.accent : (hasSample ? Tokens.bg : Tokens.ultraDim))
                }
            }
            .buttonStyle(.plain)
            .disabled(!hasSample)
            .help(hasSample ? "Play sample" : "No sample clip for this voice yet")
            GeometryReader { geo in
                HStack(spacing: Spacing.xxs) {
                    ForEach(0..<bars.count, id: \.self) { i in
                        Rectangle()
                            .fill(i < filled ? Tokens.accent : Tokens.borderStrong)
                            .frame(height: max(3, geo.size.height * bars[i]))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 26)
            .opacity(hasSample ? 1 : 0.4)
            Text(hasSample ? fmtDuration(Int((playing ? samplePlayer.remainingS : meta.sampleSeconds).rounded())) : "no clip")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.dim).frame(width: 40, alignment: .trailing)
        }
    }

    private var footer: some View {
        HStack(spacing: Spacing.md) {
            Text("\(voices.count) voices · \(displayBackendLabel)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.ultraDim)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            // Cancel beside Done (HIG sheets). Esc and a click on the scrim
            // also close without saving; the host screens drop their own Esc
            // (Back) while the picker is up, so Esc reaches this one.
            Button(action: close) {
                Text("Cancel").font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Tokens.muted)
                    .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.borderStrong))
                    .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            Button(action: commit) {
                Text("Done").font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .accentPill(horizontal: Spacing.lg, vertical: Spacing.sm)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.md)
    }

    private var displayBackendLabel: String {
        currentBackend?.compactLabel ?? ""
    }

    // Plays the FIXED per-voice sample clip — the same audio file every time,
    // at <archive_root>/_samples/<voice>.mp3 (produced out-of-band by the
    // samples track, NOT rendered on the spot). No-op for a voice whose clip
    // doesn't exist yet (its play button is disabled).
    private func togglePreview(_ v: String) {
        if samplePlayer.playingVoice == v { samplePlayer.stop(); return }
        guard let url = VoiceCatalog.meta(for: v).sampleURL else { return }
        samplePlayer.play(url: url, voice: v)
    }

    private func commit() {
        onPick(tabBackendID, Self.committedVoice(selected: selectedVoice, voices: voices,
                                                 defaultVoice: currentBackend?.defaultVoice ?? ""))
        close()
    }

    /// The voice Done saves for the tab's backend: the selection when it
    /// belongs to this backend, else the backend's default, else its first
    /// voice. Switching tabs keeps the old tab's selection, so saving it as is
    /// would pair a voice with a backend that doesn't have it.
    nonisolated static func committedVoice(selected: String, voices: [String], defaultVoice: String) -> String {
        if voices.contains(selected) { return selected }
        if !defaultVoice.isEmpty { return defaultVoice }
        return voices.first ?? ""
    }

    private func close() {
        samplePlayer.stop()
        withAnimation(Motion.quick) { isPresented = false }
    }
}
