// SectionLabel — the one section eyebrow ("TEXT", "UP NEXT (3)", …).
// ComposeScreen, RenderQueueView and HeaderView each hand-rolled this with
// slightly different sizes (9 vs 10pt) and ramps (dim vs ultraDim); this is
// the single shared form on the TypeScale.

import SwiftUI

struct SectionLabel: View {
    let text: String
    var count: Int? = nil
    var tone: Color = Tokens.dim

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(text)
                .font(TypeScale.eyebrow)
                .kerning(TypeScale.eyebrowKerning)
            if let count {
                Text("(\(count))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
        .foregroundStyle(tone)
    }
}
