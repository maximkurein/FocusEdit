import AppKit

/// Basic Fountain screenplay line tokenizer. Block elements are line-scoped,
/// which fits Fountain's mostly line-oriented grammar.
struct FountainHighlighter: SyntaxHighlighter {
    private static let sceneHeading = RegexUtil.regex(
        #"^(INT|EXT|EST|INT\.?/EXT|I/E)[\. ].*$"#, [.caseInsensitive])
    private static let transition = RegexUtil.regex(#"^.*TO:$"#)
    private static let characterCue = RegexUtil.regex(#"^[\p{Lu}][\p{Lu}0-9 \.\(\)'’\-]*$"#)

    func tokens(forLine line: String) -> [SyntaxToken] {
        let whole = NSRange(line.startIndex..., in: line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        // Forced markers
        if trimmed.hasPrefix("#") {                         // section
            return [SyntaxToken(range: whole, role: .heading)]
        }
        if trimmed.hasPrefix("=") {                         // synopsis
            return [SyntaxToken(range: whole, role: .quote)]
        }
        if trimmed.hasPrefix("~") {                         // lyric
            return [SyntaxToken(range: whole, role: .emphasis)]
        }
        if trimmed.hasPrefix("[[") {                        // note
            return [SyntaxToken(range: whole, role: .quote)]
        }
        if trimmed.hasPrefix(".") && !trimmed.hasPrefix("..") {   // forced scene heading
            return [SyntaxToken(range: whole, role: .heading)]
        }
        if trimmed.hasPrefix(">") {                         // forced transition
            return [SyntaxToken(range: whole, role: .heading)]
        }

        // Scene headings / transitions / parentheticals / characters
        if !RegexUtil.matches(Self.sceneHeading, in: line).isEmpty {
            return [SyntaxToken(range: whole, role: .heading)]
        }
        if !RegexUtil.matches(Self.transition, in: line).isEmpty {
            return [SyntaxToken(range: whole, role: .heading)]
        }
        if trimmed.hasPrefix("(") && trimmed.hasSuffix(")") {
            return [SyntaxToken(range: whole, role: .parenthetical)]
        }
        if !RegexUtil.matches(Self.characterCue, in: line).isEmpty, trimmed.count > 1 {
            return [SyntaxToken(range: whole, role: .character)]
        }
        return []
    }
}
