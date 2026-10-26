// ScriptImport — turn a script file (.md / .txt) into Compose's title + text.
// Pure, so it tests without files. Mirrors `voice-say render --title-from`: the first
// "# " heading is the title.

import Foundation

enum ScriptImport {
    /// The file's title and the text to speak. Title: the first "# " heading,
    /// else the first non-empty line. Text: the whole file with that heading's
    /// "# " marker dropped (the title is still read aloud, as the opening line).
    static func parse(_ raw: String) -> (title: String, text: String) {
        let unmarked = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw   // UTF-8 BOM
        let text = unmarked.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { $0.hasPrefix("# ") }) {
            let title = String(lines[i].dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines[i] = title
            return (title, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        return (String(first.trimmingCharacters(in: .whitespaces).prefix(120)),
                text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// File types Compose opens or accepts by drag and drop.
    static let extensions: Set<String> = ["md", "markdown", "txt"]
}
