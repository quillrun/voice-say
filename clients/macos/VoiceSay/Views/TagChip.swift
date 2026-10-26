// TagChip + TagsAndCategoryButton — the shared tag affordances.
//
// TagChip replaces the hand-rolled `#tag` pill that used to live in four
// places (PlayerPanel.appliedTagChip, TranscriptScreen.tagPill,
// ComposeScreen.selectedTagChip, and the Compose "reuse" chips), each with its
// own radius / padding / opacity. One recipe now: color from Tokens.tagColor,
// symmetric horizontal padding, Radius.md. Variants:
//   .display                — static colored pill
//   onRemove:               — adds a trailing × button
//   onTap:                  — whole-#text taps (e.g. filter / add)

import SwiftUI

struct TagChip: View {
    @Environment(TagColorStore.self) private var tagColors: TagColorStore?

    let tag: String
    /// Whole-chip tap on the `#tag` text (filter by it, add it, …). nil = inert.
    var onTap: (() -> Void)? = nil
    /// Trailing × remove button. nil = not removable.
    var onRemove: (() -> Void)? = nil

    /// Resolved color: custom override from TagColorStore when available, else
    /// the auto-hash from Tokens.tagColor. Optional environment so TagChip still
    /// compiles in previews/tests that don't inject the store.
    private var c: Color { tagColors?.color(for: tag) ?? Tokens.tagColor(tag) }

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            label
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                        .contentShape(Rectangle())
                }
                // Full tag colour: at 0.6 the glyph fell under the 3:1 minimum
                // for a control on its wash (hig/accessibility.md › Vision).
                .buttonStyle(.plain).help("Remove tag")
                .accessibilityLabel("Remove tag \(tag)")
            }
        }
        .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xxs)
        .background(c.opacity(0.18))
        // Capsule — micro-pills (tag chips, the compose classification pill,
        // pin badges) share one shape app-wide; Radius.md on an ~18pt chip
        // read as a third, in-between shape.
        .overlay(Capsule().strokeBorder(c.opacity(0.5), lineWidth: 1))
        .foregroundStyle(c)
        .clipShape(Capsule())
    }

    @ViewBuilder private var label: some View {
        let text = Text("#\(tag)").font(.system(size: 11, design: .monospaced))
        if let onTap {
            Button(action: onTap) { text.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            text
        }
    }
}

/// The "Tags & Category" trigger button — one outlined pill used by Compose and
/// the expanded player, both of which open the same TagPicker. Was two
/// inline hand-rolled copies differing only in stroke tone.
struct TagsAndCategoryButton: View {
    var action: () -> Void
    var tone: Color = Tokens.accent

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "tag").font(.system(size: 11))
                Text("Tags & Category").font(.system(size: 11, weight: .semibold, design: .monospaced))
            }
            .foregroundStyle(Tokens.accent)
            .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.xs)
            .overlay(RoundedRectangle(cornerRadius: Radius.sm).stroke(tone.opacity(0.45)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Pick tags & categories from the existing vocabulary")
    }
}

/// One applied tag chip. EVERY tag shows its accurate per-tag colour
/// (Tokens.tagColor) — client (user) tags additionally carry a remove ×; server
/// / render-time tags are read-only (no ×) but still tap-to-filter and keep
/// their colour. The single source for the expanded card (PlayerPanel) and the
/// transcript reader — was copy-pasted as appliedTagChip / inlineTagChip.
struct AppliedTagChip: View {
    @Environment(HistoryStore.self) var store
    let entry: VoiceEntry
    let tag: String
    /// When false the chip is display-only (no remove ×) even for client tags —
    /// used in the transcript reader, where tags are edited via the tag window,
    /// not inline.
    var removable: Bool = true

    var body: some View {
        let isClient = store.userTags(entry).contains(tag)
        // Accurate colour for all; server tags stay read-only via no ×.
        TagChip(tag: tag,
                onTap: { store.toggleTagFilter(tag) },
                onRemove: (removable && isClient) ? { store.removeTag(entry, tag) } : nil)
    }
}
