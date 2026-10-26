// HeaderView — sticky top chrome: brand, daemon pill, compose/settings
// toggles, stats strip, speed control, header popovers (bookmarks +
// starred). Extracted from ContentView.swift.

import SwiftUI
import AppKit

struct HeaderView: View {
    @Environment(HistoryStore.self) var store
    @Environment(AudioPlayer.self) var player
    // Routes the render / gear / daemon-pill actions to full-window screens.
    @Environment(UIRouter.self) var router
    // Shared liveness authority — the pill polls /health through it (10 s,
    // only while the header is visible) so SSE's half-open-socket lie is
    // cross-checked. See HealthMonitor.
    @Environment(HealthMonitor.self) var health

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Library totals live in Settings → LIBRARY: not
            // needed while listening, and they took the top 130 pt. At narrow
            // widths the compact row drops the brand title and the speed label
            // so the row never clips (window minimum 760 pt).
            ViewThatFits(in: .horizontal) {
                headerRow(compact: false)
                headerRow(compact: true)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.md)
    }

    private func headerRow(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: compact ? Spacing.md : Spacing.lg) {
            sidebarToggle
            brand(compact: compact)
            daemonPill
            Spacer(minLength: 0)
            speedControl(compact: compact)
            sleepMenu
            composeToggle
            settingsToggle
        }
    }

    private var sidebarToggle: some View {
        Button(action: { NotificationCenter.default.post(name: .toggleSidebar, object: nil) }) {
            Image(systemName: "sidebar.left").font(.system(size: 13))
                .foregroundStyle(Tokens.muted)
        }
        .buttonStyle(.plain)
        .help("Show or hide the sidebar (⌥⌘S)")
        // Symbol names read as "split view"; say what the button does
        // (hig/voiceover.md › Descriptions).
        .accessibilityLabel(router.sidebarShown ? "Hide sidebar" : "Show sidebar")
    }

    private func openSettings() {
        router.open(.settings)
    }

    /// Live daemon status pill — AND of SSE connection state and a
    /// periodic /health probe. SSE alone can stay "connected" on a
    /// half-open TCP socket after daemon death; /health alone misses
    /// the case where the daemon is up but the stream wedged. Both
    /// have to agree for green. Click opens Settings.
    private var daemonUp: Bool { store.streamConnected && health.healthOK }

    private var daemonPill: some View {
        Button(action: openSettings) {
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(daemonUp ? Tokens.add : Tokens.del)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(
                        (daemonUp ? Tokens.add : Tokens.del).opacity(0.35),
                        lineWidth: 2))
                Text(daemonUp ? "daemon up" : "daemon down")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(daemonUp ? Tokens.add : Tokens.del)
            }
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
            .background((daemonUp ? Tokens.add : Tokens.del).opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(
                (daemonUp ? Tokens.add : Tokens.del).opacity(0.4)))
        }
        .buttonStyle(.plain)
        .help(daemonUp
              ? "voice-say daemon up — click for start/stop/restart"
              : "voice-say daemon down — click to start")
        .onAppear { health.startPillPolling() }
        .onDisappear { health.stopPillPolling() }
    }

    private func brand(compact: Bool) -> some View {
        HStack(spacing: Spacing.md) {
            // App icon (built into the bundle's
            // AppIcon.icns by build-app.sh; loaded at runtime by its system name).
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 48, height: 48)   // +50% (was 32)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            // No app-drawn border — the icon artwork already carries its own
            // accent frame; a second SwiftUI stroke double-bordered it.
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                if !compact { Text("Voice Say").font(.system(size: 15, weight: .bold)) }
                if !store.query.isEmpty {
                    Text("\(store.filtered.count.formatted()) match\(store.filtered.count == 1 ? "" : "es")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.accent)
                }
            }
        }
    }

    private var composeToggle: some View {
        // Opens the full-screen New-render flow (presented by ContentView as
        // a slide-from-top overlay via the router).
        Button(action: { router.open(.compose) }) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "plus.circle.fill").font(.system(size: 15))
                Text("render").font(.system(size: 13, weight: .bold, design: .monospaced))
            }
            // Primary action — enlarged + filled accent so it reads as the main CTA.
            .foregroundStyle(Tokens.bg)
            .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
            .background(Tokens.accent, in: RoundedRectangle(cornerRadius: Radius.sm))
            .shadow(color: Tokens.accent.opacity(0.3), radius: 5, y: 1)
        }
        .buttonStyle(.plain)
        .help("New render")
    }

    private var settingsToggle: some View {
        // Opens the full-window SettingsScreen (presented by ContentView as a
        // slide-from-top overlay); the daemonPill drives the same binding.
        Button(action: openSettings) {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.sm)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.borderStrong))
                .foregroundStyle(Tokens.muted)
        }
        .buttonStyle(.plain)
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
    }

    /// Sleep timer (AudioPlayer.setSleepTimer): moon icon, minutes left
    /// while one runs.
    private var sleepMenu: some View {
        let on = player.sleepTimer != nil
        return Menu {
            ForEach([15, 30, 45, 60], id: \.self) { m in
                Button("\(m) minutes") { player.setSleepTimer(.minutes(m)) }
            }
            Button("End of episode") { player.setSleepTimer(.endOfEpisode) }
            if on {
                Divider()
                Button("Off") { player.setSleepTimer(nil) }
            }
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: on ? "moon.fill" : "moon")
                if let label = sleepLabel { Text(label).font(.system(size: 11, design: .monospaced)) }
            }
            .foregroundStyle(on ? Tokens.accent : Tokens.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sleep timer")
        .accessibilityLabel("Sleep timer")
        .accessibilityValue(sleepLabel.map { $0 == "end" ? "end of episode" : "\($0) left" } ?? "off")
    }

    /// "23m" while a timed sleep runs (refreshed by the player's tick),
    /// "end" for end-of-episode; nil when off.
    private var sleepLabel: String? {
        switch player.sleepTimer {
        case .none: return nil
        case .endOfEpisode: return "end"
        case .minutes:
            let left = (player.sleepRemaining ?? 0) + 59
            return "\(max(0, Int(left / 60)))m"
        }
    }

    private func speedControl(compact: Bool) -> some View {
        let atMin = player.playbackRate <= AudioPlayer.speedStops.first!
        let atMax = player.playbackRate >= AudioPlayer.speedStops.last!
        return HStack(spacing: 0) {
            if !compact {
                Text("Playback Speed")
                    .font(.system(size: 11, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(Tokens.ultraDim)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Spacing.md)

                Rectangle().fill(Tokens.borderStrong).frame(width: 1, height: 22)
            }

            Button(action: { player.bumpSpeed(-1) }) {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(atMin ? Tokens.ultraDim : Tokens.text)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(atMin)
            .accessibilityLabel("Decrease playback speed")

            Rectangle().fill(Tokens.borderStrong).frame(width: 1, height: 22)

            Button(action: { player.resetSpeed() }) {
                Text(fmtSpeed(player.playbackRate))
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(player.playbackRate == 1.0 ? Tokens.muted : Tokens.accent)
                    .frame(minWidth: 56, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click to reset to 1×")
            .accessibilityLabel("Reset playback speed")
            .accessibilityValue(fmtSpeed(player.playbackRate))

            Rectangle().fill(Tokens.borderStrong).frame(width: 1, height: 22)

            Button(action: { player.bumpSpeed(+1) }) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(atMax ? Tokens.ultraDim : Tokens.text)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(atMax)
            .accessibilityLabel("Increase playback speed")
        }
        .frame(height: 28)
        .background(Tokens.bg2)
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.borderStrong))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        // Win the compression contest at narrow widths: the 24pt stat
        // cells must yield horizontal space to the speed control before
        // it ever has to compress (and truncate "SPEED" → "SP E…").
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
        // Rate is threaded through BOTH players now (applyRate touches the
        // streaming queue player too), so the control stays live during a
        // render. At >1× the stream can outrun the render head — the existing
        // buffering path covers the underrun.
        .help("Playback speed (0.5–2.5×)")
    }

}
