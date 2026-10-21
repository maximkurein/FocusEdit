import AppKit

/// What kind of document is being edited — drives highlighting, outline
/// extraction and whether HTML preview/export is offered.
enum DocumentKind {
    case plain, markdown, fountain

    init(fileExtension ext: String) {
        switch ext.lowercased() {
        // RTF opens as Markdown (RTFMarkdown converts both ways).
        case "md", "markdown", "mdown", "mkd", "mdwn", "rtf": self = .markdown
        case "fountain":                                self = .fountain
        default:                                        self = .plain
        }
    }

    func makeHighlighter() -> SyntaxHighlighter? {
        switch self {
        case .markdown: return MarkdownHighlighter()
        case .fountain: return FountainHighlighter()
        case .plain:    return nil
        }
    }

    var supportsHTML: Bool { self == .markdown }
}

/// One entry in the document outline.
struct OutlineItem {
    let title: String
    let level: Int
    let range: NSRange   // the heading line, for jump-to
    let line: Int        // 1-based
}

/// Extracts headings/scene-headings for the outline sidebar. Mirrors
/// `windows/src/outline.ts`: Markdown ATX and setext headings outside code fences
/// and YAML front matter (also in plain text), or Fountain sections and scene
/// headings (plus Mac's forced `.SCENE` headings).
enum OutlineExtractor {
    private static let atx = RegexUtil.regex(#"^ {0,3}(#{1,6})[ \t]+(.*?)[ \t]*#*[ \t]*$"#)
    private static let fence = RegexUtil.regex(#"^\s{0,3}(`{3,}|~{3,})"#)
    private static let scene = RegexUtil.regex(#"^(?:INT|EXT|EST|INT\.?/EXT|I/E)[. ]"#, [.caseInsensitive])
    private static let listOrQuote = RegexUtil.regex(#"^\s*(?:(?:[-*+]|\d+[.)])\s|>)"#)
    private static let setext1 = RegexUtil.regex(#"^ {0,3}=+\s*$"#)
    private static let setext2 = RegexUtil.regex(#"^ {0,3}-{2,}\s*$"#)

    private static func groups(_ re: NSRegularExpression?, _ s: String) -> [String]? {
        guard let re, let m = re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
        else { return nil }
        return (0..<m.numberOfRanges).map {
            m.range(at: $0).location == NSNotFound ? "" : (s as NSString).substring(with: m.range(at: $0))
        }
    }

    static func items(from text: NSString, kind: DocumentKind) -> [OutlineItem] {
        // Lines with their ranges (line ends included), \r\n or \n.
        var lines: [(String, NSRange)] = []
        var location = 0
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            // ("\r\n" is one Character in Swift, so trim by scalars, not with hasSuffix.)
            let line = text.substring(with: range).trimmingCharacters(in: .newlines)
            lines.append((line, range))
            location = NSMaxRange(range)
        }

        var items: [OutlineItem] = []
        var start = 0
        // YAML front matter (--- … ---) at the very top is not a heading.
        if kind != .fountain, lines.first?.0.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.indices.dropFirst().first(where: {
               lines[$0].0.range(of: #"^(---|\.\.\.)\s*$"#, options: .regularExpression) != nil }) {
            start = close + 1
        }
        var openFence: Character?

        var i = start
        while i < lines.count {
            defer { i += 1 }
            let (line, range) = lines[i]
            func add(_ title: String, _ level: Int) {
                items.append(OutlineItem(title: title, level: level, range: range, line: i + 1))
            }
            if kind != .fountain, let marker = groups(fence, line)?[1].first {
                if openFence == nil { openFence = marker } else if openFence == marker { openFence = nil }
                continue
            }
            if openFence != nil { continue }

            if kind == .fountain {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    let hashes = trimmed.prefix { $0 == "#" }.count
                    let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty { add(title, min(hashes, 3)) }
                } else if groups(scene, trimmed) != nil {
                    add(trimmed, 2)
                } else if trimmed.hasPrefix("."), !trimmed.hasPrefix(".."), trimmed.count > 1 {
                    add(String(trimmed.dropFirst()), 2)
                }
                continue
            }

            if let m = groups(atx, line) {
                if !m[2].isEmpty { add(m[2], m[1].count) }
                continue
            }
            // Setext: a text line underlined by === or ---
            if i + 1 < lines.count, !line.trimmingCharacters(in: .whitespaces).isEmpty,
               groups(listOrQuote, line) == nil {
                let next = lines[i + 1].0
                let title = line.trimmingCharacters(in: .whitespaces)
                if groups(setext1, next) != nil { add(title, 1) } else if groups(setext2, next) != nil { add(title, 2) }
            }
        }
        return items
    }

    /// Index of the heading the cursor belongs to (the last one at or above its line), or nil.
    static func active(_ items: [OutlineItem], cursor: Int) -> Int? {
        var active: Int?
        for (i, item) in items.enumerated() where item.range.location <= cursor { active = i }
        return active
    }
}
