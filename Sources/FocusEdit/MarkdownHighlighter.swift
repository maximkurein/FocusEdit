import AppKit

/// Basic Markdown line tokenizer: headings, blockquote, list markers, and the
/// inline emphasis/code/link spans.
struct MarkdownHighlighter: SyntaxHighlighter {
    private static let heading  = RegexUtil.regex(#"^\s{0,3}#{1,6}\s.*$"#)
    private static let quote    = RegexUtil.regex(#"^\s{0,3}>.*$"#)
    private static let listMark = RegexUtil.regex(#"^(\s*)([-+*]|\d+\.)(\s)"#)
    private static let strong   = RegexUtil.regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let emphasis = RegexUtil.regex(#"(?<![\*_])([\*_])(?=\S)([^\*_]+?)(?<=\S)\1(?![\*_])"#)
    private static let code     = RegexUtil.regex(#"`[^`]+`"#)
    private static let link     = RegexUtil.regex(#"\[[^\]]+\]\([^)]+\)"#)
    // CriticMarkup
    private static let cmAdd    = RegexUtil.regex(#"\{\+\+.+?\+\+\}"#)
    private static let cmDel    = RegexUtil.regex(#"\{--.+?--\}"#)
    private static let cmSub    = RegexUtil.regex(#"\{~~.+?~>.+?~~\}"#)
    private static let cmHigh   = RegexUtil.regex(#"\{==.+?==\}"#)
    private static let cmCom    = RegexUtil.regex(#"\{>>.+?<<\}"#)

    func tokens(forLine line: String) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        let whole = NSRange(line.startIndex..., in: line)

        // Block-level (whole line / marker)
        if !RegexUtil.matches(Self.heading, in: line).isEmpty {
            tokens.append(SyntaxToken(range: whole, role: .heading))
        } else if !RegexUtil.matches(Self.quote, in: line).isEmpty {
            tokens.append(SyntaxToken(range: whole, role: .quote))
        } else if let m = RegexUtil.matches(Self.listMark, in: line).first, m.numberOfRanges > 2 {
            tokens.append(SyntaxToken(range: m.range(at: 2), role: .listMarker))
        }

        // Inline spans (applied on top; fonts combine, colors layer)
        for m in RegexUtil.matches(Self.code, in: line) {
            tokens.append(SyntaxToken(range: m.range, role: .code))
        }
        for m in RegexUtil.matches(Self.link, in: line) {
            tokens.append(SyntaxToken(range: m.range, role: .link))
        }
        for m in RegexUtil.matches(Self.strong, in: line) {
            tokens.append(SyntaxToken(range: m.range, role: .strong))
        }
        for m in RegexUtil.matches(Self.emphasis, in: line) {
            tokens.append(SyntaxToken(range: m.range, role: .emphasis))
        }
        for m in RegexUtil.matches(Self.cmAdd, in: line) {
            tokens.append(SyntaxToken(range: m.range, role: .cmAddition))
        }
        for m in RegexUtil.matches(Self.cmDel, in: line) {
            tokens.append(SyntaxToken(range: m.range, role: .cmDeletion))
        }
        for m in RegexUtil.matches(Self.cmSub, in: line) {
            tokens.append(SyntaxToken(range: m.range, role: .cmSubstitution))
        }
        for m in RegexUtil.matches(Self.cmHigh, in: line) {
            tokens.append(SyntaxToken(range: m.range, role: .cmHighlight))
        }
        for m in RegexUtil.matches(Self.cmCom, in: line) {
            tokens.append(SyntaxToken(range: m.range, role: .cmComment))
        }
        return tokens
    }
}
