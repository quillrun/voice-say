// Shared bookmark UI atoms — the pieces the expanded card (PlayerPanel) and
// the full-screen reader (TranscriptScreen) previously copy-pasted:
//   • BookmarksSectionHeader — the "BOOKMARKS (n) · view all" line; both
//     surfaces open the same RowBookmarksPopover, passed by the call site so
//     seek semantics stay local to each surface.
//   • bookmarkComposerChrome() — the warn-tinted background + border both
//     add-bookmark rows share. The row LAYOUTS stay per-surface on purpose:
//     the card uses a compact single-line field, the reader a growing
//     multi-line editor.

import SwiftUI

struct BookmarksSectionHeader<PopoverContent: View>: View {
    let count: Int
    @Binding var dialogOpen: Bool
    /// The reader keeps the header visible at count == 0 (dimmed, disabled);
    /// the card only renders the section when bookmarks exist.
    var disableWhenEmpty: Bool = false
    var arrowEdge: Edge = .bottom
    /// Row geometry + label kerning. Defaults are the card's (PlayerPanel)
    /// original values; the reader passes its own (firstTextBaseline,
    /// Spacing.xs, 0.6) so the shared atom renders each surface exactly as
    /// its pre-extraction hand-rolled header did.
    var alignment: VerticalAlignment = .center
    var spacing: CGFloat = Spacing.sm
    var kerning: CGFloat = 0.8
    @ViewBuilder let popoverContent: () -> PopoverContent

    var body: some View {
        let empty = disableWhenEmpty && count == 0
        HStack(alignment: alignment, spacing: spacing) {
            Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundStyle(Tokens.warn)
            Text("BOOKMARKS (\(count))")
                .font(.system(size: 11, weight: .bold))
                .kerning(kerning).foregroundStyle(Tokens.warn)
            Spacer(minLength: 0)
            Button(action: { dialogOpen = true }) {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "list.bullet").font(.system(size: 11))
                    Text("view all").font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(Tokens.dim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(empty)
            .opacity(empty ? 0.4 : 1.0)
            .help("Open the full bookmarks list")
            .popover(isPresented: $dialogOpen, arrowEdge: arrowEdge, content: popoverContent)
        }
    }
}

extension View {
    /// Warn-tinted composer chrome shared by both add-bookmark rows.
    func bookmarkComposerChrome() -> some View {
        self.padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
            .background(Tokens.warn.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(Tokens.warn.opacity(0.3)))
    }
}

struct BookmarkMarker: View {
    var body: some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(Tokens.warn)
                .frame(width: 8, height: 5)
                .offset(y: -2)
            Rectangle()
                .fill(Tokens.warn.opacity(0.8))
                .frame(width: 2)
        }
        .frame(width: 8)
    }
}

/// Flat bookmark pip — a warn-color tick used by the collapsed CommitRow bar.
/// (BookmarkMarker (above) is instantiated only by WaveformView
/// (Theme/WaveformView.swift); PlayerPanel and TranscriptScreen render bookmark
/// markers transitively through WaveformView, not directly. BookmarkPip's sole
/// caller is CommitRow.swift.)
struct BookmarkPip: View {
    var height: CGFloat = 10
    var body: some View {
        Rectangle().fill(Tokens.warn).frame(width: 3, height: height)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.closeSubpath()
        }
    }
}


