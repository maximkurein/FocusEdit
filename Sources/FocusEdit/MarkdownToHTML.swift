import Foundation

/// Colours of the live preview page. Export and print use `plain`, black on white.
struct PageColors: Equatable {
    var schemeDark: Bool
    var background: String
    var foreground: String
    var muted: String
    var accent: String

    static func plain(dark: Bool) -> PageColors {
        dark
            ? PageColors(schemeDark: true, background: "#1e1e20", foreground: "#e0e0e3", muted: "#8a8a90", accent: "#3399d9")
            : PageColors(schemeDark: false, background: "#ffffff", foreground: "#1c1c1e", muted: "#6b6b70", accent: "#3399d9")
    }
}

/// Dependency-free Markdown → HTML for the preview and HTML export: CommonMark
/// blocks (ATX and setext headings, quotes, nested lists, fenced and indented
/// code, rules) plus GFM tables, task lists, strikethrough and bare URLs.
/// Blocks are parsed line by line, inlines with regular expressions; not a full
/// CommonMark implementation. Raw HTML in the document is shown as text, and
/// links are limited to safe addresses (see `safeURL`).
/// Mirrors `windows/src/markdown-html.ts`, except that images are shown.
enum MarkdownToHTML {

    static func render(_ markdown: String) -> String {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
                           .replacingOccurrences(of: "\r", with: "\n")
        var lines = text.components(separatedBy: "\n")
        let definitions = takeDefinitions(&lines)
        return Renderer(definitions: definitions).blocks(lines, tight: false)
    }

    /// Wrap rendered body in a full, themed HTML document for preview/export.
    /// `fontSize` is the editor's text size in the preview, so zoom scales both.
    /// `fitted` fills the pane (Split, same margins as the editor). Otherwise the page
    /// keeps a centred reading measure, for Preview and for export.
    /// `colors` paints the live preview; export and print pass nil and stay black on white.
    static func document(_ markdown: String, dark: Bool, fontSize: Double = 16,
                         fitted: Bool = false, colors: PageColors? = nil) -> String {
        let page = colors ?? PageColors.plain(dark: dark)
        let fg = page.foreground
        let bg = page.background
        let muted = page.muted
        let accent = page.accent
        let measure = fitted
            ? "max-width: none; margin: 28px 36px 72px; padding: 0;"
            : "max-width: 45em; margin: 40px auto; padding: 0 24px;"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: \(page.schemeDark ? "dark" : "light"); }
          body { font: \(fontSize)px/1.6 -apple-system, system-ui, sans-serif;
                 color: \(fg); background: \(bg);
                 \(measure) }
          h1,h2,h3,h4,h5,h6 { line-height: 1.25; }
          blockquote { color: \(muted); border-left: 3px solid \(muted);
                       margin: 0; padding-left: 1em; }
          code { font-family: ui-monospace, Menlo, monospace;
                 background: rgba(127,127,127,0.15); padding: 0 .3em; border-radius: 4px; }
          pre { background: rgba(127,127,127,0.12); padding: 12px; border-radius: 8px;
                overflow-x: auto; }
          pre code { background: none; padding: 0; }
          a { color: \(accent); }
          img { max-width: 100%; }
          hr { border: none; border-top: 1px solid \(muted); margin: 2em 0; }
          table { border-collapse: collapse; margin: 1em 0; }
          th, td { border: 1px solid rgba(127,127,127,0.35); padding: 4px 10px; }
          th { background: rgba(127,127,127,0.10); }
          li.task { list-style: none; margin-left: -1.3em; }
          del { color: \(muted); }
        </style></head><body>
        \(render(markdown))
        </body></html>
        """
    }

    // MARK: Link definitions

    private static let definitionPattern = RegexUtil.regex(
        #"^ {0,3}\[([^\]]+)\]:\s*<?([^\s>]+)>?(?:\s+["'(].*["')])?\s*$"#)

    /// `[label]: url "title"` lines (outside code fences), removed from the text.
    private static func takeDefinitions(_ lines: inout [String]) -> [String: String] {
        var found: [String: String] = [:]
        var kept: [String] = []
        var fence: String?
        for line in lines {
            if let open = fence {
                if closesFence(line, open) { fence = nil }
                kept.append(line)
                continue
            }
            if let f = fenceOpening(line) {
                fence = f.marker
                kept.append(line)
                continue
            }
            if let re = definitionPattern,
               let m = re.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let ns = line as NSString
                let label = normalizeLabel(ns.substring(with: m.range(at: 1)))
                if found[label] == nil { found[label] = ns.substring(with: m.range(at: 2)) }
                continue
            }
            kept.append(line)
        }
        lines = kept
        return found
    }

    static func normalizeLabel(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: Block helpers

    /// ``` or ~~~ (three or more), up to three spaces in; the info string's first word.
    fileprivate static func fenceOpening(_ line: String) -> (marker: String, lang: String)? {
        let t = line.drop(while: { $0 == " " })
        guard line.count - t.count <= 3, let c = t.first, c == "`" || c == "~" else { return nil }
        let marker = String(t.prefix(while: { $0 == c }))
        guard marker.count >= 3 else { return nil }
        let info = t.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
        if c == "`", info.contains("`") { return nil }
        return (marker, info.split(separator: " ").first.map(String.init) ?? "")
    }

    fileprivate static func closesFence(_ line: String, _ marker: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let c = marker.first, t.count >= marker.count else { return false }
        return t.allSatisfy { $0 == c }
    }

    // MARK: Inline helpers

    /// Escape for both text and quoted attribute values.
    fileprivate static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// A link or image address that is safe to put in the page: web addresses,
    /// mail links (not images), relative paths, and data: images. Anything else
    /// (javascript:, file:, …) is dropped and only the text is shown.
    static func safeURL(_ raw: String, image: Bool) -> String? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !url.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "<" }) else { return nil }
        guard let colon = url.firstIndex(of: ":") else { return url }          // relative path
        if let slash = url.firstIndex(where: { "/?#".contains($0) }), slash < colon { return url }
        let allowed = image ? ["http", "https", "data"] : ["http", "https", "mailto"]
        return allowed.contains(url[..<colon].lowercased()) ? url : nil
    }
}

// MARK: - Renderer

private struct Renderer {
    let definitions: [String: String]

    // MARK: Line patterns

    private static let atx = RegexUtil.regex(#"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$"#)
    private static let rule = RegexUtil.regex(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let setext = RegexUtil.regex(#"^ {0,3}(=+|-+)[ \t]*$"#)
    private static let listMarker = RegexUtil.regex(#"^( {0,3})([-+*]|\d{1,9}[.)])([ \t]+|$)"#)
    private static let tableRule = RegexUtil.regex(#"^ {0,3}\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)

    private static func match(_ re: NSRegularExpression?, _ s: String) -> [String]? {
        guard let re else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map {
            let r = m.range(at: $0)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    private static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    /// Leading indentation in columns (a tab counts to the next multiple of 4).
    private static func indent(_ s: String) -> Int {
        var n = 0
        for c in s {
            if c == " " { n += 1 } else if c == "\t" { n += 4 - n % 4 } else { break }
        }
        return n
    }

    /// `s` without its first `columns` columns of indentation.
    private static func dedent(_ s: String, _ columns: Int) -> String {
        var n = 0
        var idx = s.startIndex
        while idx < s.endIndex, n < columns {
            if s[idx] == " " { n += 1 } else if s[idx] == "\t" { n += 4 - n % 4 } else { break }
            idx = s.index(after: idx)
        }
        return String(s[idx...])
    }

    private struct ListStart {
        let ordered: Bool
        let marker: String      // "-", "+", "*" or the delimiter "." / ")"
        let number: Int
        let contentIndent: Int
        let rest: String
    }

    private static func listStart(_ line: String) -> ListStart? {
        guard let m = match(listMarker, line) else { return nil }
        let lead = m[1].count, mark = m[2]
        let after = String(line.dropFirst(m[0].count))
        let ordered = mark.first!.isNumber
        let spaces = indent(m[3])
        // Five or more spaces after the marker: the item starts with indented code (one space counts).
        let gap = after.isEmpty ? 1 : (spaces > 4 ? 1 : spaces)
        let rest = spaces > 4 ? String(repeating: " ", count: spaces - 1) + after : after
        return ListStart(ordered: ordered,
                         marker: ordered ? String(mark.last!) : mark,
                         number: ordered ? Int(mark.dropLast()) ?? 1 : 1,
                         contentIndent: lead + mark.count + gap,
                         rest: rest)
    }

    /// Lines that start a block of their own (end a paragraph).
    private static func interruptsParagraph(_ line: String) -> Bool {
        if match(atx, line) != nil || match(rule, line) != nil { return true }
        if MarkdownToHTML.fenceOpening(line) != nil { return true }
        let t = line.drop(while: { $0 == " " })
        if line.count - t.count <= 3, t.first == ">" { return true }
        if let l = listStart(line), !l.rest.isEmpty, !l.ordered || l.number == 1 { return true }
        return false
    }

    // MARK: Blocks

    /// `tight`: paragraphs are written without `<p>` (items of a list with no blank lines).
    func blocks(_ lines: [String], tight: Bool) -> String {
        var html = ""
        var paragraph: [String] = []
        var i = 0

        func flush() {
            guard !paragraph.isEmpty else { return }
            let body = paragraphHTML(paragraph)
            html += tight ? body + "\n" : "<p>\(body)</p>\n"
            paragraph.removeAll()
        }

        while i < lines.count {
            let line = lines[i]

            if Self.isBlank(line) { flush(); i += 1; continue }

            // Setext heading underline (before the rule check: `---` under text is a heading).
            if !paragraph.isEmpty, let m = Self.match(Self.setext, line) {
                let level = m[1].first == "=" ? 1 : 2
                html += "<h\(level)>\(paragraphHTML(paragraph))</h\(level)>\n"
                paragraph.removeAll()
                i += 1
                continue
            }

            // Indented code (cannot interrupt a paragraph).
            if paragraph.isEmpty, Self.indent(line) >= 4 {
                var code: [String] = []
                while i < lines.count, Self.isBlank(lines[i]) || Self.indent(lines[i]) >= 4 {
                    code.append(Self.dedent(lines[i], 4)); i += 1
                }
                while let last = code.last, Self.isBlank(last) { code.removeLast() }
                html += "<pre><code>\(MarkdownToHTML.escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }

            if let fence = MarkdownToHTML.fenceOpening(line) {
                flush()
                let lead = Self.indent(line)
                i += 1
                var code: [String] = []
                while i < lines.count, !MarkdownToHTML.closesFence(lines[i], fence.marker) {
                    code.append(Self.dedent(lines[i], lead)); i += 1
                }
                i += 1 // closing fence (or the end)
                let lang = fence.lang.range(of: #"^[\w+#.-]+$"#, options: .regularExpression) != nil
                    ? " class=\"language-\(MarkdownToHTML.escape(fence.lang))\"" : ""
                html += "<pre><code\(lang)>\(MarkdownToHTML.escape(code.joined(separator: "\n")))</code></pre>\n"
                continue
            }

            if let m = Self.match(Self.atx, line) {
                flush()
                let level = m[1].count
                html += "<h\(level)>\(inline(m[2].trimmingCharacters(in: .whitespaces)))</h\(level)>\n"
                i += 1
                continue
            }

            if Self.match(Self.rule, line) != nil {
                flush()
                html += "<hr>\n"
                i += 1
                continue
            }

            // Table: a row with pipes, then the |:--|--:| rule.
            if paragraph.isEmpty, line.contains("|"), i + 1 < lines.count,
               lines[i + 1].contains("-"), Self.match(Self.tableRule, lines[i + 1]) != nil {
                let header = cells(line)
                let align = cells(lines[i + 1]).map { c -> String in
                    let l = c.hasPrefix(":"), r = c.hasSuffix(":")
                    return l && r ? "center" : r ? "right" : l ? "left" : ""
                }
                if header.count == align.count {
                    i += 2
                    var rows: [[String]] = []
                    while i < lines.count, !Self.isBlank(lines[i]), lines[i].contains("|") {
                        rows.append(cells(lines[i])); i += 1
                    }
                    html += table(header: header, align: align, rows: rows)
                    continue
                }
            }

            // Blockquote: `>` lines, plus lazy lines that continue its paragraph.
            if Self.indent(line) <= 3, line.drop(while: { $0 == " " }).first == ">" {
                flush()
                var inner: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    let t = l.drop(while: { $0 == " " })
                    if l.count - t.count <= 3, t.first == ">" {
                        var rest = t.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        inner.append(String(rest))
                    } else if !Self.isBlank(l), let prev = inner.last, !Self.isBlank(prev),
                              !Self.interruptsParagraph(l) {
                        inner.append(l)
                    } else { break }
                    i += 1
                }
                html += "<blockquote>\n\(blocks(inner, tight: false))</blockquote>\n"
                continue
            }

            if let start = Self.listStart(line),
               paragraph.isEmpty || (!start.rest.isEmpty && (!start.ordered || start.number == 1)) {
                flush()
                html += list(lines, &i, first: start)
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flush()
        return html
    }

    /// One list starting at `lines[i]`; `i` ends after it.
    private func list(_ lines: [String], _ i: inout Int, first: ListStart) -> String {
        var items: [[String]] = []
        var loose = false
        var current = first

        while i < lines.count {
            // This item: the rest of the marker line, then its indented, blank or lazy lines.
            var body = [current.rest]
            i += 1
            var sawBlank = false
            while i < lines.count {
                let l = lines[i]
                if Self.isBlank(l) {
                    sawBlank = true
                    body.append("")
                    i += 1
                    continue
                }
                if Self.indent(l) >= current.contentIndent {
                    if sawBlank, body.dropLast().contains(where: { !Self.isBlank($0) }) { loose = true }
                    sawBlank = false
                    body.append(Self.dedent(l, current.contentIndent))
                    i += 1
                    continue
                }
                // Lazy continuation of the item's paragraph.
                if !sawBlank, Self.listStart(l) == nil, !Self.interruptsParagraph(l),
                   let last = body.last, !Self.isBlank(last) {
                    body.append(l)
                    i += 1
                    continue
                }
                break
            }
            // Blank lines at the end belong between items (or after the list).
            var trailing = 0
            while let last = body.last, Self.isBlank(last), body.count > 1 { body.removeLast(); trailing += 1 }
            items.append(body)

            guard i < lines.count, let next = Self.listStart(lines[i]),
                  next.ordered == first.ordered, next.marker == first.marker else {
                i -= trailing   // leave the blank lines to the caller
                break
            }
            if trailing > 0 { loose = true }
            current = next
        }

        let tag = first.ordered ? "ol" : "ul"
        let start = first.ordered && first.number != 1 ? " start=\"\(first.number)\"" : ""
        var html = "<\(tag)\(start)>\n"
        for body in items { html += listItem(body, tight: !loose) }
        return html + "</\(tag)>\n"
    }

    private func listItem(_ body: [String], tight: Bool) -> String {
        var lines = body
        var task = ""
        if let first = lines.first,
           let r = first.range(of: #"^\[([ xX])\](?:[ \t]+|$)"#, options: .regularExpression) {
            let checked = first[r].dropFirst().first.map { $0 == "x" || $0 == "X" } ?? false
            task = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
            lines[0] = String(first[r.upperBound...])
        }
        var inner = blocks(lines, tight: tight)
        if inner.hasSuffix("\n") { inner.removeLast() }
        let cls = task.isEmpty ? "" : " class=\"task\""
        return "<li\(cls)>\(task)\(inner)</li>\n"
    }

    // MARK: Tables

    /// Cells of a table row: split on `|` that is not escaped or inside code.
    private func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = [], cell = "", inCode = false, escaped = false
        for c in t {
            if escaped { cell.append(c); escaped = false; continue }
            if c == "\\" { escaped = true; cell.append(c); continue }
            if c == "`" { inCode.toggle() }
            if c == "|", !inCode { out.append(cell); cell = ""; continue }
            cell.append(c)
        }
        out.append(cell)
        return out.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
    }

    private func table(header: [String], align: [String], rows: [[String]]) -> String {
        func row(_ cells: [String], _ tag: String) -> String {
            var html = "<tr>"
            for (n, a) in align.enumerated() {
                let style = a.isEmpty ? "" : " style=\"text-align:\(a)\""
                html += "<\(tag)\(style)>\(n < cells.count ? inline(cells[n]) : "")</\(tag)>"
            }
            return html + "</tr>\n"
        }
        return "<table>\n<thead>\(row(header, "th"))</thead>\n<tbody>\n"
            + rows.map { row($0, "td") }.joined() + "</tbody>\n</table>\n"
    }

    // MARK: Inline

    /// Lines of a paragraph: leading spaces dropped, two trailing spaces or `\` make a line break.
    private func paragraphHTML(_ lines: [String]) -> String {
        var parts: [String] = []
        for (n, raw) in lines.enumerated() {
            var line = String(raw.drop(while: { $0 == " " || $0 == "\t" }))
            let last = n == lines.count - 1
            if !last, line.hasSuffix("  ") {
                while line.hasSuffix(" ") { line.removeLast() }
                line += Inline.breakMark
            } else if !last, line.hasSuffix("\\"), !line.hasSuffix("\\\\") {
                line.removeLast()
                line += Inline.breakMark
            } else {
                while line.hasSuffix(" ") || line.hasSuffix("\t") { line.removeLast() }
            }
            parts.append(line)
        }
        return inline(parts.joined(separator: "\n"))
    }

    func inline(_ text: String) -> String {
        Inline(definitions: definitions).render(text)
    }
}

// MARK: - Inline

/// Inline Markdown. Finished pieces (code, escapes, link tags) are swapped for
/// private-use placeholders so later patterns can't touch them; the text left
/// over is escaped, emphasis is applied, then the placeholders are restored.
private final class Inline {
    static let breakMark = "\u{E002}"
    private static let open: Character = "\u{E000}", close: Character = "\u{E001}"

    /// The preview renders on every keystroke: compile each pattern once (main thread only).
    private static var compiled: [String: NSRegularExpression] = [:]

    let definitions: [String: String]
    private var pieces: [String] = []

    init(definitions: [String: String]) { self.definitions = definitions }

    private func hold(_ html: String) -> String {
        pieces.append(html)
        return "\(Self.open)\(pieces.count - 1)\(Self.close)"
    }

    func render(_ source: String) -> String {
        var s = source

        // Code spans: `x`, ``x ` y``.
        s = replace(s, #"(`+)(.+?)(?<!`)\1(?!`)"#) { m in
            var code = m[2].replacingOccurrences(of: "\n", with: " ")
            if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 2, code.contains(where: { $0 != " " }) {
                code = String(code.dropFirst().dropLast())
            }
            return self.hold("<code>\(MarkdownToHTML.escape(code))</code>")
        }
        // Backslash escapes.
        s = replace(s, ##"\\([!"#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~])"##) { m in
            self.hold(MarkdownToHTML.escape(m[1]))
        }
        // Autolinks: <https://…>, <mailto:…>.
        s = replace(s, #"<((?:https?|mailto):[^\s<>]+)>"#) { m in
            self.anchor(m[1], text: self.hold(MarkdownToHTML.escape(m[1])))
        }
        // Images, then links: ![alt](src "title"), [text](href "title").
        let target = #"\(\s*<?([^\s()<>]*(?:\([^\s()<>]*\)[^\s()<>]*)*)>?(?:\s+(?:"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)"#
        s = replace(s, #"!\[([^\]]*)\]"# + target) { m in
            guard let src = MarkdownToHTML.safeURL(m[2], image: true) else { return m[1] }
            return self.hold("<img alt=\"\(MarkdownToHTML.escape(self.plain(m[1])))\" src=\"\(MarkdownToHTML.escape(src))\">")
        }
        s = replace(s, #"\[((?:[^\[\]]|\[[^\[\]]*\])+)\]"# + target) { m in
            self.anchor(m[2], text: m[1])
        }
        // Reference links: [text][label], [label][], [label].
        s = replace(s, #"\[((?:[^\[\]]|\[[^\[\]]*\])+)\](?:\[([^\[\]]*)\])?(?![(:])"#) { m in
            let label = MarkdownToHTML.normalizeLabel(m[2].isEmpty ? m[1] : m[2])
            guard let href = self.definitions[label] else { return m[0] }
            return self.anchor(href, text: m[1])
        }
        // Bare web addresses (trailing punctuation stays outside).
        s = replace(s, #"(?<![\w/\"'=\x{E001}])https?://[^\s<>\x{E000}\x{E001}\x{E002}]*[^\s<>.,:;!?"')\]\x{E000}\x{E001}\x{E002}]"#) { m in
            self.anchor(m[0], text: self.hold(MarkdownToHTML.escape(m[0])))
        }

        s = MarkdownToHTML.escape(s)
        s = replace(s, #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#) { m in "<strong>\(m[2])</strong>" }
        s = replace(s, #"(?<![*\w])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![*\w])"#) { m in "<em>\(m[1])</em>" }
        s = replace(s, #"(?<![_\w])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![_\w])"#) { m in "<em>\(m[1])</em>" }
        s = replace(s, #"~~(?=\S)(.+?)(?<=\S)~~"#) { m in "<del>\(m[1])</del>" }
        s = s.replacingOccurrences(of: Self.breakMark, with: "<br>\n")
        return restore(s)
    }

    /// A link when the address is safe, otherwise just its text.
    private func anchor(_ href: String, text: String) -> String {
        guard let safe = MarkdownToHTML.safeURL(href, image: false) else { return text }
        return hold("<a href=\"\(MarkdownToHTML.escape(safe))\">") + text + hold("</a>")
    }

    /// Alt text without placeholders or emphasis marks.
    private func plain(_ s: String) -> String {
        restore(s).replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
    }

    /// Put the held pieces back (they may contain placeholders themselves).
    private func restore(_ s: String) -> String {
        var out = s
        for _ in 0..<8 where out.contains(Self.open) {
            out = replace(out, "\u{E000}(\\d+)\u{E001}") { m in self.pieces[Int(m[1]) ?? 0] }
        }
        return out
    }

    /// Regex replace with capture-group access via a closure.
    private func replace(_ s: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let re = Self.compiled[pattern] ?? RegexUtil.regex(pattern) else { return s }
        Self.compiled[pattern] = re
        let ns = s as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String] = []
            for g in 0..<m.numberOfRanges {
                let r = m.range(at: g)
                groups.append(r.location == NSNotFound ? "" : ns.substring(with: r))
            }
            result += transform(groups)
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
