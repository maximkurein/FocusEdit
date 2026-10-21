import Foundation

/// Pasting a web address over selected text makes a Markdown link, as in Obsidian
/// and Notion: select a word, paste the address, get [word](address).
/// Mirrors `windows/src/links.ts`.
enum LinkPaste {

    /// The Markdown link for `selected` pasted over with `clipboard`, or nil when it is not that gesture.
    static func link(selected: String, clipboard: String) -> String? {
        let url = clipboard.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.range(of: #"^https?://[^\s<>]+$"#, options: [.regularExpression, .caseInsensitive]) != nil,
              !text.isEmpty, !selected.contains("\n"), !selected.contains("\r") else { return nil }
        // Brackets in the text would end the link early; parentheses in the address would end it too.
        let label = text.replacingOccurrences(of: #"([\[\]])"#, with: #"\\$1"#, options: .regularExpression)
        let target = url.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
        // Spaces that came with the selection stay outside the link.
        let lead = String(selected.prefix(while: { $0.isWhitespace }))
        let trail = String(String(selected.reversed()).prefix(while: { $0.isWhitespace }).reversed())
        return "\(lead)[\(label)](\(target))\(trail)"
    }
}
