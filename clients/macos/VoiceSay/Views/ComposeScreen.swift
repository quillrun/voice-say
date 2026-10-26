// ComposeScreen — text + backend + voice + tags + render button. The app's
// `voice-say render`: it enqueues a RenderJob, and RenderQueue sends it to the
// daemon's /render_longform.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ComposeScreen: View {
    @Environment(HistoryStore.self) var store
    @Environment(RenderQueue.self) var renderQueue
    @Environment(AudioPlayer.self) var player
    @Environment(UIRouter.self) var router
    // Daemon-owned tunables. Observed so the say/render classification below
    // re-derives the moment the threshold is edited in Settings.
    private let config = AppConfig.shared

    @State private var text: String = ""
    /// Title / series / episode set on the new row (empty = not set; the
    /// daemon then derives the title from the text).
    @State private var titleField: String = ""
    @State private var seriesField: String = ""
    @State private var episodeField: String = ""
    @State private var dropTargeted = false
    /// Autosaved draft: restored when Compose opens empty, cleared on render.
    @AppStorage("composeDraftText") private var savedText = ""
    @AppStorage("composeDraftTitle") private var savedTitle = ""
    @AppStorage("composeDraftSeries") private var savedSeries = ""
    @AppStorage("composeDraftEpisode") private var savedEpisode = ""
    @State private var backendID: String = "kokoro"
    @State private var voice: String = "af_heart"
    /// Set once the user picks a backend or voice here: a late /config
    /// (the open's refresh, or the history load's) must not replace it.
    @State private var userPicked = false
    @State private var renderSpeed: Double = 1.0
    @State private var selectedTags: Set<String> = []
    /// Drives the interactive voice picker sheet overlay.
    @State private var showVoicePicker: Bool = false
    /// Play-while-rendering — the per-item override on the silent-batch default.
    /// When on, THIS queued render plays each chunk as it lands instead of
    /// rendering silently to history.
    @State private var streamMode: Bool = false
    /// Drives the Tags & Category picker (reuses TagPicker in staging mode).
    @State private var showTagPicker: Bool = false
    @State private var status: ComposeStatus = .idle

    /// Compose is enqueue-only (the render queue owns progress reporting), so
    /// the local status is just idle vs. a validation error.
    enum ComposeStatus: Equatable {
        case idle
        case error(String)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Tokens.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                composeHeader
                Divider().background(Tokens.border)
                // One 760pt content column (header + body + action bar all
                // share it). No ScrollView: the TEXT panel is the greedy
                // element, so the editor absorbs the window's height instead
                // of leaving dead background below the panels. VOICE and TAGS
                // sit side by side — fixed-height option panels don't deserve
                // a full row each.
                // When the window is too short for that, the column scrolls
                // with a fixed-height editor instead of overflowing upward
                // into the title bar.
                ViewThatFits(in: .vertical) {
                    column(editorHeight: nil)
                    ScrollView { column(editorHeight: 320) }
                }
                actionBar
            }
            // Under a picker the form is out of VoiceOver's reach, as the
            // window is under the pickers ContentView routes.
            .accessibilityHidden(showVoicePicker || showTagPicker)
            if showVoicePicker {
                VoicePickerSheet(isPresented: $showVoicePicker, context: .compose,
                                 initialBackendID: backendID, initialVoiceID: voice,
                                 onPick: { be, v in backendID = be; voice = v; userPicked = true })
                    .zIndex(5)
            }
            if showTagPicker {
                TagPicker(staging: $selectedTags, onClose: { showTagPicker = false })
                    .zIndex(6)
            }
        }
        .foregroundStyle(Tokens.text)
        .font(.system(.body, design: .monospaced))
        // Seed defaults once /config is available, and RE-seed if it lands
        // after this view appears — mirrors SettingsScreen's seedPickers wiring
        // so Compose doesn't strand on the kokoro/af_heart cold-start literals
        // (the daemon's built-in default backend and voice).
        .task {
            await config.refresh()
            syncDefaultsFromConfig()
        }
        .onChange(of: config.loadedFromDaemon) { _, _ in syncDefaultsFromConfig() }
        .onAppear {
            if text.isEmpty { text = savedText }
            if titleField.isEmpty { titleField = savedTitle }
            if seriesField.isEmpty { seriesField = savedSeries }
            if episodeField.isEmpty { episodeField = savedEpisode }
        }
        .onChange(of: text) { _, v in savedText = v }
        .onChange(of: titleField) { _, v in savedTitle = v }
        .onChange(of: seriesField) { _, v in savedSeries = v }
        .onChange(of: episodeField) { _, v in savedEpisode = v }
    }

    private var composeHeader: some View {
        HStack(spacing: Spacing.md) {
            Button(action: { router.closeToList() }) {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                    Text("Back").font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
                .foregroundStyle(Tokens.accent)
                .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.accent.opacity(0.45)))
                .contentShape(Rectangle())
            }
            // Esc belongs to the voice picker while it is up.
            .buttonStyle(.plain).keyboardShortcut(router.shortcutsOpen || showVoicePicker ? nil : .cancelAction)
            .help("Back (Esc)")
            Image(systemName: "waveform.circle").font(.system(size: 14)).foregroundStyle(Tokens.accent)
                .frame(width: 30, height: 30).background(Tokens.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("New render").font(TypeScale.title)
                Text("type text · pick a voice · render to history")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.dim)
            }
            Spacer()
        }
        // Same 760 content column as the body and action bar — one width
        // regime for the whole screen.
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.lg)
    }

    /// Sync initial defaults from the daemon config once backends are loaded.
    /// Honors the daemon's persisted default_backend / default_voice (set in
    /// Settings) so the compose pane opens on the same choice every surface
    /// uses; falls back to the first backend + its own default voice.
    private func syncDefaultsFromConfig() {
        guard let seed = Self.seededPick(defaultBackend: config.defaultBackend,
                                         defaultVoice: config.defaultVoice,
                                         userPicked: userPicked) else { return }
        backendID = seed.backend
        voice = seed.voice
    }

    /// The daemon defaults to seed the pickers with, or nil when the user
    /// already picked (or no backend is known). Only adopts default_voice if it
    /// belongs to the backend; otherwise the backend's own default keeps the
    /// picker valid.
    static func seededPick(defaultBackend: String?, defaultVoice: String?, userPicked: Bool,
                           backends: [Backend] = Backends.all) -> (backend: String, voice: String)? {
        guard !userPicked,
              let beID = defaultBackend ?? backends.first?.id,
              let be = backends.first(where: { $0.id == beID }) else { return nil }
        if let dv = defaultVoice, be.voices.contains(dv) { return (be.id, dv) }
        return (be.id, be.defaultVoice)
    }

    private func textBox(height: CGFloat?) -> some View {
        TextEditor(text: $text)
            .font(TypeScale.body)
            .foregroundStyle(Tokens.text)
            .scrollContentBackground(.hidden)
            .background(Tokens.bg)
            .padding(Spacing.sm)
            // Greedy — the editor absorbs the window height (the old 260pt cap
            // left the bottom half of tall windows as dead background).
            .frame(minHeight: height ?? 150, maxHeight: height ?? .infinity)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.border))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("type text to render…")
                        .font(TypeScale.body)
                        .foregroundStyle(Tokens.ultraDim)
                        // Match the TextEditor's actual text origin (panel pad
                        // + its ~5pt internal inset) so the placeholder sits
                        // where the caret is.
                        .padding(.leading, Spacing.sm + 5)
                        .padding(.top, Spacing.sm + 1)
                        .allowsHitTesting(false)
                }
            }
    }

    // Purely derived from the composed text and the daemon's (now editable)
    // say-threshold. Mirrors how the daemon classifies a render: text whose
    // length is ≤ the threshold is a "say", longer text is a full "render".

    private var charCount: Int { text.count }

    /// "≈ 12 min audio" (at RenderJob.charsPerSecond); nil for tiny texts.
    nonisolated static func estimate(chars: Int) -> String? {
        let s = Double(chars) / RenderJob.charsPerSecond
        guard s >= 30 else { return nil }
        return "≈ \(max(1, Int((s / 60).rounded()))) min audio"
    }
    private var isSay: Bool { charCount <= config.sayThresholdChars }
    private var classificationLabel: String { isSay ? "say" : "render" }
    private var classificationColor: Color { isSay ? Tokens.add : Tokens.warn }

    private var charCountRow: some View {
        HStack(spacing: Spacing.sm) {
            Text("\(fmtCompactChars(charCount)) \(charCount == 1 ? "char" : "chars")")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.dim)
            Text("·")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.ultraDim)
            Text(classificationLabel)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .kerning(0.4)
                .foregroundStyle(classificationColor)
                .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs)
                .background(classificationColor.opacity(0.14))
                .clipShape(Capsule())
            if let est = Self.estimate(chars: charCount) {
                Text("·").font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.ultraDim)
                Text(est).font(.system(size: 11, design: .monospaced)).foregroundStyle(Tokens.dim)
                    .help("Estimated audio length at 1.0×")
            }
            Spacer(minLength: 0)
            Text("threshold \(config.sayThresholdChars)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.ultraDim)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(charCount) characters, classified \(classificationLabel), say threshold \(config.sayThresholdChars) characters")
    }

    /// BACKEND — segmented chip selector. Selecting a backend resets the
    /// voice to that backend's default (the picker's old onChange behavior,
    /// now driven explicitly through onSelect so the voice-picker path — which
    /// can also change the backend — doesn't fight a SwiftUI .onChange).
    // Each compose step is grouped into a bordered panel so the screen reads
    // as ordered sections (Text → Voice → Tags) instead of one loose stack of
    // labels and controls floating in space.
    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.lg)
            .background(RoundedRectangle(cornerRadius: Radius.md).fill(Tokens.bg2.opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(Tokens.border))
    }

    /// The 760 pt content column. `editorHeight` nil = the editor absorbs
    /// the window height; a value = fixed (the scrolling fallback).
    private func column(editorHeight: CGFloat?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            textPanel(editorHeight: editorHeight)
            // Side by side when they fit, else stacked (a few backend chips
            // alone can fill the column).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Spacing.lg) { voicePanel; tagsPanel }
                VStack(alignment: .leading, spacing: Spacing.lg) { voicePanel; tagsPanel }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, Spacing.xl).padding(.top, Spacing.xl).padding(.bottom, Spacing.lg)
    }

    private func textPanel(editorHeight: CGFloat?) -> some View {
        panel {
            HStack {
                SectionLabel(text: "TEXT")
                Spacer()
                Button(action: openScript) {
                    Label("Open script…", systemImage: "doc.text")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                }
                .buttonStyle(.plain).foregroundStyle(Tokens.accent)
                .keyboardShortcut(router.shortcutsOpen ? nil : KeyboardShortcut("o"))
                .help("Open a .md or .txt script (⌘O) — or drop one on the text box")
            }
            metaRow
            textBox(height: editorHeight)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm)
                    .stroke(Tokens.accent, lineWidth: dropTargeted ? 2 : 0))
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                    guard let p = providers.first else { return false }
                    _ = p.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in importScript(url) }
                    }
                    return true
                }
            charCountRow
        }
    }

    /// Title · series · episode — set on the new row with the render.
    private var metaRow: some View {
        HStack(spacing: Spacing.sm) {
            metaField("title (else the first line)", text: $titleField)
            metaField("series", text: $seriesField).frame(width: 150)
            metaField("ep.", text: $episodeField).frame(width: 56)
        }
    }

    private func metaField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
            .background(Tokens.bg)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.border))
    }

    private func openScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ScriptImport.extensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { importScript(url) }
    }

    /// Load a script file into the editor; its heading (or first line)
    /// becomes the title — the old title belonged to the text just replaced.
    private func importScript(_ url: URL) {
        guard ScriptImport.extensions.contains(url.pathExtension.lowercased()) else {
            status = .error("not a script file: \(url.lastPathComponent) (.md or .txt)")
            return
        }
        do {
            let parsed = ScriptImport.parse(try String(contentsOf: url, encoding: .utf8))
            text = parsed.text
            if !parsed.title.isEmpty { titleField = parsed.title }
            status = .idle
        } catch {
            status = .error("could not read \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// VOICE — provider segmented selector + the voice picker + (when the
    /// backend supports it) the speed slider, grouped into one panel.
    private var voicePanel: some View {
        panel {
            SectionLabel(text: "VOICE PROVIDER")
            BackendSelector(selectedID: $backendID,
                            onSelect: { b in voice = b.defaultVoice; userPicked = true })
            // Voice and speed side by side when the whole voice name fits,
            // with a shorter slider before speed drops below: in the
            // half-width panel beside TAGS the 160 pt slider left the trigger
            // too narrow for "Heart · warm · friendly", and a stacked speed
            // falls under the action bar in a 800 pt tall window. No Spacer in
            // the rows: with one, ViewThatFits never picked a side-by-side row.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xl) {
                    voiceField
                    speedField(width: 160)
                }
                HStack(alignment: .firstTextBaseline, spacing: Spacing.lg) {
                    voiceField
                    speedField(width: 100)
                }
                VStack(alignment: .leading, spacing: Spacing.md) {
                    voiceField
                    speedField(width: 160)
                }
            }
        }
    }

    private var voiceField: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionLabel(text: "VOICE")
            voiceTrigger
        }
    }

    /// Speed (only when the backend supports it) — find()-not-by() so a
    /// missing backend doesn't render a misleading slider.
    @ViewBuilder
    private func speedField(width: CGFloat) -> some View {
        if Backends.find(id: backendID)?.supportsSpeed == true {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionLabel(text: "SPEED \(fmtSpeed(renderSpeed))")
                Slider(value: $renderSpeed, in: 0.5...2.0, step: 0.05)
                    .frame(width: width)
                    .tint(Tokens.accent)
            }
        }
    }

    // (VOICE / SPEED controls were folded into voicePanel above.)

    private var voiceTrigger: some View {
        let meta = VoiceCatalog.meta(for: voice)
        return Button(action: { showVoicePicker = true }) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "speaker.wave.2").font(.system(size: 12)).foregroundStyle(Tokens.accent)
                Text(meta.label).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Tokens.text)
                    .lineLimit(1).truncationMode(.tail)
                    .layoutPriority(1)   // when space is short the descriptor yields, not the name
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
        .help("Choose a voice")
    }

    private var tagsPanel: some View {
        panel {
            HStack(spacing: Spacing.sm) {
                SectionLabel(text: "TAGS")
                Spacer(minLength: 0)
                TagsAndCategoryButton(action: { showTagPicker = true })
            }
            // Selected tags — removable chips, wrapping (the old single
            // HStack overflowed the now-narrower half-width panel). Tags are
            // picked in the Tags & Category dialog (single source — no
            // separate add field).
            if selectedTags.isEmpty {
                Text("no tags — add from Tags & Category")
                    .font(TypeScale.micro)
                    .foregroundStyle(Tokens.dim)
            } else {
                FlowLayout(spacing: Spacing.sm, lineSpacing: Spacing.sm) {
                    ForEach(selectedTags.sorted(), id: \.self) { tag in selectedTagChip(tag) }
                }
            }
        }
    }

    private func selectedTagChip(_ tag: String) -> some View {
        TagChip(tag: tag, onRemove: { selectedTags.remove(tag) })
    }

    /// Pinned bottom action bar — options on the left, status + Render on the
    /// right. Lives outside the ScrollView so Render is always reachable.
    private var actionBar: some View {
        VStack(spacing: 0) {
            Divider().background(Tokens.border)
            HStack(spacing: Spacing.lg) {
                Toggle("Play while rendering", isOn: $streamMode)
                    .toggleStyle(.vsCheckbox)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.muted)
                    .help("Play each chunk of THIS render as it lands. Off (default) renders silently to history — the rest of the queue stays silent so a batch can't hijack audio.")
                Spacer()
                statusLine
                renderButton
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.lg)
        }
        .background(Tokens.bg)
    }

    @ViewBuilder
    private var statusLine: some View {
        switch status {
        case .idle:
            // Stable placeholder (was EmptyView) — the action bar no longer
            // reflows when status appears; doubles as the shortcut hint.
            Text("\(Self.renderShortcutGlyph) to render")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.ultraDim)
        case .error(let msg):
            Text("✗ \(msg)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.del)
                .lineLimit(2).truncationMode(.tail)
        }
    }

    /// True when there is text to enqueue.
    private var canRender: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// "Render" when the queue is idle (this starts immediately), "Add to
    /// queue" when a render is already in flight (this lines up behind it).
    private var queueing: Bool { renderQueue.isRendering }

    private var renderButton: some View {
        Button(action: render) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: queueing ? "text.append" : "play.fill").font(.system(size: 12, weight: .bold))
                Text(queueing ? "Add to queue" : "Render")
            }
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            // Fixed width across both labels so the bar doesn't reflow when
            // the queue state flips Render ↔ Add to queue.
            .frame(minWidth: 132)
            .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
            .background(canRender ? Tokens.accent : Tokens.accent.opacity(0.4))
            .foregroundStyle(Tokens.bg)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            // Same accent-CTA shadow as the header's render button.
            .shadow(color: canRender ? Tokens.accent.opacity(0.3) : .clear, radius: 5, y: 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(Self.renderShortcut)
        .disabled(!canRender)
        .help(queueing ? "Add this render to the queue (\(Self.renderShortcutGlyph))"
                       : "Render this text to history (\(Self.renderShortcutGlyph))")
    }

    /// ⌘↩, not plain Return (.defaultAction): Return inserts a newline in the
    /// editor and ends editing in the title/series/episode fields without
    /// queueing a half-filled render. The hint and tooltip read this.
    static let renderShortcut = KeyboardShortcut(.return, modifiers: .command)
    static var renderShortcutGlyph: String { glyph(renderShortcut) }

    /// "⌘↩"-style label for a shortcut (modifiers in the menu order ⌃⌥⇧⌘).
    static func glyph(_ s: KeyboardShortcut) -> String {
        var g = ""
        if s.modifiers.contains(.control) { g += "⌃" }
        if s.modifiers.contains(.option) { g += "⌥" }
        if s.modifiers.contains(.shift) { g += "⇧" }
        if s.modifiers.contains(.command) { g += "⌘" }
        switch s.key {
        case .return: g += "↩"
        case .escape: g += "⎋"
        default: g += String(s.key.character).uppercased()
        }
        return g
    }


    private func render() {
        // No /config yet means no backend catalog to resolve against: say the
        // daemon is down rather than "unknown backend". The text stays, and
        // the catalog loads when the event stream reconnects.
        guard config.loadedFromDaemon else {
            status = .error("voice-say daemon isn't answering — \(DaemonController.startHint)")
            return
        }
        guard let backend = Backends.find(id: backendID) else {
            status = .error("unknown backend \(backendID)")
            return
        }
        // Sorted for deterministic ordering in the stored entry.
        let tagsToSend = selectedTags.sorted()
        let speed = backend.supportsSpeed ? renderSpeed : 1.0
        let t = text

        // Enqueue rather than render directly: the RenderQueue's serial pump
        // owns submission so renders run one at a time and never overlap. The
        // job carries its OWN backend/voice (mix models across the queue) and
        // its own play-while-rendering override (silent batch by default).
        let title = titleField.trimmingCharacters(in: .whitespacesAndNewlines)
        let series = seriesField.trimmingCharacters(in: .whitespacesAndNewlines)
        let episodeText = episodeField.trimmingCharacters(in: .whitespaces)
        let episode = Int(episodeText)
        guard episodeText.isEmpty || (episode ?? -1) >= 0 else {
            status = .error("episode must be a whole number ≥ 0")
            return
        }
        let job = RenderJob(source: .fresh(text: t),
                            backendID: backend.id,
                            voice: voice,
                            speed: speed,
                            tags: tagsToSend,
                            playWhileRendering: streamMode,
                            title: title.isEmpty ? RenderJob.title(fromText: t) : title,
                            overlay: RenderOverlay(title: title.isEmpty ? nil : title,
                                                   series: series.isEmpty ? nil : series,
                                                   episode: episode))
        renderQueue.enqueue(job)

        text = ""
        titleField = ""
        episodeField = ""
        selectedTags = []
        status = .idle
        // Land on the Rendering queue so the just-queued render (and the live
        // one) are immediately visible; the reader stays one click away.
        store.selectRenderingCategory()
        router.closeToList()
    }
}
