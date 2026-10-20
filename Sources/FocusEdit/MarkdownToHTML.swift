import Foundation

/// Minimal, dependency-free Markdown → HTML renderer covering the basics:
/// ATX headings, blockquotes, fenced/indented code, ordered/unordered lists,
/// paragraphs, and inline bold/italic/code/links/images. Good enough for a
/// live preview and HTML export; not a full CommonMark implementation.
enum MarkdownToHTML {

    static func render(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var html = ""
        var i = 0

        func flushParagraph(_ buffer: inout [String]) {
            guard !buffer.isEmpty else { return }
            html += "<p>" + inline(buffer.joined(separator: " ")) + "</p>\n"
            buffer.removeAll()
        }

        var paragraph: [String] = []

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                flushParagraph(&paragraph)
                i += 1
                var code: [String] = []
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(escape(lines[i])); i += 1
                }
                i += 1 // closing fence
                html += "<pre><code>" + code.joined(separator: "\n") + "</code></pre>\n"
                continue
            }

            // Blank line
            if trimmed.isEmpty {
                flushParagraph(&paragraph)
                i += 1
                continue
            }

            // ATX heading
            if let (level, text) = heading(trimmed) {
                flushParagraph(&paragraph)
                html += "<h\(level)>" + inline(text) + "</h\(level)>\n"
                i += 1
                continue
            }

            // Blockquote (consecutive)
            if trimmed.hasPrefix(">") {
                flushParagraph(&paragraph)
                var quote: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                html += "<blockquote>" + inline(quote.joined(separator: " ")) + "</blockquote>\n"
                continue
            }

            // Lists (consecutive)
            if isUnordered(trimmed) || isOrdered(trimmed) {
                let ordered = isOrdered(trimmed)
                flushParagraph(&paragraph)
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if ordered, isOrdered(t) {
                        items.append(inline(stripOrdered(t)))
                    } else if !ordered, isUnordered(t) {
                        items.append(inline(String(t.dropFirst()).trimmingCharacters(in: .whitespaces)))
                    } else { break }
                    i += 1
                }
                let tag = ordered ? "ol" : "ul"
                html += "<\(tag)>\n" + items.map { "<li>\($0)</li>" }.joined(separator: "\n") + "\n</\(tag)>\n"
                continue
            }

            // Default: paragraph text
            paragraph.append(line)
            i += 1
        }
        flushParagraph(&paragraph)
        return html
    }

    /// Wrap rendered body in a full, themed HTML document for preview/export.
    static func document(_ markdown: String, dark: Bool) -> String {
        let fg = dark ? "#e0e0e3" : "#1c1c1e"
        let bg = dark ? "#1e1e20" : "#ffffff"
        let muted = dark ? "#8a8a90" : "#6b6b70"
        let accent = "#3399d9"
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
          :root { color-scheme: \(dark ? "dark" : "light"); }
          body { font: 16px/1.6 -apple-system, system-ui, sans-serif;
                 color: \(fg); background: \(bg);
                 max-width: 720px; margin: 40px auto; padding: 0 24px; }
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
        </style></head><body>
        \(render(markdown))
        </body></html>
        """
    }

    // MARK: Blocks

    private static func heading(_ line: String) -> (Int, String)? {
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 6 { level += 1; idx = line.index(after: idx) }
        guard level > 0, idx < line.endIndex, line[idx] == " " else { return nil }
        return (level, String(line[idx...]).trimmingCharacters(in: .whitespaces))
    }

    private static func isUnordered(_ t: String) -> Bool {
        guard let f = t.first, "-+*".contains(f) else { return false }
        return t.count >= 2 && t[t.index(after: t.startIndex)] == " "
    }
    private static func isOrdered(_ t: String) -> Bool {
        RegexUtil.matches(RegexUtil.regex(#"^\d+\.\s"#), in: t).isEmpty == false
    }
    private static func stripOrdered(_ t: String) -> String {
        if let r = t.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            return String(t[r.upperBound...])
        }
        return t
    }

    // MARK: Inline

    private static func inline(_ text: String) -> String {
        var s = escape(text)
        s = replace(s, #"!\[([^\]]*)\]\(([^)]+)\)"#) { m in
            guard let src = safeURL(m[2], image: true) else { return m[1] }
            return "<img alt=\"\(attribute(m[1]))\" src=\"\(attribute(src))\">"
        }
        s = replace(s, #"\[([^\]]+)\]\(([^)]+)\)"#) { m in
            guard let href = safeURL(m[2], image: false) else { return m[1] }
            return "<a href=\"\(attribute(href))\">\(m[1])</a>"
        }
        s = replace(s, #"`([^`]+)`"#) { m in "<code>\(m[1])</code>" }
        s = replace(s, #"(\*\*|__)(\S.*?\S|\S)\1"#) { m in "<strong>\(m[2])</strong>" }
        s = replace(s, #"(?<![\*_])([\*_])(\S.*?\S|\S)\1(?![\*_])"#) { m in "<em>\(m[2])</em>" }
        return s
    }

    /// Text for inside a quoted attribute value (the quotes must not end the value).
    private static func attribute(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// A link or image address that is safe to put in the page: web addresses,
    /// mail links (not images), relative paths, and data: images. Anything else
    /// (javascript:, file:, …) is dropped and only the text is shown.
    private static func safeURL(_ raw: String, image: Bool) -> String? {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return nil }
        guard let colon = url.firstIndex(of: ":") else { return url }          // relative path
        if let slash = url.firstIndex(where: { "/?#".contains($0) }), slash < colon { return url }
        let allowed = image ? ["http", "https", "data"] : ["http", "https", "mailto"]
        return allowed.contains(url[..<colon].lowercased()) ? url : nil
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Regex replace with capture-group access via a closure.
    private static func replace(_ s: String, _ pattern: String,
                                _ transform: ([String]) -> String) -> String {
        guard let re = RegexUtil.regex(pattern) else { return s }
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
