// The text ramp stays readable: every tier clears 6:1 against the window
// background (WCAG AA is 4.5:1), 5.5:1 against the raised surface, and the
// order text > muted > dim > ultraDim holds.

import Foundation
import Testing
@testable import VoiceSay

@Suite("Token contrast")
struct TokenContrastTests {

    private func luminance(_ hex: UInt32) -> Double {
        func ch(_ v: UInt32) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch((hex >> 16) & 0xff) + 0.7152 * ch((hex >> 8) & 0xff) + 0.0722 * ch(hex & 0xff)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test("every text tier clears 6:1 on bg and 5.5:1 on bg2, in order")
    func ramp() {
        let tiers = [RampHex.text, RampHex.muted, RampHex.dim, RampHex.ultraDim]
        for t in tiers {
            #expect(contrast(t, RampHex.bg) >= 6.0, "0x\(String(t, radix: 16)) on bg")
            #expect(contrast(t, RampHex.bg2) >= 5.5, "0x\(String(t, radix: 16)) on bg2")
        }
        let ratios = tiers.map { contrast($0, RampHex.bg) }
        #expect(ratios == ratios.sorted(by: >))
    }

    /// `fg` at `alpha` composited over `bg`, channel by channel in sRGB (how
    /// SwiftUI's .opacity over a solid fill renders).
    private func over(_ fg: UInt32, _ alpha: Double, _ bg: UInt32) -> UInt32 {
        func mix(_ s: UInt32) -> UInt32 {
            let f = Double((fg >> s) & 0xff), b = Double((bg >> s) & 0xff)
            return UInt32((f * alpha + b * (1 - alpha)).rounded()) << s
        }
        return mix(16) | mix(8) | mix(0)
    }

    @Test("a selected sidebar row's accent label clears 4.5:1 on its 0.18 wash")
    func selectedSidebarRow() {
        let accent: UInt32 = 0x5fb3ff
        #expect(contrast(accent, over(accent, 0.18, RampHex.bg)) >= 4.5)
    }

    @Test("a tag chip's remove glyph, in full tag colour, clears 3:1 on the chip wash")
    func tagChipRemove() {
        for c in Tokens.tagPalette {
            for base in [RampHex.bg, RampHex.bg2] {
                #expect(contrast(c, over(c, 0.18, base)) >= 3.0, "0x\(String(c, radix: 16))")
            }
        }
    }
}

@Suite("Reader text size")
struct ReaderTypeTests {
    @Test("⌘+/− steps stay inside 12…28 pt")
    func step() {
        #expect(ReaderType.step(16, by: 1) == 17)
        #expect(ReaderType.step(28, by: 1) == 28)
        #expect(ReaderType.step(12, by: -1) == 12)
    }
}

@Suite("Tag palette")
struct TagPaletteTests {
    private func hue(_ hex: UInt32) -> Double {
        let r = Double((hex >> 16) & 0xff) / 255, g = Double((hex >> 8) & 0xff) / 255, b = Double(hex & 0xff) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        guard d > 0 else { return 0 }
        var h: Double
        if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
        h *= 60
        return h < 0 ? h + 360 : h
    }

    @Test("no two palette hues within 18° of each other")
    func distinct() {
        let hs = Tokens.tagPalette.map(hue).sorted()
        let gaps = zip(hs, hs.dropFirst()).map { $1 - $0 } + [360 - hs.last! + hs.first!]
        #expect(gaps.min()! >= 18, "hues \(hs)")
    }
}
