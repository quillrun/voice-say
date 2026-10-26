// SettingsServicesPanel — the Settings "SERVICES" section: daemon row with
// start/restart/stop (launchctl via DaemonController), one row per catalog
// backend with Start/Stop where client-manageable (BackendController), all
// liveness from the shared HealthMonitor. Split out of SettingsScreen;
// the panel owns its own probe-refresh loop.

import SwiftUI

struct SettingsServicesPanel: View {
    @Environment(HealthMonitor.self) var probe
    @Environment(DaemonController.self) var controller
    @Environment(BackendController.self) var backendCtl
    // Observed so backend rows track daemon /config live.
    private let cfg = AppConfig.shared
    /// Stop / Restart wait for a confirmation: either one cuts off a render in
    /// progress and can't be taken back (hig/alerts.md › Best practices). The
    /// button keeps the plain style, since the person chose the action
    /// (hig/alerts.md › Buttons).
    @State private var pending: Confirm? = nil

    enum Confirm: Equatable {
        case stopDaemon, restartDaemon
        case stopBackend(Backend)

        var title: String {
            switch self {
            case .stopDaemon: return "Stop the \(SettingsServicesPanel.daemonName)?"
            case .restartDaemon: return "Restart the \(SettingsServicesPanel.daemonName)?"
            case .stopBackend(let b): return "Stop \(b.label)?"
            }
        }
        var message: String {
            switch self {
            case .stopDaemon: return "A render in progress stops, and nothing renders or loads until you start it again."
            case .restartDaemon: return "A render in progress stops."
            case .stopBackend: return "A render in progress on it stops, and its voices can't render until you start it again."
            }
        }
        var button: String {
            switch self {
            case .stopDaemon: return "Stop Daemon"
            case .restartDaemon: return "Restart"
            case .stopBackend: return "Stop"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                sectionLabel("SERVICES")
                Spacer()
                Button(action: { Task { await probe.refresh(cfg.backends) } }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Tokens.dim)
                }
                .buttonStyle(.plain)
                .help("Re-probe all endpoints")
                .accessibilityLabel("Re-check services")
            }
            daemonRow
            // One row per backend the daemon reports — drives on/off via the
            // service descriptor. Empty only before /config returns.
            ForEach(cfg.backends) { backendRow($0) }
            if cfg.backends.isEmpty {
                Text(probe.daemon == .down ? "daemon not reachable" : "loading backends…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.ultraDim)
                    .padding(.horizontal, Spacing.sm)
            }
        }
        .confirmationDialog(pending?.title ?? "",
                            isPresented: Binding(get: { pending != nil },
                                                 set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible,
                            presenting: pending) { p in
            Button(p.button) { run(p) }
            Button("Cancel", role: .cancel) { }
                .keyboardShortcut(.cancelAction)
        } message: { p in
            Text(p.message)
        }
        .task {
            // Re-probe after a backend start/stop settles, and on a 5 s
            // cadence while the panel is visible (same loop the shell ran
            // before the split).
            backendCtl.onSettled = { Task { await probe.refresh(cfg.backends) } }
            // First-ever open: the shell's own .task loads /config in
            // parallel — make sure the catalog is there before the first
            // probe (pre-split, one task sequenced refresh after config).
            // No-op re-fetch on every later open (AppConfig is a singleton).
            if cfg.backends.isEmpty { await cfg.refresh() }
            while !Task.isCancelled {
                await probe.refresh(cfg.backends)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// A backend row: status dot + name + endpoint/mechanism + Start/Stop
    /// (when the daemon marks it client-manageable). Mirrors `daemonRow` but
    /// drives `BackendController` instead of `DaemonController`.
    /// Other backends that bind the same host:port. When non-empty, the
    /// status dot reflects shared endpoint reachability (a port probe can't
    /// tell which of them is actually serving), so we say so rather than
    /// imply both processes are independently up.
    private func portPeers(_ backend: Backend) -> [Backend] {
        cfg.backends.filter { $0.id != backend.id && $0.hostPort == backend.hostPort }
    }

    private func backendRow(_ backend: Backend) -> some View {
        let state = probe.backends[backend.id] ?? .unknown
        let kind = backend.service?.kind
        let mechanism: String = {
            switch kind {
            case "launchd": return "launchd"
            case "docker":  return "docker"
            default:        return "manual"
            }
        }()
        let peers = portPeers(backend)
        let subtitle: String = {
            let base = "\(backend.hostPort)  ·  \(mechanism)"
            guard !peers.isEmpty else { return base }
            return base + "  ·  shares it w/ " + peers.map(\.id).joined(separator: ", ")
        }()
        let act = backendCtl.action(for: backend.id)
        return VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(stateColor(state))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(stateColor(state).opacity(0.4), lineWidth: 3))
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(backend.label).font(.system(size: 12, weight: .medium))
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.dim)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    Text(stateLabel(state))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(stateColor(state))
                    if !peers.isEmpty && state == .up {
                        Text("endpoint")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Tokens.ultraDim)
                    }
                }
            }
            if BackendController.isManageable(backend) {
                HStack(spacing: Spacing.sm) {
                    daemonButton("play.fill", label: "Start", service: backend.label, tone: Tokens.add,
                                 enabled: state != .up && act != .running) {
                        backendCtl.start(backend)
                    }
                    daemonButton("stop.fill", label: "Stop", service: backend.label, tone: Tokens.del,
                                 enabled: state == .up && act != .running) {
                        pending = .stopBackend(backend)
                    }
                    Spacer()
                    backendActionStatus(act)
                }
                .padding(.top, Spacing.sm)
            }
        }
        .padding(.vertical, Spacing.sm).padding(.horizontal, Spacing.sm)
        .background(Tokens.bg2.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }

    @ViewBuilder
    private func backendActionStatus(_ act: ServiceOutcome) -> some View {
        switch act {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small).tint(Tokens.accent)
                Text("working…").font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.dim)
            }
        case .ok(let m):
            Text("✓ \(m)").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.add).lineLimit(1).truncationMode(.tail)
        case .failed(let m):
            Text("✗ \(m)").font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.del).lineLimit(2).truncationMode(.tail)
        }
    }

    /// Daemon row gets the full status + start/stop/restart controls.
    /// Other rows are read-only — only the daemon is launchctl-managed.
    private var daemonRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(stateColor(probe.daemon))
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(stateColor(probe.daemon).opacity(0.4), lineWidth: 3))
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(Self.daemonName).font(.system(size: 12, weight: .medium))
                    Text("\(DaemonClient.shared.baseHostPort)  ·  \(DaemonController.serviceLabel)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Tokens.dim)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    Text(stateLabel(probe.daemon))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(stateColor(probe.daemon))
                    if let v = probe.daemonVersion, probe.daemon == .up {
                        Text("v\(v)").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Tokens.ultraDim)
                    }
                }
            }
            if DaemonController.agentInstalled {
                daemonControls
            } else {
                // No LaunchAgent: launchctl has nothing to drive, so offer
                // no buttons that could only fail.
                Text("Not managed by launchd. Start it with \"make run\" in the voice-say repo; "
                     + "to start and stop it here, install "
                     + "daemon/launchd/\(DaemonController.serviceLabel).plist.example.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.top, Spacing.sm)
            }
        }
        .padding(.vertical, Spacing.sm).padding(.horizontal, Spacing.sm)
        .background(Tokens.bg2.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .onChange(of: controller.lastAction) { _, new in
            // After any successful start/stop/restart, give launchd a moment
            // to settle then re-probe so the dot/colour reflect reality.
            if case .ok = new {
                Task {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    await probe.refresh(cfg.backends)
                }
            }
        }
    }

    /// Start / Restart / Stop through launchctl, with the last outcome.
    private var daemonControls: some View {
        HStack(spacing: Spacing.sm) {
            daemonButton("play.fill", label: "Start", service: Self.daemonName, tone: Tokens.add,
                         enabled: probe.daemon != .up && controller.lastAction != .running) {
                controller.start()
            }
            daemonButton("arrow.clockwise", label: "Restart", service: Self.daemonName, tone: Tokens.accent,
                         enabled: probe.daemon == .up && controller.lastAction != .running) {
                pending = .restartDaemon
            }
            daemonButton("stop.fill", label: "Stop", service: Self.daemonName, tone: Tokens.del,
                         enabled: probe.daemon == .up && controller.lastAction != .running) {
                pending = .stopDaemon
            }
            Spacer()
            actionStatus
        }
        .padding(.top, Spacing.sm)
    }

    nonisolated static let daemonName = "voice-say daemon"

    private func run(_ p: Confirm) {
        switch p {
        case .stopDaemon: controller.stop()
        case .restartDaemon: controller.restart()
        case .stopBackend(let b): backendCtl.stop(b)
        }
    }

    /// `service` names the row for VoiceOver: the rows repeat Start / Stop,
    /// so "Stop" alone doesn't say which (hig/voiceover.md › Descriptions).
    private func daemonButton(_ icon: String, label: String, service: String, tone: Color,
                              enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
            .background(enabled ? tone.opacity(0.18) : Tokens.bg2.opacity(0.3))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(
                enabled ? tone.opacity(0.55) : Tokens.borderStrong))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .foregroundStyle(enabled ? tone : Tokens.ultraDim)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel("\(label) \(service)")
    }

    @ViewBuilder
    private var actionStatus: some View {
        switch controller.lastAction {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: Spacing.sm) {
                ProgressView().controlSize(.small).tint(Tokens.accent)
                Text("working…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.dim)
            }
        case .ok(let msg):
            Text("✓ \(msg)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.add)
                .lineLimit(1)
                .truncationMode(.tail)
        case .failed(let msg):
            Text("✗ \(msg)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.del)
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    private func stateLabel(_ s: HealthMonitor.State) -> String {
        switch s {
        case .unknown: return "PROBING…"
        case .up:      return "UP"
        case .down:    return "DOWN"
        }
    }
    private func stateColor(_ s: HealthMonitor.State) -> Color {
        switch s {
        case .unknown: return Tokens.dim
        case .up:      return Tokens.add
        case .down:    return Tokens.del
        }
    }

}
