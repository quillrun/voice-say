// RenderQueueView — the live "Rendering" category surface: the currently-
// rendering job (locked head) over a reorderable "up next" list. Shown by
// ContentView when the Rendering category is selected. Reorder + remove drive
// RenderQueue; the head can't be moved (it's stopped via the streaming card's
// StreamingRenderControls — Pause / Stop Now / Delete).
// Each waiting row carries its OWN model (backend + voice), editable in place —
// the "swap between models" requirement.

import SwiftUI

struct RenderQueueView: View {
    @Environment(RenderQueue.self) private var queue
    @Environment(HistoryStore.self) private var store

    /// Job whose model is being edited — drives the VoicePickerSheet overlay.
    @State private var editingJobID: UUID? = nil

    /// Paused (resumable) drafts — formerly the separate Drafts category, now
    /// part of the Rendering bucket as paused renders. A draft being continued
    /// is excluded: it has a resume job in the queue, so it shows there (UP NEXT
    /// / CURRENTLY RENDERING), not duplicated in PAUSED.
    private var pausedDrafts: [VoiceEntry] {
        let resuming = queue.resumingTSs
        return store.resumableDrafts.filter { !resuming.contains($0.ts) }
    }

    private var isEmpty: Bool {
        queue.jobs.isEmpty && queue.failed.isEmpty && store.streamingEpisode == nil && pausedDrafts.isEmpty
    }

    var body: some View {
        ZStack {
            Tokens.bg
            // Hidden from VoiceOver while the voice picker covers it.
            Group {
                if isEmpty {
                    emptyState
                } else {
                    queueList
                }
            }
            .accessibilityHidden(editingJobID != nil)
            if let id = editingJobID, let job = (queue.jobs + queue.failed).first(where: { $0.id == id }) {
                modelPicker(for: job)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queueList: some View {
        List {
            // Only show CURRENTLY RENDERING when something is actually rendering
            // (a live episode, or the submit→episode_start gap). With nothing
            // rendering, no "preparing next render…" placeholder.
            if store.streamingEpisode != nil || queue.isRendering {
                Section {
                    head
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.lg,
                                                  bottom: Spacing.sm, trailing: Spacing.lg))
                } header: {
                    sectionHeader("CURRENTLY RENDERING")
                }
            }

            if queue.waitingForDaemon {
                Section {
                    daemonWaitBanner
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.lg,
                                                  bottom: Spacing.sm, trailing: Spacing.lg))
                }
            }

            if !queue.waiting.isEmpty {
                Section {
                    ForEach(Array(queue.waiting.enumerated()), id: \.element.id) { idx, job in
                        RenderQueueRow(job: job, position: idx + 1,
                                       onEditModel: { editingJobID = job.id })
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.lg,
                                                      bottom: Spacing.xs, trailing: Spacing.lg))
                    }
                    .onMove { from, to in queue.move(fromOffsets: from, toOffset: to) }
                } header: {
                    sectionHeader("UP NEXT · \(queue.waiting.count)")
                }
            }

            if !queue.failed.isEmpty {
                Section {
                    ForEach(queue.failed) { job in
                        FailedRenderRow(job: job)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.lg,
                                                      bottom: Spacing.xs, trailing: Spacing.lg))
                    }
                } header: {
                    sectionHeader("FAILED · \(queue.failed.count)")
                }
            }

            if !pausedDrafts.isEmpty {
                Section {
                    // Reuse the audio card (CommitRow) in rendering mode:
                    // a paused draft opens the details screen on click — no
                    // inline expand — and surfaces its render progress plus
                    // Continue-render / Show-in-Finder actions inline.
                    ForEach(pausedDrafts, id: \.id) { d in
                        CommitRow(entry: d,
                                  isExpanded: false,
                                  onToggle: { },
                                  renderingContext: true)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.lg,
                                                      bottom: Spacing.xs, trailing: Spacing.lg))
                    }
                } header: {
                    sectionHeader("PAUSED · \(pausedDrafts.count)")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Tokens.bg)
    }

    /// The locked head: the live streaming card once episode_start lands, or a
    /// "starting…" placeholder in the gap between submit and episode_start.
    @ViewBuilder private var head: some View {
        if let ep = store.streamingEpisode, !ep.done {
            StreamingEpisodeCard(episode: ep)
        } else {
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small).tint(Tokens.accent)
                Text(queue.activeJob.map { "starting '\($0.displayTitle)'…" } ?? "preparing next render…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Tokens.dim)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(Spacing.md)
            .background(Tokens.accent.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(Tokens.accent.opacity(0.25)))
        }
    }

    /// The queue holds its texts while the daemon is down and renders the
    /// head again once /health answers.
    private var daemonWaitBanner: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.small).tint(Tokens.warn)
            Text("daemon unreachable · the queue resumes when it is back")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Tokens.warn)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(Spacing.md)
        .background(Tokens.warn.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(Tokens.warn.opacity(0.35)))
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "waveform.circle")
                .font(.system(size: 34)).foregroundStyle(Tokens.dim)
            Text("No renders queued")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Tokens.muted)
            Text("Compose a render to start a queue. Completed renders land in History.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.dim)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ s: String) -> some View {
        SectionLabel(text: s, tone: Tokens.ultraDim)
            .padding(.top, Spacing.sm)
    }

    @ViewBuilder private func modelPicker(for job: RenderJob) -> some View {
        VoicePickerSheet(
            isPresented: Binding(get: { editingJobID != nil },
                                 set: { if !$0 { editingJobID = nil } }),
            context: .compose,
            initialBackendID: job.backendID,
            initialVoiceID: job.voice,
            onPick: { be, v in
                queue.setModel(job.id, backendID: be, voice: v)
                editingJobID = nil
            })
            .zIndex(10)
    }
}

/// One waiting ("up next") row: position, title, an editable model chip, char
/// count + ETA, a play-while-rendering toggle, and remove. The active head is
/// never rendered through this row (it's the StreamingEpisodeCard above).
private struct RenderQueueRow: View {
    @Environment(RenderQueue.self) private var queue
    @Environment(UIRouter.self) private var router
    let job: RenderJob
    let position: Int
    let onEditModel: () -> Void

    /// Open the queued item's details: a resume continues a draft, so open that
    /// draft's reader; a fresh render has no row yet, so open a read-only preview
    /// of its queued text (keyed by the job id; TranscriptScreen resolves it from
    /// the queue).
    private func openDetails() {
        router.open(.transcript(job.resumeTS ?? job.id.uuidString))
    }

    // A card in the SAME shape as a PAUSED CommitRow (Radius.md, Spacing.md pad,
    // bg2 fill, bordered, title-prominent, meta + actions rows), made a distinct
    // card type by the "#n · QUEUED" eyebrow + drag handle (vs the paused card's
    // voice/date + "% rendered" + Continue/Finder/Delete). Still drag-orderable
    // via the List .onMove (the handle is the affordance).
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Text("#\(position)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Tokens.accent)
                Text("QUEUED")
                    .font(.system(size: 11, weight: .bold)).kerning(0.8)
                    .foregroundStyle(Tokens.ultraDim)
                Spacer(minLength: Spacing.sm)
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11)).foregroundStyle(Tokens.ultraDim)
                    .help("Drag to reorder")
            }
            Button(action: openDetails) {
                Text(job.displayTitle)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(job.hasTitle ? Tokens.text : Tokens.dim)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open details")
            HStack(spacing: Spacing.sm) {
                modelChip
                Text(job.metaLine(withETA: true))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.dim)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            HStack(spacing: Spacing.sm) {
                playToggle
                Spacer(minLength: 0)
                ArmedDeleteControl(onDelete: { queue.remove(job.id) },
                                   help: "Remove from queue", label: "remove from queue")
            }
        }
        .padding(Spacing.md)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Tokens.bg2.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(Tokens.border, lineWidth: 1))
    }

    /// Backend + voice chip. Editable for a fresh render (opens the picker);
    /// static for a resume (the draft's original settings are used server-side).
    @ViewBuilder private var modelChip: some View {
        let accent = Color(hex: Backends.find(id: job.backendID)?.accent ?? "", fallback: Tokens.accent)
        let content = HStack(spacing: Spacing.xs) {
            Circle().fill(accent).frame(width: 6, height: 6)
            Text(backendLabel)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Tokens.muted)
            Text("·").foregroundStyle(Tokens.ultraDim).font(.system(size: 11))
            Text(VoiceCatalog.meta(for: job.voice).label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.muted)
            if !job.isResume {
                Image(systemName: "chevron.down").font(.system(size: 7)).foregroundStyle(Tokens.dim)
            }
        }
        .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs)
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.border))

        if job.isResume {
            content
        } else {
            Button(action: onEditModel) { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Change the model for this render")
        }
    }

    private var playToggle: some View {
        let on = job.playWhileRendering
        return Button(action: { queue.setPlayWhileRendering(job.id, !on) }) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: on ? "speaker.wave.2.fill" : "speaker.slash").font(.system(size: 11))
                Text(on ? "plays live" : "silent").font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(on ? Tokens.accent : Tokens.dim)
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm)
                .stroke(on ? Tokens.accent.opacity(0.5) : Tokens.borderStrong))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(on ? "Plays while rendering — click to render silently"
              : "Renders silently — click to play while rendering")
    }

    private var backendLabel: String {
        Backends.find(id: job.backendID)?.compactLabel ?? job.backendID
    }

}

/// A render that failed: its title, the error, and Retry / Remove. The text
/// stays here until the user chooses.
private struct FailedRenderRow: View {
    @Environment(RenderQueue.self) private var queue
    @Environment(UIRouter.self) private var router
    let job: RenderJob

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Text("FAILED")
                    .font(.system(size: 11, weight: .bold)).kerning(0.8)
                    .foregroundStyle(Tokens.del)
                Spacer(minLength: 0)
            }
            Button(action: { router.open(.transcript(job.resumeTS ?? job.id.uuidString)) }) {
                Text(job.displayTitle)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(job.hasTitle ? Tokens.text : Tokens.dim)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open details")
            Text(job.metaLine(withETA: false))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.dim)
                .lineLimit(1).truncationMode(.tail)
            if let failure = job.failure {
                Text(failure)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.del)
                    .lineLimit(2).truncationMode(.tail)
            }
            HStack(spacing: Spacing.sm) {
                Button(action: { queue.retry(job.id) }) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        Text("retry").font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(Tokens.accent)
                    .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.accent.opacity(0.5)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Queue this render again")
                Spacer(minLength: 0)
                ArmedDeleteControl(onDelete: { queue.remove(job.id) },
                                   help: "Remove this render and its text", label: "remove")
            }
        }
        .padding(Spacing.md)
        .background(RoundedRectangle(cornerRadius: Radius.md).fill(Tokens.del.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).stroke(Tokens.del.opacity(0.35), lineWidth: 1))
    }
}
