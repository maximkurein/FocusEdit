import AppKit

/// Semantic role of a highlighted span. Concrete colors/traits are resolved at
/// render time from the active theme, so theme switches need no re-tokenising.
enum SyntaxRole {
    case heading          // # headings, Fountain scene headings/sections
    case strong           // **bold**
    case emphasis         // *italic*
    case quote            // > blockquote, notes, synopsis
    case listMarker       // -, *, +, 1.
    case code             // `code`
    case link             // [text](url)
    case character        // Fountain character cue
    case parenthetical    // Fountain (parenthetical)
    // CriticMarkup
    case cmAddition       // {++ ++}
    case cmDeletion       // {-- --}
    case cmSubstitution   // {~~ ~> ~~}
    case cmHighlight      // {== ==}
    case cmComment        // {>> <<}

    struct Style { let bold: Bool; let italic: Bool; let mono: Bool }

    var style: Style {
        switch self {
        case .heading, .strong, .character:
            return Style(bold: true, italic: false, mono: false)
        case .emphasis, .parenthetical, .cmComment:
            return Style(bold: false, italic: true, mono: false)
        case .code:
            return Style(bold: false, italic: false, mono: true)
        default:
            return Style(bold: false, italic: false, mono: false)
        }
    }

    /// Foreground color, or nil to inherit the base/focus color.
    func color(active: NSColor, dim: NSColor, accent: NSColor) -> NSColor? {
        switch self {
        case .heading, .character: return active
        case .quote, .listMarker, .code, .parenthetical: return dim
        case .link: return accent
        case .strong, .emphasis: return nil
        case .cmAddition, .cmSubstitution:
            return NSColor(srgbRed: 0.25, green: 0.62, blue: 0.20, alpha: 1)  // green
        case .cmDeletion:
            return NSColor(srgbRed: 0.80, green: 0.22, blue: 0.22, alpha: 1)  // red
        case .cmHighlight:
            return NSColor(srgbRed: 0.80, green: 0.55, blue: 0.00, alpha: 1)  // amber
        case .cmComment:
            return NSColor(srgbRed: 0.20, green: 0.45, blue: 0.90, alpha: 1)  // blue
        }
    }
}

struct SyntaxToken {
    var range: NSRange          // absolute (whole document) after the engine offsets it
    let role: SyntaxRole
}

/// A per-line tokenizer. Lines are produced by `SyntaxEngine`, so block rules
/// (headings, quotes, list markers) are naturally line-scoped.
protocol SyntaxHighlighter {
    /// Tokens with ranges relative to the start of `line`.
    func tokens(forLine line: String) -> [SyntaxToken]
}

/// Drives a `SyntaxHighlighter` incrementally: it tokenises per paragraph (line)
/// and memoises results by the line's text, so an edit only re-parses the lines
/// whose text actually changed; unchanged lines are reused and merely re-offset.
final class SyntaxEngine {
    private let highlighter: SyntaxHighlighter
    private var cache: [String: [SyntaxToken]] = [:]

    init(highlighter: SyntaxHighlighter) {
        self.highlighter = highlighter
    }

    func tokens(for text: NSString) -> [SyntaxToken] {
        var out: [SyntaxToken] = []
        let full = NSRange(location: 0, length: text.length)
        text.enumerateSubstrings(in: full, options: .byParagraphs) { substring, subRange, _, _ in
            guard let line = substring else { return }
            let relative: [SyntaxToken]
            if let cached = self.cache[line] {
                relative = cached
            } else {
                relative = self.highlighter.tokens(forLine: line)
                if self.cache.count < 5000 { self.cache[line] = relative }
            }
            for tok in relative {
                out.append(SyntaxToken(
                    range: NSRange(location: subRange.location + tok.range.location,
                                   length: tok.range.length),
                    role: tok.role))
            }
        }
        return out
    }
}

/// Small helper for regex-based line tokenizers.
enum RegexUtil {
    static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }
    static func matches(_ re: NSRegularExpression?, in line: String) -> [NSTextCheckingResult] {
        guard let re else { return [] }
        let full = NSRange(line.startIndex..., in: line)
        return re.matches(in: line, range: full)
    }
}
