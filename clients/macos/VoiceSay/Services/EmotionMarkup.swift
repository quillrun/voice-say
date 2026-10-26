// EmotionMarkup — the single canonical inline-markup stripper, shared by
// VoiceEntry.derivedTitle() and the row preview (displayText) and
// TranscriptScreen.wordCount (word-count strip). Backends with emotion tags keep them in the stored
// text, so any code deriving a title or counting words must strip them first.
//
// The angle arm is CONSTRAINED to tag-like tokens (<laugh>, </whisper>,
// <sigh/>) so prose comparison operators survive: a loose `<[^>]*>` ate
// "x < 5 and y > 3." down to "x 3." (regression covered by
// VoiceEntryTitleTests).
//
// COUPLED PAIR: this pattern must stay in sync with the daemon's word-count
// strip in `_sinks.py` — if one changes the markup vocabulary, change both.

import Foundation

enum EmotionMarkup {
    /// `[bracket]` emotion tags plus tag-like `<angle>` tokens (open, close,
    /// self-closing), but NOT arbitrary `<...>` spans, so prose like "a < b"
    /// is left intact.
    static let pattern = #"\[[^\]]*\]|</?[a-zA-Z][a-zA-Z0-9_]*\s*/?>"#

    /// Strip the markup, replacing each match with `replacement` (empty string
    /// for title derivation; a space for word-count, where a stripped tag must
    /// not glue two words together).
    static func stripped(_ text: String, replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    /// `voice-say render`'s control tokens — `<|emotion:x|>`, `<|style:x|>`,
    /// `<|prosody:pause|>`, `<|sfx:x|>` — which reach the stored text of
    /// some renders. Display-only: `pattern` above (and the daemon's word
    /// count it mirrors) is left as is, so word counts still include them.
    static let controlTokenPattern = #"<\|[^|<>]*\|>"#

    /// Text for a title or preview: control tokens become a space (a pause
    /// between two sentences must not glue them), the inline markup goes, and
    /// the doubled spaces either leaves behind collapse to one.
    static func displayText(_ text: String) -> String {
        stripped(text.replacingOccurrences(of: controlTokenPattern, with: " ", options: .regularExpression),
                 replacement: "")
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
    }
}
