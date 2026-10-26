// TaxonomyKit — the pieces the three tag dialogs share: the scrim + card
// chrome with its header and optional search field, section labels, empty
// hints, the dashed create row, and the selectable category / tag rows.
// TagAssignEditor (one entry), TaxonomyEditor (a new render's staging) and
// TaxonomyManageView (the library vocabulary) differ only in what they stage
// and save; how a row looks lives here once.

import SwiftUI

/// Scrim + centered card: header (icon, title, subtitle, close), an optional
/// search field, a scrolling body and a footer. `showsCard` false leaves just
/// the scrim (an entry that is still resolving).
struct TaxonomyDialog<Content: View, Footer: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    var width: CGFloat = 480
    var maxBodyHeight: CGFloat = 420
    var search: Binding<String>? = nil
    var searchPrompt: String = ""
    var showsCard = true
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        ZStack(alignment: .top) {
            Tokens.scrim
                .ignoresSafeArea()
                .onTapGesture { onClose() }
            if showsCard {
                card.padding(.top, Spacing.xxl * 2)
            }
        }
        .foregroundStyle(Tokens.text)
        .font(.system(.body, design: .monospaced))
    }

    private var card: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Tokens.border)
            if let search { searchField(search) }
            ScrollView {
                // Lazy — only visible rows materialize (~300 tags).
                LazyVStack(alignment: .leading, spacing: Spacing.sm) { content() }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.md)
            }
            .frame(maxHeight: maxBodyHeight)
            Divider().background(Tokens.border)
            footer()
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
        }
        .frame(width: width)
        .background(Tokens.bg2)
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).stroke(Tokens.borderStrong))
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .shadow(color: .black.opacity(0.6), radius: 40, x: 0, y: 24)
    }

    private var header: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Tokens.accent)
                .frame(width: 28, height: 28)
                .background(Tokens.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title)
                    .font(.system(size: 13.5, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Tokens.dim)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14))
                    .foregroundStyle(Tokens.dim)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
    }

    private func searchField(_ text: Binding<String>) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Tokens.dim)
            TextField(searchPrompt, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Tokens.text)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Tokens.bg)
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.borderStrong))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.md)
    }
}

/// "CATEGORIES (n)" — matches the sidebar's section labels; `hint` adds "— hint".
struct TaxonomySectionLabel: View {
    let label: String
    let count: Int
    var hint: String? = nil

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
            Text("(\(count))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            if let hint {
                Text("— \(hint)")
                    .font(.system(size: 11, design: .monospaced))
            }
        }
        .foregroundStyle(Tokens.ultraDim)
        .padding(.top, Spacing.sm)
    }
}

struct TaxonomyEmptyHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Tokens.ultraDim)
            .padding(.vertical, Spacing.xs)
    }
}

/// The dashed "create" row: `tone` colours it (accent for tags, add/green for
/// categories), `icon` is the leading glyph.
struct TaxonomyCreateRow: View {
    let label: String
    let icon: String
    let tone: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
            }
            .foregroundStyle(tone)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(tone.opacity(0.10))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm)
                        .strokeBorder(tone.opacity(0.5),
                                      style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
    }
}

/// A selectable category row: folder glyph, name, backing #tag, check.
struct TaxonomyCategoryRow: View {
    let category: Category
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let tag = category.tag ?? ""
        TaxonomySelectRow(selected: selected, tint: Tokens.accent, action: action) {
            Image(systemName: selected ? "folder.fill" : "folder")
                .font(.system(size: 11))
                .foregroundStyle(selected ? Tokens.accent : Tokens.muted)
            Text(category.name)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(Tokens.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("#\(tag)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Tokens.ultraDim)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(-1)
        }
    }
}

/// A selectable tag row: colour dot, #tag (in its colour when selected), check.
struct TaxonomyTagRow: View {
    let tag: String
    let color: Color
    let selected: Bool
    let action: () -> Void

    var body: some View {
        TaxonomySelectRow(selected: selected, tint: color, action: action) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text("#\(tag)")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(selected ? color : Tokens.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// The tappable row both of the above use: tinted fill + stroke when selected,
/// a trailing check, and the selected state exposed to VoiceOver.
private struct TaxonomySelectRow<Content: View>: View {
    let selected: Bool
    let tint: Color
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                content()
                Spacer()
                check
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(selected ? tint.opacity(0.12) : Color.clear)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm)
                        .stroke(selected ? tint.opacity(0.4) : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var check: some View {
        ZStack {
            Circle().fill(selected ? Tokens.accent : Color.clear)
            Circle().stroke(selected ? Color.clear : Tokens.borderStrong, lineWidth: 1)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Tokens.bg)
            }
        }
        .frame(width: 20, height: 20)
    }
}
