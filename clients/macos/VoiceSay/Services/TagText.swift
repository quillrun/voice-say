// TagText — the single canonical tag/category-tag sanitizer, shared by the
// stores (DeclaredTagsStore, CategoryStore), the dialogs (TagPicker,
// TaxonomyManager), and Compose. Having ONE function means a name typed
// in any field maps to the same canonical tag, so dedupe checks and what gets
// stored never disagree (e.g. "News!!!", "news", and " News " all collapse to
// "news" and won't create a duplicate).
//
// A superset of the previous trim→lower→hyphenate rule (so existing clean tags
// are unchanged): also strips characters outside [a-z0-9-], collapses repeated
// hyphens, and trims leading/trailing hyphens. Empty result = invalid input.

import Foundation

enum TagText {
    static func sanitized(_ raw: String) -> String {
        var s = raw.lowercased()
        // Separators → hyphen.
        for sep in [" ", "_", "\t", "\n"] {
            s = s.replacingOccurrences(of: sep, with: "-")
        }
        // Keep only lowercase alphanumerics + hyphen.
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        s = String(s.filter { allowed.contains($0) })
        // Collapse repeated hyphens.
        while s.contains("--") { s = s.replacingOccurrences(of: "--", with: "-") }
        // Trim leading/trailing hyphens.
        while s.hasPrefix("-") { s.removeFirst() }
        while s.hasSuffix("-") { s.removeLast() }
        return s
    }
}
