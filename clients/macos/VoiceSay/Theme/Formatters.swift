// Display formatters for the views layer. Moved out of ContentView so
// PlayerPanel, popovers, and Sidebar can discover them without
// scrolling through a 1300-line root file.
//
// Single-purpose, pure functions — no SwiftUI dependency, no state.

import Foundation

/// Tolerant ISO8601 parse — fractional-seconds first (daemon output), then
/// plain integer-second (legacy rows), falling back to now. Shared by the
/// relative + absolute date formatters below.
private func parseTS(_ tsString: String) -> Date {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return parser.date(from: tsString)
        ?? ISO8601DateFormatter().date(from: tsString)
        ?? Date()
}

/// Display formatters built once: fmtRel/fmtDate run per history row per
/// render. DateFormatter is Sendable and thread-safe once configured.
/// (ISO8601DateFormatter is not Sendable, so parseTS keeps building its own.)
private enum Fmt {
    static func date(_ format: String) -> DateFormatter {
        let f = DateFormatter(); f.dateFormat = format; return f
    }
    static let dayMonth = date("d MMM")
    static let dayMonthYear = date("d MMM yyyy")
    static let dateTime = date("d MMM yyyy, HH:mm")
}

/// "12 seconds ago" / "yesterday" / "3 weeks ago" / "12 Mar". Tolerant
/// of both ISO8601-with-fractional-seconds (daemon output) and the
/// integer-second variant in legacy rows.
func fmtRel(_ tsString: String) -> String {
    let date = parseTS(tsString)
    let s = max(0, Date().timeIntervalSince(date))
    if s < 60 { let n = Int(s); return "\(n) second\(n == 1 ? "" : "s") ago" }
    if s < 3600 { let n = Int(s / 60); return "\(n) minute\(n == 1 ? "" : "s") ago" }
    if s < 86400 { let n = Int(s / 3600); return "\(n) hour\(n == 1 ? "" : "s") ago" }
    if s < 86400 * 2 { return "yesterday" }
    if s < 86400 * 7 { let n = Int(s / 86400); return "\(n) day\(n == 1 ? "" : "s") ago" }
    if s < 86400 * 30 {
        let w = Int(s / (86400 * 7))
        return "\(w) week\(w > 1 ? "s" : "") ago"
    }
    // Include the year once the render falls in a prior calendar year, so a
    // "12 Mar" never reads ambiguously across years.
    let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
    return (sameYear ? Fmt.dayMonth : Fmt.dayMonthYear).string(from: date)
}

/// "12 Mar 2026, 14:30" — absolute creation date+time for a render. Tolerant
/// of fractional-second and integer-second ISO8601 (matches fmtRel).
func fmtDate(_ tsString: String) -> String {
    Fmt.dateTime.string(from: parseTS(tsString))
}

/// "1:23" / "1:02:03" — minutes:seconds (and hours when >= 1h).
func fmtDuration(_ s: Int) -> String {
    let s = max(0, s)
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
    return String(format: "%d:%02d", m, sec)
}

/// "1:23" — a bookmark's fractional position rendered against `totalSeconds`.
/// Shared by every inline bookmark timestamp + the tooltip below.
func bookmarkTimestamp(_ bm: Bookmark, totalSeconds: Int) -> String {
    // Round (not truncate) so the saved/re-listed timestamp matches the rounded
    // preview shown while setting the bookmark — no "1:30 → 1:29" flip on save.
    fmtDuration(Int((bm.position * Double(totalSeconds)).rounded()))
}

/// Bookmark tooltip — "Bookmark at <ts>" (no note) or "<ts> — <note>", where
/// <ts> is the bookmark's fractional position rendered against `totalSeconds`.
/// Shared by the player panel, the row popover, and the reader.
func bookmarkHelp(_ bm: Bookmark, totalSeconds: Int) -> String {
    let ts = bookmarkTimestamp(bm, totalSeconds: totalSeconds)
    return bm.note.isEmpty ? "Bookmark at \(ts)" : "\(ts) — \(bm.note)"
}

/// "12m" / "1h25m" — for header totals where compactness wins.
func fmtCompactTime(_ s: Int) -> String {
    let s = max(0, s)
    let h = s / 3600
    let m = (s % 3600) / 60
    return h > 0 ? "\(h)h\(m)m" : "\(m)m"
}

/// Size split into (number, unit) so the unit can render adjacent in its own
/// (dim) colour — e.g. "915.4" + "MB".
func fmtCompactSizeParts(_ b: Int) -> (value: String, unit: String) {
    // Cut over at the POST-rounding threshold so %.1f carry promotes the unit
    // (999_999_999 B → "1.0 GB", not "1000.0 MB").
    if b >= 999_950_000 { return (String(format: "%.1f", Double(b) / 1_000_000_000), "GB") }
    if b >= 999_950     { return (String(format: "%.1f", Double(b) / 1_000_000), "MB") }
    if b >= 1_000         { return ("\(b / 1000)", "KB") }
    return ("\(b)", "B")
}

/// Character counts: the FULL count (locale separators) up to 8 digits, then
/// abbreviated ("123M") beyond — so the real number shows for any realistic
/// library size instead of a lossy "1.6M".
func fmtCompactChars(_ n: Int) -> String {
    if n < 100_000_000 { return n.formatted() }
    return "\(n / 1_000_000)M"
}

/// "1×" / "1.25×" — playback speed.
func fmtSpeed(_ n: Double) -> String {
    if n == floor(n) { return "\(Int(n))×" }
    // Up to 2 decimals with trailing zeros stripped: 1.5 → "1.5×", 1.25 → "1.25×".
    var s = String(format: "%.2f", n)
    while s.hasSuffix("0") { s.removeLast() }
    if s.hasSuffix(".") { s.removeLast() }
    return "\(s)×"
}

extension Int {
    /// Grouped integer formatter — always "1,234" (comma grouping), in the
    /// few places (transcript char/word counts) where the separator improves
    /// readability. Grouping is pinned to a literal comma rather than left
    /// locale-aware: on a European locale (e.g. ro_RO) `.decimal` uses "."
    /// as the thousands separator, so 6315 rendered as "6.315" and read as a
    /// decimal — colliding with the compact "776.3M"/"1.4M" formatters above.
    func formatted() -> String {
        Int.grouped.string(from: NSNumber(value: self)) ?? "\(self)"
    }

    private static let grouped: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.usesGroupingSeparator = true
        nf.groupingSeparator = ","
        return nf
    }()
}
