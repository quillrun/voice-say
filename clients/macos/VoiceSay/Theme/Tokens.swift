// Design tokens: the app's single source of colour, spacing and type.

import SwiftUI

/// Hex values of the background and the text ramp — the single source for
/// the Tokens below and for the contrast test (TokenContrastTests).
enum RampHex {
    static let bg: UInt32       = 0x0a1320
    static let bg2: UInt32      = 0x0d1828
    static let text: UInt32     = 0xe8f0fa
    static let muted: UInt32    = 0xaebdd0
    static let dim: UInt32      = 0x9aabc3
    static let ultraDim: UInt32 = 0x8a9cb6
}

enum Tokens {
    static let bg          = Color(hex: RampHex.bg)
    static let bg2         = Color(hex: RampHex.bg2)
    static let surfActive  = Color(hex: 0x5fb3ff, alpha: 0.06)

    static let border       = Color(red: 150/255, green: 200/255, blue: 240/255).opacity(0.09)
    static let borderStrong = Color(red: 150/255, green: 200/255, blue: 240/255).opacity(0.18)

    // Ramp lifted toward white for legibility: every tier, ultraDim
    // included, clears 6:1 on bg (TokenContrastTests). Ordering preserved:
    // text > muted > dim > ultraDim.
    static let text     = Color(hex: RampHex.text)
    static let muted    = Color(hex: RampHex.muted)
    static let dim      = Color(hex: RampHex.dim)
    static let ultraDim = Color(hex: RampHex.ultraDim)

    static let accent     = Color(hex: 0x5fb3ff)
    static let accentSoft = Color(hex: 0x5fb3ff, alpha: 0.12)
    // Brand orange kept as a SPOT accent only — used by
    // the collapsed-row play visualizer; the app accent is blue again.
    static let brand      = Color(hex: 0xe82e15)
    static let add        = Color(hex: 0x6dd47e)
    static let del        = Color(hex: 0xff7e8e)
    static let warn       = Color(hex: 0xf5b557)

    /// Faint cool wash behind micro-pills (was a raw literal in BackendSelector).
    static let chipWash = Color(red: 150/255, green: 200/255, blue: 240/255).opacity(0.1)
    /// Dialog scrim — the dimmed backdrop behind centered sheets (voice picker,
    /// taxonomy editor). Was duplicated as a raw literal at each site.
    static let scrim = Color(red: 4/255, green: 8/255, blue: 16/255).opacity(0.55)

    /// Palette for in-row tag pills. Known labels get hand-picked colors;
    /// date-stamp tags (YYYY-MM-DD) share one muted hue so they don't
    /// flicker; everything else falls into a stable djb2-hashed slot in
    /// the catch-all palette so identical tag names always render in the
    /// same color across rows.
    static let tagPalette: [UInt32] = [
        0xff7b72,  // red
        0xffa657,  // orange
        0xe3c55a,  // yellow
        0xa5d65a,  // lime
        0x56d97b,  // green
        0x4fd1c5,  // teal
        0x58c4f0,  // cyan
        0x6ca8ff,  // blue
        0x9a8cff,  // indigo
        0xc792ea,  // violet
        0xec7fd8,  // magenta
        0xf27fa5,  // pink
    ]

    static func tagColor(_ tag: String) -> Color {
        let t = tag.lowercased()
        switch t {
        case "starred":   return Color(hex: 0xf5c542)  // gold
        case "completed": return Color(hex: 0x6dd47e)  // green
        case "news":      return Color(hex: 0x5fb3ff)  // blue
        case "briefing":  return Color(hex: 0xb89bff)  // violet
        case "hardware":  return Color(hex: 0xf5b557)  // amber
        case "learn":     return Color(hex: 0x5fdb9b)  // mint
        default: break
        }
        // YYYY-MM-DD date tags — muted teal so a row stamped with two
        // dates doesn't strobe.
        if t.count == 10,
           t[t.index(t.startIndex, offsetBy: 4)] == "-",
           t[t.index(t.startIndex, offsetBy: 7)] == "-" {
            return Color(hex: 0x7fb8c0)
        }
        // djb2 hash → palette slot. Deterministic so the same tag always
        // gets the same color. The 8 colors are tuned for the
        // `Tokens.bg` (#0a1320) backdrop: all sit at roughly equal
        // perceptual lightness so no single tag dominates, and each is
        // saturated enough to read against the dark blue without
        // washing out the way pastel hues do.
        var h: UInt32 = 5381
        for byte in t.utf8 { h = (h &* 33) &+ UInt32(byte) }
        // 12 hues, 30° apart around the wheel at even lightness (the
        // earlier 16-slot set had four near-identical oranges and two pinks, so
        // different tags read as the same colour).
        let palette: [UInt32] = Self.tagPalette
        return Color(hex: palette[Int(h % UInt32(palette.count))])
    }
}

/// Spacing scale — a 4-pt grid. Replaces the ad-hoc
/// mix of paddings (every integer 1–12 was in use, with no rhythm) that read
/// as uneven "misspacing". Views snap to the nearest step; the dominant
/// existing values map cleanly (4→xs, 8→sm, 12→md, 16→lg, 24→xl) and the
/// off-grid strays (5/6/7/9/10/11) round to the closest step.
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs:  CGFloat = 4
    static let sm:  CGFloat = 8
    static let md:  CGFloat = 12
    static let lg:  CGFloat = 16
    static let xl:  CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Corner-radius scale — matches the existing 6 / 10 / 14 usage so adopting
/// it is pixel-neutral.
enum Radius {
    static let sm:   CGFloat = 6
    static let md:   CGFloat = 10
    static let lg:   CGFloat = 14
}

/// Motion tokens — single source for durations and curves app-wide.
/// Three tiers:
///   quick    — hovers, micro state flips, chip/button toggles (fast, invisible).
///   standard — scrolls, screen changes, list transitions (snappy but readable).
///   springy  — card expand/collapse, panel reveals (physical feel, natural settle).
enum Motion {
    /// ~0.15 s easeOut — hover highlights, small state flips, chip/save-button
    /// opacity toggles. Anything so quick the user shouldn't notice the curve.
    static let quick:    Animation = .easeOut(duration: 0.15)
    /// ~0.25 s easeOut — screen pushes, list insertions/removals, most UI changes.
    /// The default when there's no spring reason to use springy.
    static let standard: Animation = .easeOut(duration: 0.25)
    /// Spring (response 0.3, damping 0.8) — card expand/collapse, panel reveals,
    /// any surface that "opens". Gives a physical settle without over-bounce.
    static let springy:  Animation = .spring(response: 0.3, dampingFraction: 0.8)
}

/// Typography scale — consolidates the ad-hoc per-view `.system(size:)`
/// literals (ComposeScreen alone used 7 sizes) onto a few named steps. Sizes
/// bias UPWARD when consolidating: no step sits below 10pt.
/// Reader body text: a proportional face at a size the user sets with
/// ⌘+ / ⌘− / ⌘0 (View menu), persisted under `key`.
enum ReaderType {
    static let key = "readerFontSize"
    static let defaultSize: Double = 16
    static let range: ClosedRange<Double> = 12...28
    static func font(_ size: Double) -> Font { .system(size: size) }
    static func lineSpacing(_ size: Double) -> CGFloat { CGFloat(size * 0.45) }
    static func step(_ size: Double, by delta: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, size + delta))
    }
}

/// Type sizes. Floor: no text under 11 pt.
enum TypeScale {
    /// Section eyebrows ("TEXT", "VOICE PROVIDER", "UP NEXT") — always
    /// paired with `eyebrowKerning`.
    static let eyebrow = Font.system(size: 11, weight: .semibold)
    static let eyebrowKerning: CGFloat = 0.8
    /// Secondary annotations (counts, hints, descriptors).
    static let micro = Font.system(size: 11, design: .monospaced)
    /// Editor/body text.
    static let body = Font.system(size: 13, design: .monospaced)
    /// Screen titles.
    static let title = Font.system(size: 14, weight: .bold)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xff) / 255.0
        let g = Double((hex >>  8) & 0xff) / 255.0
        let b = Double( hex        & 0xff) / 255.0
        self.init(red: r, green: g, blue: b, opacity: alpha)
    }
    /// Parse a CSS-style "#rrggbb" or "rrggbb" string. Falls back to
    /// Tokens.muted on malformed input so a daemon-supplied accent typo
    /// degrades to neutral instead of throwing.
    init(hex: String, fallback: Color = .gray) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self = fallback
            return
        }
        self.init(hex: v)
    }
}

extension VoiceTone {
    /// Avatar tint — mirrors the design's gender/style tinting
    /// (F → rose, M → sky, neutral → muted). Lives in Theme, not on the
    /// model: VoiceTone itself stays presentation-free.
    var tint: Color {
        switch self {
        case .female:  return Color(hex: 0xf280b0)
        case .male:    return Color(hex: 0x6ec5e8)
        case .neutral: return Tokens.muted
        }
    }
}

#if canImport(AppKit)
import AppKit

extension Color {
    /// This color as a lowercase "rrggbb" sRGB hex string, or nil if it can't be
    /// resolved to sRGB (e.g. a pattern/dynamic color). Used to persist a
    /// selection from the system color picker back into TagColorStore.
    var hexRGB: String? {
        guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        // Clamp: converting a wide-gamut (Display P3) pick to sRGB can land a
        // channel slightly outside [0,1]; without the clamp "%02x" of >255 or a
        // negative would yield a non-6-char string that normalizedHex rejects,
        // silently dropping the pick. Clamp = nearest in-gamut sRGB.
        let r = min(255, max(0, Int((c.redComponent   * 255).rounded())))
        let g = min(255, max(0, Int((c.greenComponent * 255).rounded())))
        let b = min(255, max(0, Int((c.blueComponent  * 255).rounded())))
        return String(format: "%02x%02x%02x", r, g, b)
    }
}
#endif
