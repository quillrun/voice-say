// TimeReadout — THE "elapsed / total · <n> left" recipe. Shared by the
// streaming card, the inline PlayerPanel, and CommitRow's collapsed stat
// line (each previously hand-rolled it). The full-screen reader's live-read
// time block is deliberately styled differently (bigger, "−mm:ss"), so it
// does NOT use this.

import SwiftUI

struct TimeReadout: View {
    let current: Int
    let total: Int
    var showRemaining: Bool = false
    /// Elapsed-time tone. The collapsed CommitRow stat line brightens it to
    /// Tokens.text so "played" pops against the row; default matches the
    /// player/streaming surfaces.
    var playedColor: Color = Tokens.muted
    var font: Font = .system(size: 11.5, design: .monospaced)
    /// Separator ("/") tone + inter-token gap. Defaults match the player/
    /// streaming surfaces; the collapsed CommitRow stat keeps its original
    /// looser rhythm (dim separator, Spacing.sm gaps).
    var separatorColor: Color = Tokens.ultraDim
    var spacing: CGFloat = Spacing.xs

    var body: some View {
        let remaining = max(0, total - current)
        HStack(spacing: spacing) {
            Text(fmtDuration(current)).foregroundStyle(playedColor)
            Text("/").foregroundStyle(separatorColor)
            Text(fmtDuration(total)).foregroundStyle(Tokens.dim)
            if showRemaining && remaining > 0 {
                Text("·").foregroundStyle(Tokens.ultraDim)
                Text("\(fmtDuration(remaining)) left").foregroundStyle(Tokens.dim)
            }
        }
        .font(font)
        .fixedSize()
    }
}
