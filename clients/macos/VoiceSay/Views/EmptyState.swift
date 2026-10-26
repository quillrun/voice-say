// EmptyState — shown when filter + query yield no rows. The copy names the
// view that is empty: an empty New inbox with 200 renders behind it is not
// "No renders yet".

import SwiftUI

struct EmptyState: View {
    let query: String
    /// The New inbox is the active collection.
    var inNew: Bool = false
    /// The starred collection is the active one.
    var starred: Bool = false
    /// No renders exist at all (not just none in this view).
    var libraryEmpty: Bool = true

    /// Title and detail line for the current view. Pure, so it tests
    /// without a store.
    nonisolated static func copy(query: String, inNew: Bool, starred: Bool,
                                 libraryEmpty: Bool) -> (title: String, detail: String) {
        if !query.isEmpty { return ("No episodes match \"\(query)\"", "Try a different search term.") }
        if libraryEmpty { return ("No renders yet", "Press ⌘N to render your first text.") }
        if inNew { return ("Nothing new", "Renders you haven't opened show here.") }
        if starred { return ("No starred renders", "Star a render to keep it here.") }
        return ("Nothing in this view", "Renders in this collection show here.")
    }

    var body: some View {
        let text = Self.copy(query: query, inNew: inNew, starred: starred, libraryEmpty: libraryEmpty)
        return VStack(spacing: Spacing.lg) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 22))
                .foregroundStyle(Tokens.dim)
                .frame(width: 48, height: 48)
                .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(
                    Tokens.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                // Decoration: VoiceOver read the symbol's name ("Divide")
                // (hig/accessibility.md › Vision).
                .accessibilityHidden(true)
            VStack(spacing: Spacing.xs) {
                Text(text.title)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Tokens.muted)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                Text(text.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Tokens.dim)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.xxl)
    }
}

