// BackendSelector — segmented chip row for picking a TTS backend. One
// component shared by the New-render screen, the voice picker sheet, and
// Settings (replacing the plain menu Pickers). Each chip carries the
// backend's accent status dot, a "SPEED" tag when the backend supports a
// speed control, and a red offline dot for any id in `downIDs`.

import SwiftUI

struct BackendSelector: View {
    @Binding var selectedID: String
    var backends: [Backend] = Backends.all
    /// Backend ids known to be offline (from a Settings probe). Empty
    /// elsewhere — Compose has no live probe, so chips just show accent dots.
    var downIDs: Set<String> = []
    /// Called after a selection so the caller can sync voice/speed + persist.
    var onSelect: ((Backend) -> Void)? = nil

    var body: some View {
        HStack(spacing: Spacing.sm) {
            ForEach(backends) { b in chip(b) }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ b: Backend) -> some View {
        let on = b.id == selectedID
        let accent = Color(hex: b.accent, fallback: Tokens.muted)
        let down = downIDs.contains(b.id)
        let dotColor = down ? Tokens.del : accent
        return Button(action: {
            selectedID = b.id
            onSelect?(b)
        }) {
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(dotColor.opacity(on ? 0.35 : 0.0), lineWidth: 3))
                    .opacity(down ? 0.65 : 1.0)
                Text(displayLabel(b))
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize()
                if b.supportsSpeed {
                    Text("SPEED")
                        .font(.system(size: 11, design: .monospaced))
                        .kerning(0.4)
                        .padding(.horizontal, Spacing.xs).padding(.vertical, Spacing.xxs)
                        .background(Tokens.chipWash)
                        .foregroundStyle(Tokens.dim)
                        .clipShape(Capsule())
                        .fixedSize()
                }
            }
            .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
            .background(on ? accent.opacity(0.14) : Tokens.bg2)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(on ? accent : Tokens.borderStrong))
            .foregroundStyle(on ? Tokens.text : Tokens.muted)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(down ? "\(b.label) — offline" : b.label)
    }

    /// Strip a trailing " (local)" so chips stay compact (via Backend.compactLabel).
    private func displayLabel(_ b: Backend) -> String {
        b.compactLabel
    }
}
