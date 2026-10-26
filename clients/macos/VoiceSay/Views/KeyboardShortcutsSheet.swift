// KeyboardShortcutsSheet — Help ▸ Keyboard Shortcuts (⌘/): the
// ShortcutReference as a card over the current screen, one eyebrow per room,
// one row per key. A reference, not a tutorial: the check is pressing the
// key and watching the action. Esc, ⌘/ or the scrim closes it. While it is
// open the router counts it as an overlay, so the player keys and the
// list's ⌘Y / ⌘⌫ / Esc stay with it.

import SwiftUI

struct KeyboardShortcutsSheet: View {
    @Environment(UIRouter.self) private var router

    var body: some View {
        ZStack(alignment: .top) {
            Tokens.scrim
                .ignoresSafeArea()
                .onTapGesture { router.closeShortcuts() }
            card
                .padding(.top, Spacing.xxl * 2)
        }
        .foregroundStyle(Tokens.text)
        .font(.system(.body, design: .monospaced))
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Tokens.border)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(ShortcutReference.groups) { group in
                        VStack(alignment: .leading, spacing: Spacing.sm) {
                            SectionLabel(text: group.room.uppercased())
                            ForEach(group.rows) { row in
                                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                                    HStack(spacing: Spacing.xs) {
                                        ForEach(row.caps, id: \.self) { cap in keyCap(cap) }
                                    }
                                    .frame(width: 112, alignment: .leading)
                                    Text(row.action)
                                        .font(.system(size: 12))
                                        .foregroundStyle(Tokens.text)
                                        .lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.lg)
            }
            .frame(maxHeight: 520)
        }
        .frame(width: 440)
        .background(Tokens.bg2)
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).stroke(Tokens.borderStrong))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .shadow(color: .black.opacity(0.6), radius: 40, x: 0, y: 24)
    }

    private var header: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "keyboard")
                .font(.system(size: 14))
                .foregroundStyle(Tokens.accent)
                .frame(width: 28, height: 28)
                .background(Tokens.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            Text("Keyboard Shortcuts")
                .font(.system(size: 13.5, weight: .bold))
            Spacer()
            Button(action: { router.closeShortcuts() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Tokens.dim)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
        }
        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.md)
    }

    private func keyCap(_ cap: String) -> some View { KeyCap(cap) }
}

/// One key cap ("⌘/", "Space"): the sheet's rows and the Settings row.
struct KeyCap: View {
    let cap: String
    init(_ cap: String) { self.cap = cap }

    var body: some View {
        Text(cap)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Tokens.muted)
            .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs)
            .background(Tokens.chipWash)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.border))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }
}

/// The Settings row that opens Help ▸ Keyboard Shortcuts (his ask: the hint
/// at the top of Settings).
struct KeyboardShortcutsRow: View {
    @Environment(UIRouter.self) private var router

    var body: some View {
        Button(action: { router.toggleShortcuts() }) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12))
                    .foregroundStyle(Tokens.accent)
                    .frame(width: 24, height: 24)
                    .background(Tokens.accentSoft)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                Text("Keyboard shortcuts")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Tokens.text)
                Spacer()
                KeyCap("⌘/")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Every key, by the room it works in (⌘/)")
    }
}
