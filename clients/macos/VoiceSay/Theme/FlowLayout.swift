// FlowLayout — a simple left-to-right wrapping container (macOS 13+ Layout).
// Tag rows used to be HStacks that overflowed the row/sidebar width when a
// render carried many tags; this wraps them onto new lines instead.

import SwiftUI

struct FlowLayout: Layout {
    var spacing: CGFloat = Spacing.sm
    var lineSpacing: CGFloat = Spacing.sm

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxWidth, x > 0 {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += sz.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, sz.height)
        }
        let w = maxWidth == .infinity ? widest : min(maxWidth, widest)
        return CGSize(width: max(0, w), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += lineHeight + lineSpacing; lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineHeight = max(lineHeight, sz.height)
        }
    }
}
