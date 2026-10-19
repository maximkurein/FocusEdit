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
}

/// Extracts headings/scene-headings for the outline sidebar.
enum OutlineExtractor {
    private static let mdHeading = RegexUtil.regex(#"^(\s{0,3})(#{1,6})\s+(.+?)\s*#*\s*$"#)
    private static let scene = RegexUtil.regex(
        #"^(INT|EXT|EST|INT\.?/EXT|I/E)[\. ].*$"#, [.caseInsensitive])

    static func items(from text: NSString, kind: DocumentKind) -> [OutlineItem] {
        guard kind != .plain else { return [] }
        var items: [OutlineItem] = []
        let full = NSRange(location: 0, length: text.length)
        text.enumerateSubstrings(in: full, options: .byParagraphs) { line, _, enclosing, _ in
            guard let line, !line.isEmpty else { return }
            switch kind {
            case .markdown:
                if let m = RegexUtil.matches(mdHeading, in: line).first, m.numberOfRanges > 3 {
                    let level = (line as NSString).substring(with: m.range(at: 2)).count
                    let title = (line as NSString).substring(with: m.range(at: 3))
                    items.append(OutlineItem(title: title, level: level, range: enclosing))
                }
            case .fountain:
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    let hashes = trimmed.prefix { $0 == "#" }.count
                    let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                    items.append(OutlineItem(title: title, level: min(hashes, 3), range: enclosing))
                } else if !RegexUtil.matches(scene, in: line).isEmpty
                            || (trimmed.hasPrefix(".") && !trimmed.hasPrefix("..")) {
                    let title = trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
                    items.append(OutlineItem(title: title, level: 1, range: enclosing))
                }
            case .plain:
                break
            }
        }
        return items
    }
}
