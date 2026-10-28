import Foundation

/// Live Markdown: the marks of formatting (#, **, *, ~~, `, [ ](…), <…>) are
/// hidden while the cursor is somewhere else and appear when it comes close,
/// so the text reads almost like the finished page and the file stays plain
/// Markdown. Headings get their size wherever the cursor is, so lines don't jump.
/// Mirrors `windows/src/live.ts`; lists, quotes, code blocks, tables, rules and
/// setext underlines are left alone.
struct LiveElement {
    enum Kind: Equatable {
        case inline
        /// `~~text~~`: drawn struck through.
        case strikethrough
        /// A heading line (ATX or setext) of this level.
        case heading(Int)
        /// An image: `caption` is its description, shown in italics.
        case image(caption: NSRange)
    }
    /// What the cursor has to touch for the marks to show.
    let range: NSRange
    /// The marks hidden while it doesn't.
    let marks: [NSRange]
    let kind: Kind

    fileprivate func offset(by delta: Int) -> LiveElement {
        func move(_ r: NSRange) -> NSRange { NSRange(location: r.location + delta, length: r.length) }
        let k: Kind
        if case .image(let caption) = kind { k = .image(caption: move(caption)) } else { k = kind }
        return LiveElement(range: move(range), marks: marks.map(move), kind: k)
    }
}

/// Finds the elements of a document, line by line, memoising lines by their text.
final class LiveMarkdown {
    private var cache: [String: [LiveElement]] = [:]

    /// Every element of `text`, outside fenced code blocks.
    func elements(in text: NSString) -> [LiveElement] {
        var out: [LiveElement] = []
        var fence: Character?
        var previous: (text: String, range: NSRange)?
        var location = 0
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let content = NSRange(location: lineRange.location, length: (line as NSString).length)
            defer { previous = (line, content) }

            if let marker = Self.fenceMarker(line) {
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                continue
            }
            if fence != nil { continue }

            // Setext: the text line above `===` / `---` is a heading (the underline stays).
            if let prev = previous, !prev.text.trimmingCharacters(in: .whitespaces).isEmpty,
               let level = Self.setextLevel(line), !Self.isBlockStart(prev.text),
               Self.fenceMarker(prev.text) == nil {
                out.append(LiveElement(range: prev.range, marks: [], kind: .heading(level)))
                continue
            }

            let relative: [LiveElement]
            if let cached = cache[line] {
                relative = cached
            } else {
                relative = Self.lineElements(line)
                if cache.count < 5000 { cache[line] = relative }
            }
            out += relative.map { $0.offset(by: lineRange.location) }
        }
        return out
    }

    /// The marks to hide while the selection is `selection`.
    static func hidden(_ elements: [LiveElement], selection: [NSRange]) -> IndexSet {
        var set = IndexSet()
        for e in elements where !e.marks.isEmpty {
            let touched = selection.contains { $0.location <= NSMaxRange(e.range) && NSMaxRange($0) >= e.range.location }
            if touched { continue }
            for m in e.marks where m.length > 0 { set.insert(integersIn: m.location..<NSMaxRange(m)) }
        }
        return set
    }

    // MARK: One line

    private static func regex(_ p: String) -> NSRegularExpression? { RegexUtil.regex(p) }
    private static let atx = regex(#"^ {0,3}(#{1,6})(?:([ \t]+)(.*?))?(?:[ \t]+(#+))?[ \t]*$"#)
    private static let code = regex(#"(`+)(?:.+?)(?<!`)\1(?!`)"#)
    private static let autolink = regex(#"<(?:https?|mailto):[^\s<>]+>"#)
    private static let image = regex(#"!\[([^\[\]]*)\]\([^()\s]*(?:\s+"[^"]*")?\)"#)
    private static let link = regex(#"(?<!!)\[((?:[^\[\]]|\[[^\[\]]*\])+)\](?:\([^()\s]*(?:\([^()\s]*\))?[^()\s]*(?:\s+"[^"]*")?\)|\[[^\[\]]*\])"#)
    private static let strong = regex(#"(?<![*_\\])(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let emStar = regex(#"(?<![*\w\\])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])"#)
    private static let emUnder = regex(#"(?<![_\w\\])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#)
    private static let strike = regex(#"(?<!~)~~(?=\S)(.+?)(?<=\S)~~(?!~)"#)

    static func lineElements(_ line: String) -> [LiveElement] {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        var out: [LiveElement] = []
        var taken: [NSRange] = []   // code spans and link targets: nothing else inside them
        func free(_ r: NSRange) -> Bool { !taken.contains { NSIntersectionRange($0, r).length > 0 } }
        func matches(_ re: NSRegularExpression?) -> [NSTextCheckingResult] { re?.matches(in: line, range: all) ?? [] }

        if let m = atx?.firstMatch(in: line, range: all) {
            var marks = [NSRange(location: m.range(at: 1).location,
                                 length: m.range(at: 1).length + (m.range(at: 2).location == NSNotFound ? 0 : 1))]
            if m.range(at: 4).location != NSNotFound { marks.append(m.range(at: 4)) }
            out.append(LiveElement(range: all, marks: marks, kind: .heading(m.range(at: 1).length)))
        }
        for m in matches(code) {
            let tick = m.range(at: 1).length
            out.append(LiveElement(range: m.range, marks: [
                NSRange(location: m.range.location, length: tick),
                NSRange(location: NSMaxRange(m.range) - tick, length: tick),
            ], kind: .inline))
            taken.append(m.range)
        }
        for m in matches(autolink) where free(m.range) {
            out.append(LiveElement(range: m.range, marks: [
                NSRange(location: m.range.location, length: 1),
                NSRange(location: NSMaxRange(m.range) - 1, length: 1),
            ], kind: .inline))
            taken.append(m.range)
        }
        for m in matches(image) where free(m.range) {
            let caption = m.range(at: 1)
            out.append(LiveElement(range: m.range, marks: [
                NSRange(location: m.range.location, length: 2),
                NSRange(location: NSMaxRange(caption), length: NSMaxRange(m.range) - NSMaxRange(caption)),
            ], kind: .image(caption: caption)))
            taken.append(m.range)
        }
        for m in matches(link) where free(m.range) {
            let text = m.range(at: 1)
            out.append(LiveElement(range: m.range, marks: [
                NSRange(location: m.range.location, length: 1),
                NSRange(location: NSMaxRange(text), length: NSMaxRange(m.range) - NSMaxRange(text)),
            ], kind: .inline))
            // The link text can hold emphasis; its target can't.
            taken.append(NSRange(location: NSMaxRange(text), length: NSMaxRange(m.range) - NSMaxRange(text)))
        }
        for (re, width) in [(strong, 2), (strike, 2), (emStar, 1), (emUnder, 1)] {
            for m in matches(re) where free(m.range) {
                out.append(LiveElement(range: m.range, marks: [
                    NSRange(location: m.range.location, length: width),
                    NSRange(location: NSMaxRange(m.range) - width, length: width),
                ], kind: re === strike ? .strikethrough : .inline))
            }
        }
        return out
    }

    // MARK: Blocks

    /// "`" or "~" for a fence line (three or more, up to three spaces in).
    /// Also used by `MarkdownHighlighter`, so both agree on where code blocks are.
    static func fenceMarker(_ line: String) -> Character? {
        let t = line.drop(while: { $0 == " " })
        guard line.count - t.count <= 3, let c = t.first, c == "`" || c == "~",
              t.prefix(while: { $0 == c }).count >= 3 else { return nil }
        return c
    }

    private static func setextLevel(_ line: String) -> Int? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard line.prefix(while: { $0 == " " }).count <= 3, !t.isEmpty else { return nil }
        if t.allSatisfy({ $0 == "=" }) { return 1 }
        if t.count >= 2, t.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    /// Lines that can't be the text of a setext heading.
    private static func isBlockStart(_ line: String) -> Bool {
        line.range(of: #"^\s*(?:(?:[-*+]|\d+[.)])\s|>|#{1,6}(?:\s|$)|(?:[-*_]\s*){3,}$)"#,
                   options: .regularExpression) != nil
    }
}
