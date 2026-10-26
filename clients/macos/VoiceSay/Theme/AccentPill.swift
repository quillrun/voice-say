// AccentPill — THE solid filled-CTA recipe: accent background, bg-tone
// content, rounded-rect clip. Replaces six hand-rolled copies of the same
// .padding + .background(Tokens.accent) + .foregroundStyle(Tokens.bg) +
// .clipShape triad (save pills, Done buttons). Font stays at the call site —
// sizes legitimately differ per surface. The large Continue-Render CTA
// (PlayerPanel) is NOT this recipe: its accent fill spans a min-width frame
// and carries a glow shadow.

import SwiftUI

extension View {
    func accentPill(horizontal: CGFloat = Spacing.sm,
                    vertical: CGFloat = Spacing.xxs) -> some View {
        self.padding(.horizontal, horizontal).padding(.vertical, vertical)
            .background(Tokens.accent)
            .foregroundStyle(Tokens.bg)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
    }
}
