import AppKit

/// RTF ↔ Markdown, so RTF files (TextEdit's default format) open in FocusEdit as
/// Markdown text and save back as RTF.
///
/// Kept both ways: bold, italic, strikethrough, headings (by font size), bullet
/// and numbered lists (TextEdit-style NSTextList), links, monospaced runs (as
/// `code`) and indented paragraphs (as > quotes). Dropped: fonts, colours,
/// underline, images and tables — `Import.lostFormatting` names what was there.
enum RTFMarkdown {

    struct Import {
        let markdown: String
        /// Human-readable names of formatting the conversion could not keep.
        let lostFormatting: [String]
    }

    // MARK: RTF → Markdown

    static func markdown(fromRTF data: Data) throws -> Import {
        let attributed = try NSAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil)
        let ns = attributed.string as NSString
        let full = NSRange(location: 0, length: ns.length)

        // The body text is the most common font size and family.
        var sizes: [CGFloat: Int] = [:]
        var families: [String: Int] = [:]
        attributed.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let font = value as? NSFont else { return }
            sizes[font.pointSize, default: 0] += range.length
            if !font.isFixedPitch { families[font.familyName ?? "", default: 0] += range.length }
        }
        let bodySize = sizes.max { $0.value < $1.value }?.key ?? 12
        let bodyFamily = families.max { $0.value < $1.value }?.key

        var lost = Set<String>()
        var lines: [String] = []
        ns.enumerateSubstrings(in: full, options: [.byParagraphs]) { _, range, _, _ in
            lines.append(convert(attributed, range, bodySize: bodySize, bodyFamily: bodyFamily, lost: &lost))
        }
        if ns.hasSuffix("\n") { lines.append("") }

        let order = ["fonts", "colours", "underline", "images", "tables"]
        return Import(markdown: lines.joined(separator: "\n"),
                      lostFormatting: order.filter(lost.contains))
    }

    private static let listMarker = try! NSRegularExpression(pattern: #"^\t*([•◦▪●○–\-*]|\d+[.)])\t"#)

    private static func convert(_ document: NSAttributedString, _ paragraphRange: NSRange, bodySize: CGFloat,
                                bodyFamily: String?, lost: inout Set<String>) -> String {
        let paragraph = document.attributedSubstring(from: paragraphRange)
        let text = paragraph.string
        guard !text.isEmpty else { return "" }
        let style = paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        if let blocks = style?.textBlocks, !blocks.isEmpty { lost.insert("tables") }

        // Lists live in the paragraph style (NSTextList). Older RTF readers also put
        // the marker text ("\t•\t", "\t1.\t") in the string: strip it when present.
        var prefix = ""
        var contentStart = 0
        let nsText = text as NSString
        if let lists = style?.textLists, let list = lists.last {
            if let m = listMarker.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)) {
                contentStart = m.range.length
            }
            let indent = String(repeating: "    ", count: lists.count - 1)
            let format = list.markerFormat.rawValue
            let ordered = ["decimal", "roman", "alpha", "octal", "hex"].contains { format.contains($0) }
            prefix = indent + (ordered ? "\(document.itemNumber(in: list, at: paragraphRange.location)). " : "- ")
        } else if let style, style.firstLineHeadIndent > 0, style.headIndent > 0 {
            prefix = "> "
        }

        // Headings: noticeably larger than the body text.
        let firstFont = paragraph.attribute(.font, at: contentStart < nsText.length ? contentStart : 0,
                                            effectiveRange: nil) as? NSFont
        var heading = false
        if prefix.isEmpty, let size = firstFont?.pointSize {
            // Matches rtf(fromMarkdown:): 24 / 18 / 14 pt over a 12 pt body.
            if size >= bodySize * 1.75 { prefix = "# "; heading = true }
            else if size >= bodySize * 1.35 { prefix = "## "; heading = true }
            else if size >= bodySize * 1.15 { prefix = "### "; heading = true }
        }

        let contentRange = NSRange(location: contentStart, length: nsText.length - contentStart)
        var runs: [Run] = []
        paragraph.enumerateAttributes(in: contentRange) { attrs, range, _ in
            var run = Run(text: nsText.substring(with: range))
            if attrs[.attachment] != nil { lost.insert("images"); run.text = run.text.replacingOccurrences(of: "\u{FFFC}", with: "") }
            if let font = attrs[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                run.bold = traits.contains(.boldFontMask) && !heading
                run.italic = traits.contains(.italicFontMask)
                run.mono = font.isFixedPitch
                if !run.mono, let family = font.familyName, let bodyFamily, family != bodyFamily { lost.insert("fonts") }
            }
            if let color = attrs[.foregroundColor] as? NSColor, !isNearBlack(color) { lost.insert("colours") }
            if attrs[.backgroundColor] != nil { lost.insert("colours") }
            if let u = attrs[.underlineStyle] as? Int, u != 0, attrs[.link] == nil { lost.insert("underline") }
            if let s = attrs[.strikethroughStyle] as? Int, s != 0 { run.strike = true }
            if let link = attrs[.link] { run.link = (link as? URL)?.absoluteString ?? (link as? String) }
            runs.append(run)
        }
        return prefix + merge(runs).map(\.markdown).joined()
    }

    private static func isNearBlack(_ color: NSColor) -> Bool {
        guard let c = color.usingColorSpace(.sRGB) else { return true }
        return c.redComponent < 0.2 && c.greenComponent < 0.2 && c.blueComponent < 0.2
    }

    private struct Run {
        var text: String
        var bold = false, italic = false, mono = false, strike = false
        var link: String?

        func sameStyle(as other: Run) -> Bool {
            bold == other.bold && italic == other.italic && mono == other.mono
                && strike == other.strike && link == other.link
        }

        /// Markers hug the words: "**bold** " not "**bold **".
        var markdown: String {
            let core = text.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { return text }
            let lead = String(text.prefix { $0 == " " || $0 == "\t" })
            let trail = String(text.reversed().prefix { $0 == " " || $0 == "\t" })
            var body = core
            if mono {
                body = "`\(core)`"
            } else {
                let mark = bold && italic ? "***" : bold ? "**" : italic ? "*" : ""
                body = mark + core + mark
                if strike { body = "~~\(body)~~" }
            }
            if let link { body = "[\(body)](\(link))" }
            return lead + body + trail
        }
    }

    private static func merge(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for run in runs {
            if let last = out.last, last.sameStyle(as: run) {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }

    // MARK: Markdown → RTF

    /// TextEdit's default look: Helvetica 12, bigger bold headings.
    static func rtf(fromMarkdown markdown: String) throws -> Data {
        let base = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
        let out = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")
        // Items of one list share one NSTextList (per nesting level); that is
        // what numbers them 1, 2, 3 instead of starting every item at 1.
        var openLists: [NSTextList] = []
        func lists(depth: Int, format: NSTextList.MarkerFormat) -> [NSTextList] {
            openLists = Array(openLists.prefix(depth + 1))
            while openLists.count <= depth { openLists.append(NSTextList(markerFormat: format, options: 0)) }
            if openLists[depth].markerFormat != format {
                openLists[depth] = NSTextList(markerFormat: format, options: 0)
            }
            return openLists
        }

        for (index, rawLine) in lines.enumerated() {
            var line = rawLine
            let style = NSMutableParagraphStyle()
            var font = base
            var marker = ""

            let isListItem = firstMatch(#"^\s*([-*+]|\d+[.)])\s+"#, in: line) != nil
            if !isListItem { openLists = [] }

            if let m = firstMatch(#"^(#{1,6})\s+(.*)$"#, in: line) {
                let level = m[1].count
                font = bold(NSFont(name: "Helvetica", size: level == 1 ? 24 : level == 2 ? 18 : 14) ?? base)
                line = m[2]
            } else if let m = firstMatch(#"^(\s*)[-*+]\s+(.*)$"#, in: line) {
                let depth = m[1].replacingOccurrences(of: "\t", with: "    ").count / 4
                style.textLists = lists(depth: depth, format: .disc)
                marker = "\t•\t"
                line = m[2]
                indentList(style, depth: depth)
            } else if let m = firstMatch(#"^(\s*)(\d+)[.)]\s+(.*)$"#, in: line) {
                let depth = m[1].replacingOccurrences(of: "\t", with: "    ").count / 4
                style.textLists = lists(depth: depth, format: .decimal)
                marker = "\t\(m[2]).\t"
                line = m[3]
                indentList(style, depth: depth)
            } else if let m = firstMatch(#"^>\s?(.*)$"#, in: line) {
                style.firstLineHeadIndent = 24
                style.headIndent = 24
                line = m[1]
            }

            let paragraph = NSMutableAttributedString(string: marker, attributes: [.font: font, .paragraphStyle: style])
            paragraph.append(inline(line, font: font, style: style))
            if index < lines.count - 1 {
                paragraph.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
            }
            out.append(paragraph)
        }
        return try out.data(from: NSRange(location: 0, length: out.length),
                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    private static func indentList(_ style: NSMutableParagraphStyle, depth: Int) {
        let left = CGFloat(depth) * 36
        style.tabStops = [NSTextTab(textAlignment: .left, location: left + 11),
                          NSTextTab(textAlignment: .left, location: left + 36)]
        style.headIndent = left + 36
    }

    // Groups: 1-2 link, 3 code, 4 bold+italic, 5-6 bold, 7-8 italic, 9 strikethrough.
    private static let inlinePattern = try! NSRegularExpression(pattern:
        #"\[([^\]]+)\]\(([^)\s]+)\)|`([^`]+)`|\*\*\*(.+?)\*\*\*|\*\*(.+?)\*\*|__(.+?)__|(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])|(?<![\w_])_(?!\s)(.+?)(?<!\s)_(?![\w_])|~~(.+?)~~"#)

    private static func inline(_ text: String, font: NSFont, style: NSParagraphStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ns = text as NSString
        var last = 0
        func plain(_ s: String, _ f: NSFont, extra: [NSAttributedString.Key: Any] = [:]) {
            var attrs: [NSAttributedString.Key: Any] = [.font: f, .paragraphStyle: style]
            attrs.merge(extra) { $1 }
            out.append(NSAttributedString(string: s, attributes: attrs))
        }
        for m in inlinePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            plain(ns.substring(with: NSRange(location: last, length: m.range.location - last)), font)
            func group(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            if let label = group(1), let url = group(2) {
                // A link label may carry its own emphasis: keep it as one link run.
                let inner = NSMutableAttributedString(attributedString: inline(label, font: font, style: style))
                inner.addAttribute(.link, value: URL(string: url) ?? url, range: NSRange(location: 0, length: inner.length))
                out.append(inner)
            } else if let code = group(3) {
                plain(code, NSFont(name: "Menlo", size: font.pointSize) ?? .monospacedSystemFont(ofSize: font.pointSize, weight: .regular))
            } else if let both = group(4) {
                plain(both, italic(bold(font)))
            } else if let strong = group(5) ?? group(6) {
                plain(strong, bold(font))
            } else if let emphasis = group(7) ?? group(8) {
                plain(emphasis, italic(font))
            } else if let strike = group(9) {
                let inner = NSMutableAttributedString(attributedString: inline(strike, font: font, style: style))
                inner.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                   range: NSRange(location: 0, length: inner.length))
                out.append(inner)
            }
            last = m.range.location + m.range.length
        }
        plain(ns.substring(from: last), font)
        return out
    }

    private static func bold(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
    private static func italic(_ f: NSFont) -> NSFont { NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }

    private static func firstMatch(_ pattern: String, in line: String) -> [String]? {
        guard let re = RegexUtil.regex(pattern),
              let m = re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) else { return nil }
        return (0..<m.numberOfRanges).map {
            let r = m.range(at: $0)
            return r.location == NSNotFound ? "" : (line as NSString).substring(with: r)
        }
    }
}
