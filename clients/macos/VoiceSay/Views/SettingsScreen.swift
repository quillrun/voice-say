// SettingsScreen — full-window settings surface (not a dialog/sheet). It is
// presented by ContentView as a top-layer overlay that slides in from the
// top edge; dismissed via the Back button, Esc, or a downward swipe on the
// header. Slides back up on dismiss.
//
// "Services" probes the daemon /health and each TTS backend's port to surface
// which are live, with per-backend Start/Stop. "Configuration" exposes the
// writable defaults (say-threshold, default backend/voice via POST /config).
// "Library" shows what the library holds now beside the all-time GET /stats
// totals (that row hidden when the daemon lacks the route).

import SwiftUI

/// The Settings-family section heading ("SERVICES", "CONFIGURATION", …) —
/// one recipe shared by the shell and SettingsServicesPanel (the P3d split
/// briefly duplicated it). The Taxonomy surfaces' count-carrying variants
/// are a different recipe, deliberately not this.
func sectionLabel(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11, weight: .bold, design: .monospaced))
        .kerning(0.8)
        .foregroundStyle(Tokens.accent)
}

struct SettingsScreen: View {
    @AppStorage(HistoryStore.autoAdvanceKey) private var autoAdvance = true
    // Routed dismissal (Back / Esc / swipe → router.closeToList()).
    @Environment(UIRouter.self) var router
    @Environment(HistoryStore.self) var store
    // Liveness (app-level HealthMonitor): the CONFIGURATION backend selector
    // shows an offline dot for down backends.
    @Environment(HealthMonitor.self) var probe
    // Observed so the CONFIGURATION panel reflects daemon /config in
    // real time rather than lying with hardcoded literals.
    private let cfg = AppConfig.shared

    // Default backend/voice picker selections. Seeded from cfg on appear and
    // written back to the daemon (POST /config) explicitly via onSelect /
    // onPick — no .onChange persisters, so seeding can't clobber the saved
    // default_voice (e.g. a cloned voice). "" voice = clear.
    @State private var pickBackend: String = ""
    @State private var pickVoice: String = ""
    @State private var defaultsStatus: String? = nil
    /// Drives the interactive voice picker sheet overlay.
    @State private var showVoicePicker = false
    /// Editable say-threshold. Seeded from cfg.sayThresholdChars in seedPickers()
    /// (the 0 placeholder is never authoritative — it's overwritten before the
    /// field is shown). Committed to the daemon (POST /config) on stepper change
    /// / field submit. nil status = no pending message.
    @State private var thresholdInput: Int = 0
    @State private var thresholdStatus: String? = nil
    /// GET /stats; nil (section hidden) until loaded or when the daemon
    /// lacks the route.
    @State private var stats: StatsResponse? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            Divider().background(Tokens.border)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    KeyboardShortcutsRow()
                    Divider().background(Tokens.border)
                    SettingsServicesPanel()
                    Divider().background(Tokens.border)
                    configSection
                    Divider().background(Tokens.border)
                    librarySection
                }
                // Full-screen content: no width cap — sections span the
                // window (minus the screen padding), instead of a 620pt
                // centered strip that read as a dialog on large displays.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(Spacing.xl)
        // Full-window screen, not a fixed-size dialog.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Tokens.bg)
        .foregroundStyle(Tokens.text)
        .font(.system(.body, design: .monospaced))
        // Under the picker the form is out of VoiceOver's reach.
        .accessibilityHidden(showVoicePicker)
        .overlay {
            if showVoicePicker {
                VoicePickerSheet(isPresented: $showVoicePicker, context: .settings,
                                 initialBackendID: pickBackend, initialVoiceID: pickVoice,
                                 onPick: { be, v in applyPicked(backend: be, voice: v) })
            }
        }
        .task {
            await cfg.refresh()
            seedPickers()
        }
        .task { stats = try? await DaemonClient.shared.stats() }
        .onChange(of: cfg.loadedFromDaemon) { _, _ in seedPickers() }
    }

    /// Seed picker selections from the daemon's current defaults. defaultVoice
    /// nil → fall back to the backend's own default_voice for a sensible
    /// initial selection (the daemon still treats "" as "backend picks").
    /// Pure assignment now — persistence is explicit (onSelect / onPick), so
    /// seeding can never write back and clobber the saved default_voice.
    private func seedPickers() {
        let be = cfg.defaultBackend ?? Backends.all.first?.id ?? ""
        pickBackend = be
        pickVoice = cfg.defaultVoice ?? Backends.find(id: be)?.defaultVoice ?? ""
        thresholdInput = cfg.sayThresholdChars
    }

    /// Commit the edited say-threshold to the daemon. No-op if unchanged so
    /// re-seeding / re-submitting the same value never round-trips.
    private func commitThreshold(_ chars: Int) {
        let v = max(0, chars)
        thresholdInput = v
        guard v != cfg.sayThresholdChars else { return }
        Task {
            do {
                _ = try await cfg.setSayThreshold(v)
                thresholdStatus = "saved"
            } catch {
                thresholdStatus = "save failed: \(error.localizedDescription)"
            }
        }
    }

    private func dismiss() {
        router.closeToList()
    }

    // Back button (left) replaces the old ✕. A downward swipe anywhere on the
    // header bar also dismisses, mirroring the slide-from-top presentation.
    private var header: some View {
        HStack(spacing: Spacing.md) {
            Button(action: dismiss) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(Tokens.accent)
                .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.accent.opacity(0.45)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Esc belongs to the voice picker while it is up.
            .keyboardShortcut(router.shortcutsOpen || showVoicePicker ? nil : .cancelAction)
            .help("Back (Esc)")

            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundStyle(Tokens.accent)
                .frame(width: 32, height: 32)
                .background(Tokens.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Settings")
                    .font(.system(size: 14, weight: .bold))
                Text("services · configuration")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.dim)
            }
            Spacer()
            // Grab handle hint for the swipe-down-to-dismiss affordance.
            Image(systemName: "chevron.compact.down")
                .font(.system(size: 18))
                .foregroundStyle(Tokens.ultraDim)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { v in
                    // Downward swipe on the header dismisses.
                    if v.translation.height > 60 { dismiss() }
                }
        )
    }


    /// CONFIGURATION — only the genuinely editable settings (say-threshold +
    /// default voice/backend, both POST /config). Read-only daemon facts live
    /// in ABOUT, so this panel is not a mix of settings and facts. Values
    /// source from AppConfig (daemon /config), so the panel re-renders on a
    /// config change.
    private var configSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            sectionLabel("CONFIGURATION")
            sayThresholdEditor
            defaultsPicker
            autoAdvanceToggle
        }
    }

    /// Auto-advance (HistoryStore.playNextInSeries): app-local, no daemon.
    private var autoAdvanceToggle: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Toggle(isOn: $autoAdvance) {
                Text("Play the next episode of a series").font(.system(size: 11, weight: .medium))
            }
            .toggleStyle(.switch).controlSize(.small)
            .accessibilityLabel("Play the next episode of a series")
            Text("When an episode ends, the next one in its series starts")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.ultraDim)
        }
        .padding(.vertical, Spacing.xs).padding(.horizontal, Spacing.xs)
    }

    /// Default backend + voice — writable. Changing either POSTs /config so
    /// the choice is authoritative for every surface (voice-say CLI, web, app),
    /// then adopts the daemon's authoritative response. Reuses the same
    /// `.menu` Picker + `Backends.find(id:)` discipline as ComposeScreen.
    private var defaultsPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("Voice Provider").font(.system(size: 11, weight: .medium))
                BackendSelector(selectedID: $pickBackend,
                                backends: cfg.backends,
                                downIDs: downBackendIDs,
                                onSelect: { b in
                                    // Move the voice to the new backend's
                                    // default, then persist both.
                                    let v = b.defaultVoice
                                    pickVoice = v
                                    persistDefaults(backend: b.id, voice: v)
                                })
            }
            HStack(spacing: Spacing.sm) {
                Text("Default voice").font(.system(size: 11, weight: .medium))
                Spacer()
                voiceTrigger
            }
            Text(defaultsStatus ?? "Initial pick in compose; per-render override available")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(defaultsStatus == nil ? Tokens.ultraDim : Tokens.accent)
        }
        .padding(.vertical, Spacing.xs).padding(.horizontal, Spacing.xs)
    }

    /// Trigger button for the shared interactive voice picker. Shows the
    /// current default voice's label + descriptor; opens the gallery sheet.
    private var voiceTrigger: some View {
        let resolved = pickVoice.isEmpty ? (Backends.find(id: pickBackend)?.defaultVoice ?? "") : pickVoice
        let meta = VoiceCatalog.meta(for: resolved)
        return Button(action: { showVoicePicker = true }) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(Tokens.accent)
                Text(meta.label).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Tokens.text)
                Text(meta.descriptor).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.dim)
                    .lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 11)).foregroundStyle(Tokens.dim)
            }
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
            .background(Tokens.bg2)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.borderStrong))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Choose the default voice")
    }

    /// Backend ids the probe currently reports down — drives the offline
    /// red dot on the segmented selector.
    private var downBackendIDs: Set<String> {
        Set(probe.backends.filter { $0.value == .down }.map { $0.key })
    }

    /// Commit a pick from the voice sheet (it may also change the backend).
    private func applyPicked(backend: String, voice: String) {
        pickBackend = backend
        pickVoice = voice
        persistDefaults(backend: backend, voice: voice)
    }

    private func persistDefaults(backend: String, voice: String) {
        // Timing-independent backstop: never write if the selection already
        // matches the daemon's current state. Makes seeding a guaranteed
        // no-op regardless of onChange ordering, so opening Settings can
        // never clobber the persisted default_voice.
        if backend == cfg.defaultBackend && voice == (cfg.defaultVoice ?? "") { return }
        Task {
            do {
                let warnings = try await cfg.setDefaults(backend: backend, voice: voice)
                defaultsStatus = warnings.first ?? "saved"
            } catch {
                defaultsStatus = "save failed: \(error.localizedDescription)"
            }
        }
    }

    /// Editable say-threshold row — replaces the old read-only configRow.
    /// Stepper buttons commit immediately; the numeric field commits on Enter.
    /// commitThreshold() no-ops when unchanged, so neither path double-POSTs.
    private var sayThresholdEditor: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.sm) {
                Text("Say threshold").font(.system(size: 11, weight: .medium))
                Spacer()
                TextField("", value: $thresholdInput, format: .number)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.accent)
                    .frame(width: 56)
                    .onSubmit { commitThreshold(thresholdInput) }
                Text("chars").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.dim)
                Stepper("",
                        onIncrement: { commitThreshold(thresholdInput + 20) },
                        onDecrement: { commitThreshold(thresholdInput - 20) })
                    .labelsHidden()
            }
            Text(thresholdStatus ?? "Renders ≤ this many chars are categorized as Says")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(thresholdStatus == nil ? Tokens.ultraDim : Tokens.accent)
        }
        .padding(.vertical, Spacing.xs).padding(.horizontal, Spacing.xs)
    }

    /// LIBRARY — what the library holds now (live, matches the list: deleting
    /// a recording lowers it) beside the all-time totals from GET /stats (never
    /// go down). Compact tiles, so each number sits next to its label.
    private var librarySection: some View {
        let size = fmtCompactSizeParts(store.totalBytes)
        return VStack(alignment: .leading, spacing: Spacing.md) {
            sectionLabel("LIBRARY")
            statGroup("In your library", [
                ("\(store.liveRenderCount)", "recordings"),
                (fmtCompactTime(store.totalDurationS), "listening time"),
                ("\(size.value) \(size.unit)", "on disk"),
                (fmtCompactChars(store.totalChars), "characters"),
            ])
            if let s = stats {
                statGroup("All time", [
                    (s.lifetime.renders.formatted(), "recordings made"),
                    ("\(fmtHours(s.lifetime.durationS)) h", "rendered"),
                    (s.lifetime.words.formatted(), "words"),
                ] + (s.lifetime.since.map { [(fmtSinceDate($0), "since")] } ?? []))
            }
            Text("Deleting a recording lowers \u{201C}In your library\u{201D}; \u{201C}All time\u{201D} never goes down.")
                .font(TypeScale.micro)
                .foregroundStyle(Tokens.dim)
        }
    }

    private func statGroup(_ title: String, _ items: [(value: String, label: String)]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Tokens.muted)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: Spacing.sm,
                                         alignment: .leading)],
                      alignment: .leading, spacing: Spacing.sm) {
                ForEach(items, id: \.label) { item in statTile(item.value, item.label) }
            }
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func statTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .monospaced))
                .foregroundStyle(Tokens.text)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(TypeScale.micro).foregroundStyle(Tokens.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
        .background(Tokens.bg2, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(Tokens.border))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Divider().background(Tokens.border)
            HStack(spacing: Spacing.sm) {
                Text("VoiceSay")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Tokens.muted)
                Text("·").foregroundStyle(Tokens.ultraDim)
                Text("macOS app for the voice-say daemon")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.dim)
            }
            .padding(.top, Spacing.sm)
        }
    }
}

/// "12.3" — hours, one decimal.
func fmtHours(_ seconds: Double) -> String {
    String(format: "%.1f", max(0, seconds) / 3600)
}

/// "23 Jun 2026" from a render ts ("2026-06-23T…"); the raw date if unparsable.
func fmtSinceDate(_ ts: String) -> String {
    let day = String(ts.prefix(10))
    let parse = DateFormatter()
    parse.locale = Locale(identifier: "en_US_POSIX")
    parse.dateFormat = "yyyy-MM-dd"
    guard let d = parse.date(from: day) else { return day }
    return d.formatted(.dateTime.day().month(.abbreviated).year())
}
