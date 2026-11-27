import Foundation

/// Text edits behind the Diagram menu, on Mermaid source. Pure functions on strings, so
/// they are tested in `--selftest` without a window.
///
/// Settings that change how a diagram looks (hand-drawn, ELK layout, theme) go in the
/// diagram's own front matter, the way Mermaid documents them, so the file keeps them
/// and other Mermaid viewers (GitHub, mermaid.live) show the same thing:
///
///     ---
///     config:
///       look: handDrawn
///     ---
///     flowchart LR
enum MermaidEdit {

    // MARK: Templates

    struct Template {
        let title: String
        let source: String
    }

    static let templates: [Template] = [
        Template(title: "Flowchart", source: """
            flowchart LR
                start(["Start"]) --> step["Step"]
                step --> check{"OK?"}
                check -- "yes" --> done[("Done")]
                check -. "no" .-> step
            """),
        Template(title: "Flowchart with Groups", source: """
            flowchart TB
                subgraph client["Client"]
                    app["App"]
                end
                subgraph server["Server"]
                    api["API"] --> db[("Database")]
                end
                app -->|"HTTPS"| api
            """),
        Template(title: "Sequence", source: """
            sequenceDiagram
                participant U as User
                participant A as App
                participant S as Server
                U->>A: Click
                A->>S: Request
                S-->>A: Response
                A-->>U: Result
            """),
        Template(title: "Class", source: """
            classDiagram
                class Document {
                    +String text
                    +save()
                }
                class Editor {
                    +open(Document)
                }
                Editor --> Document
            """),
        Template(title: "State", source: """
            stateDiagram-v2
                [*] --> Draft
                Draft --> Review
                Review --> Draft: changes
                Review --> Published
                Published --> [*]
            """),
        Template(title: "Entity Relationship", source: """
            erDiagram
                USER ||--o{ ORDER : places
                ORDER ||--|{ ITEM : contains
                USER {
                    int id
                    string name
                }
            """),
        Template(title: "Gantt", source: """
            gantt
                title Plan
                dateFormat YYYY-MM-DD
                section Work
                Design   :a1, 2026-12-01, 7d
                Build    :a2, after a1, 14d
                Release  :milestone, after a2, 0d
            """),
        Template(title: "Mindmap", source: """
            mindmap
              root((Idea))
                Goals
                  First
                  Second
                Questions
                People
            """),
        Template(title: "Timeline", source: """
            timeline
                title Project
                2026 : Start
                     : First version
                2027 : Release
            """),
        Template(title: "Architecture", source: """
            architecture-beta
                group cloud(cloud)[Cloud]
                service web(internet)[Web] in cloud
                service api(server)[API] in cloud
                service db(database)[Database] in cloud
                web:R --> L:api
                api:R --> L:db
            """),
    ]

    /// What the Diagram menu inserts: the bare source in a diagram file, a fenced block in Markdown.
    static func insertion(_ template: Template, kind: DocumentKind) -> String {
        kind == .mermaid ? template.source + "\n" : "```mermaid\n" + template.source + "\n```\n"
    }

    // MARK: Which diagram

    private static let fence = try? NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})\s*([^\s`]*)"#)

    /// The source of the diagram the cursor is in: the whole text of a diagram file, or
    /// the inside of the ```mermaid block around the cursor (its fence lines included in
    /// the hit area) in Markdown. nil when the cursor is not in a diagram.
    static func diagramRange(in text: NSString, cursor: Int, kind: DocumentKind) -> NSRange? {
        if kind == .mermaid { return NSRange(location: 0, length: text.length) }
        guard kind == .markdown || kind == .plain, let fence else { return nil }
        var location = 0
        var open: (marker: String, mermaid: Bool, lineStart: Int, bodyStart: Int)?
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let ns = line as NSString
            if let m = fence.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let marker = ns.substring(with: m.range(at: 1))
                let info = ns.substring(with: m.range(at: 2)).lowercased()
                if let o = open {
                    // A closing fence: the same character, at least as long, nothing after it.
                    if marker.first == o.marker.first, marker.count >= o.marker.count,
                       line.trimmingCharacters(in: .whitespaces) == marker {
                        if o.mermaid, cursor >= o.lineStart, cursor <= NSMaxRange(lineRange) {
                            var end = lineRange.location
                            // Leave out the newline before the closing fence.
                            if end > o.bodyStart, text.character(at: end - 1) == 10 { end -= 1 }
                            if end > o.bodyStart, text.character(at: end - 1) == 13 { end -= 1 }
                            return NSRange(location: o.bodyStart, length: max(0, end - o.bodyStart))
                        }
                        open = nil
                    }
                } else {
                    open = (marker, info == "mermaid", lineRange.location, NSMaxRange(lineRange))
                }
            }
            location = NSMaxRange(lineRange)
        }
        // An unclosed block runs to the end of the text.
        if let o = open, o.mermaid, cursor >= o.lineStart {
            return NSRange(location: o.bodyStart, length: text.length - o.bodyStart)
        }
        return nil
    }

    // MARK: Front matter (config)

    /// Lines of the source and where the front matter block ends (index after `---`), or nil.
    private static func frontMatter(_ lines: [String]) -> Int? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            return i + 1
        }
        return nil
    }

    /// `look`, `layout`, `theme`… under `config:` in the front matter.
    static func configValue(_ source: String, key: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let end = frontMatter(lines) else { return nil }
        var inConfig = false
        for line in lines[1..<(end - 1)] {
            let indent = line.prefix { $0 == " " }.count
            let body = line.trimmingCharacters(in: .whitespaces)
            if indent == 0 { inConfig = body == "config:"; continue }
            if inConfig, body.hasPrefix(key + ":") {
                let value = body.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    /// Set (or with nil remove) `config.key` in the front matter, adding or dropping the
    /// block as needed. Other front matter (title, other keys) is kept as it is.
    static func settingConfig(_ source: String, key: String, value: String?) -> String {
        var lines = source.components(separatedBy: "\n")
        let entry = value.map { "  \(key): \($0)" }
        guard let end = frontMatter(lines) else {
            guard let entry else { return source }
            return (["---", "config:", entry, "---"] + lines).joined(separator: "\n")
        }
        // Where config: is, its last line, and the key's line under it.
        var configLine: Int?
        var lastConfigLine: Int?
        var keyLine: Int?
        var inConfig = false
        for i in 1..<(end - 1) {
            let line = lines[i]
            let indent = line.prefix { $0 == " " }.count
            let body = line.trimmingCharacters(in: .whitespaces)
            if body.isEmpty { continue }
            if indent == 0 {
                inConfig = body == "config:"
                if inConfig { configLine = i; lastConfigLine = i }
                continue
            }
            if inConfig {
                lastConfigLine = i
                if indent == 2, body.hasPrefix(key + ":") { keyLine = i }
            }
        }
        if let keyLine {
            if let entry { lines[keyLine] = entry } else { lines.remove(at: keyLine) }
        } else if let entry {
            if let last = lastConfigLine {
                lines.insert(entry, at: last + 1)
            } else {
                lines.insert(contentsOf: ["config:", entry], at: end - 1)
            }
        } else {
            return source
        }
        // Drop a config: left with nothing under it, then an empty front matter block.
        if let c = configLine, c < lines.count, lines[c].trimmingCharacters(in: .whitespaces) == "config:" {
            let next = c + 1 < lines.count ? lines[c + 1] : ""
            if !next.hasPrefix(" ") { lines.remove(at: c) }
        }
        if frontMatter(lines) == 2 { lines.removeFirst(2) }
        return lines.joined(separator: "\n")
    }

    // MARK: Direction

    private static let header = try? NSRegularExpression(
        pattern: #"^(\s*)(flowchart|graph)(?:[ \t]+(TB|TD|BT|RL|LR))?(?=\s|$)"#)

    private static func headerLine(_ lines: [String]) -> Int? {
        let start = frontMatter(lines) ?? 0
        return (start..<lines.count).first {
            let body = lines[$0].trimmingCharacters(in: .whitespaces)
            return !body.isEmpty && !body.hasPrefix("%%")
        }
    }

    /// TB, LR, BT or RL of a flowchart (TD reads as TB); nil for other diagram kinds.
    static func direction(_ source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let i = headerLine(lines), let header else { return nil }
        let line = lines[i] as NSString
        guard let m = header.firstMatch(in: lines[i], range: NSRange(location: 0, length: line.length)) else { return nil }
        guard m.range(at: 3).location != NSNotFound else { return "TB" }
        let dir = line.substring(with: m.range(at: 3))
        return dir == "TD" ? "TB" : dir
    }

    /// The flowchart turned to `dir`; nil when the diagram is not a flowchart.
    static func settingDirection(_ source: String, _ dir: String) -> String? {
        var lines = source.components(separatedBy: "\n")
        guard let i = headerLine(lines), let header else { return nil }
        let line = lines[i] as NSString
        guard let m = header.firstMatch(in: lines[i], range: NSRange(location: 0, length: line.length)) else { return nil }
        let lead = line.substring(with: m.range(at: 1))
        let word = line.substring(with: m.range(at: 2))
        lines[i] = lead + word + " " + dir + line.substring(from: NSMaxRange(m.range))
        return lines.joined(separator: "\n")
    }

    // MARK: From the picture back to the text

    /// The line (as a range in `source`) that defines a clicked block: the first line where
    /// its id stands as a word, else the first line with its label.
    static func lineRange(in source: String, nodeID: String, label: String) -> NSRange? {
        var candidates: [NSRegularExpression] = []
        if !nodeID.isEmpty,
           let re = try? NSRegularExpression(pattern: "(?<![\\w-])" + NSRegularExpression.escapedPattern(for: nodeID) + "(?![\\w-])") {
            candidates.append(re)
        }
        if !label.isEmpty, let re = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: label)) {
            candidates.append(re)
        }
        let lines = source.components(separatedBy: "\n")
        let skip = frontMatter(lines) ?? 0
        for re in candidates {
            var location = 0
            for (index, line) in lines.enumerated() {
                let length = (line as NSString).length
                defer { location += length + 1 }
                if index < skip { continue }
                if re.firstMatch(in: line, range: NSRange(location: 0, length: length)) != nil {
                    return NSRange(location: location, length: length)
                }
            }
        }
        return nil
    }

    /// Line `number` (1-based) of `source` as a range.
    static func lineRange(in source: String, line number: Int) -> NSRange? {
        let lines = source.components(separatedBy: "\n")
        guard number >= 1, number <= lines.count else { return nil }
        let location = lines[..<(number - 1)].reduce(0) { $0 + ($1 as NSString).length + 1 }
        return NSRange(location: location, length: (lines[number - 1] as NSString).length)
    }

    // MARK: The diagrams of a document (the Diagrams tab of the outline sidebar)

    /// Every diagram: the whole text of a diagram file, or each ```mermaid block of a
    /// Markdown document. The title is the diagram's own title (front matter `title:` or
    /// a `title` line) and its kind line; `range` is its source.
    static func diagrams(in text: NSString, kind: DocumentKind) -> [OutlineItem] {
        if kind == .mermaid {
            guard text.length > 0, !(text as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            let range = NSRange(location: 0, length: text.length)
            return [OutlineItem(title: summary(text as String), level: 1, range: range, line: 1)]
        }
        guard kind == .markdown || kind == .plain, let fence else { return [] }
        var found: [OutlineItem] = []
        var location = 0
        var lineNumber = 0
        var open: (marker: String, mermaid: Bool, bodyStart: Int, line: Int)?
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            lineNumber += 1
            let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let ns = line as NSString
            if let m = fence.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let marker = ns.substring(with: m.range(at: 1))
                if let o = open {
                    if marker.first == o.marker.first, marker.count >= o.marker.count,
                       line.trimmingCharacters(in: .whitespaces) == marker {
                        if o.mermaid {
                            var end = lineRange.location
                            if end > o.bodyStart, text.character(at: end - 1) == 10 { end -= 1 }
                            if end > o.bodyStart, text.character(at: end - 1) == 13 { end -= 1 }
                            let body = NSRange(location: o.bodyStart, length: max(0, end - o.bodyStart))
                            found.append(OutlineItem(title: summary(text.substring(with: body)), level: 1,
                                                     range: body, line: o.line))
                        }
                        open = nil
                    }
                } else {
                    let info = ns.substring(with: m.range(at: 2)).lowercased()
                    open = (marker, info == "mermaid", NSMaxRange(lineRange), lineNumber + 1)
                }
            }
            location = NSMaxRange(lineRange)
        }
        if let o = open, o.mermaid {
            let body = NSRange(location: o.bodyStart, length: text.length - o.bodyStart)
            found.append(OutlineItem(title: summary(text.substring(with: body)), level: 1, range: body, line: o.line))
        }
        return found
    }

    /// "Network · flowchart LR": the diagram's title, if it has one, and its kind line.
    static func summary(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        var title: String?
        if let end = frontMatter(lines) {
            for line in lines[1..<(end - 1)] where line.hasPrefix("title:") {
                title = line.dropFirst(6).trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            }
        }
        let head = headerLine(lines).map { lines[$0].trimmingCharacters(in: .whitespaces) } ?? ""
        if title == nil, let i = headerLine(lines) {
            for line in lines[(i + 1)...] {
                let body = line.trimmingCharacters(in: .whitespaces)
                if body.hasPrefix("title ") { title = String(body.dropFirst(6)).trimmingCharacters(in: .whitespaces); break }
            }
        }
        let kind = head.isEmpty ? "empty diagram" : head
        guard let title, !title.isEmpty else { return kind }
        return title + " · " + kind
    }

    // MARK: Inserting a block, an arrow or a group

    enum Element: Int {
        case block, arrow, group
    }

    /// The diagram's kind word: `flowchart`, `sequenceDiagram`, `classDiagram`…
    static func diagramType(_ source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let i = headerLine(lines) else { return nil }
        return lines[i].trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
    }

    /// Can the Block / Arrow / Group buttons add to this kind of diagram?
    static func canInsertElements(_ source: String) -> Bool {
        ["flowchart", "graph", "sequenceDiagram"].contains(diagramType(source) ?? "")
    }

    private static let flowKeywords: Set<String> = [
        "subgraph", "end", "direction", "flowchart", "graph", "TB", "TD", "BT", "RL", "LR",
    ]
    private static let flowSkipLines = try? NSRegularExpression(
        pattern: #"^\s*(?:%%|classDef\b|class\b|style\b|linkStyle\b|click\b|direction\b|accTitle|accDescr)"#)
    private static let flowStrip: [(NSRegularExpression?, String)] = [
        (try? NSRegularExpression(pattern: #""[^"]*""#), " "),                 // quoted labels
        (try? NSRegularExpression(pattern: #"\|[^|]*\|"#), " "),               // |edge labels|
        (try? NSRegularExpression(pattern: #"(?:--|==|-\.)\s+[^>\n]*?\s+(?:-->|==>|\.->|---)"#), " --> "), // -- text -->
        (try? NSRegularExpression(pattern: #"\[[^\]]*\]|\([^)]*\)|\{[^}]*\}|(?<=\w)>[^\]\n]*\]"#), " "), // shapes
        (try? NSRegularExpression(pattern: #":::[\w-]+"#), " "),
        (try? NSRegularExpression(pattern: #"@\{[^}]*\}"#), " "),
    ]
    private static let idWord = try? NSRegularExpression(pattern: #"(?<![\w-])[A-Za-z_]\w*(?:-\w+)*"#)

    /// Node ids of a flowchart in `line`, in order.
    private static func flowIDs(inLine line: String) -> [String] {
        if let skip = flowSkipLines, skip.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil {
            return []
        }
        var text = line
        for (re, with) in flowStrip {
            guard let re else { continue }
            text = re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length),
                                               withTemplate: with)
        }
        guard let idWord else { return [] }
        let ns = text as NSString
        return idWord.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
            .filter { !flowKeywords.contains($0) }
    }

    /// Node ids of a flowchart, in order of first appearance.
    static func nodeIDs(_ source: String) -> [String] {
        let lines = source.components(separatedBy: "\n")
        guard let header = headerLine(lines) else { return [] }
        var seen = Set<String>()
        var ids: [String] = []
        for line in lines[(header + 1)...] {
            for id in flowIDs(inLine: line) where seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    private static let participantLine = try? NSRegularExpression(
        pattern: #"^\s*(?:participant|actor)\s+([^\s]+)"#)
    private static let messageLine = try? NSRegularExpression(
        pattern: #"^\s*([^\s:+-][^:]*?)\s*(?:->>|-->>|->|-->|-x|--x|-\)|--\))\s*[+-]?\s*([^:]+?)\s*:"#)

    /// Participants of a sequence diagram in `line`.
    private static func participants(inLine line: String) -> [String] {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let re = participantLine, let m = re.firstMatch(in: line, range: range) {
            return [ns.substring(with: m.range(at: 1))]
        }
        if let re = messageLine, let m = re.firstMatch(in: line, range: range) {
            return [ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2))]
        }
        return []
    }

    static func participants(_ source: String) -> [String] {
        var seen = Set<String>()
        var list: [String] = []
        for line in source.components(separatedBy: "\n") {
            for p in participants(inLine: line) where seen.insert(p).inserted { list.append(p) }
        }
        return list
    }

    private static func unique(_ prefix: String, avoiding taken: [String], in source: String) -> String {
        var n = 1
        while taken.contains(prefix + String(n)) || source.contains(prefix + String(n)) { n += 1 }
        return prefix + String(n)
    }

    /// The diagram with a new line after line `line` (0-based) and what to select in it
    /// (the placeholder text). nil for diagram kinds the buttons don't know.
    static func inserting(_ element: Element, in source: String, afterLine line: Int) -> (source: String, select: NSRange)? {
        var lines = source.components(separatedBy: "\n")
        guard let header = headerLine(lines), let type = diagramType(source) else { return nil }
        let at = min(max(line, header), lines.count - 1)
        let current = lines[at]
        let lead = String(current.prefix { $0 == " " || $0 == "\t" })
        let body = current.trimmingCharacters(in: .whitespaces)
        // Inside a group the new line goes one step in; after `end` or the kind line, at that level.
        var indent = at == header ? lead + "    " : (lead.isEmpty ? "    " : lead)
        if body.hasPrefix("subgraph ") || ["loop", "alt", "opt", "par", "rect", "critical", "box"].contains(where: { body.hasPrefix($0 + " ") }) {
            indent = lead + "    "
        }
        var newLines: [String]
        var placeholder: String
        switch (type, element) {
        case ("flowchart", _), ("graph", _):
            let ids = nodeIDs(source)
            switch element {
            case .block:
                let id = unique("n", avoiding: ids, in: source)
                placeholder = "Block"
                newLines = ["\(indent)\(id)[\"\(placeholder)\"]"]
            case .arrow:
                let from = (at == header ? nil : flowIDs(inLine: current).first) ?? ids.last
                let to = unique("n", avoiding: ids, in: source)
                placeholder = "Next"
                if let from {
                    newLines = ["\(indent)\(from) --> \(to)[\"\(placeholder)\"]"]
                } else {
                    let start = unique("n", avoiding: ids + [to], in: source + to)
                    newLines = ["\(indent)\(to)[\"Start\"] --> \(start)[\"\(placeholder)\"]"]
                }
            case .group:
                let id = unique("g", avoiding: ids, in: source)
                placeholder = "Group"
                newLines = ["\(indent)subgraph \(id)[\"\(placeholder)\"]", "\(indent)    ", "\(indent)end"]
            }
        case ("sequenceDiagram", _):
            let people = participants(source)
            switch element {
            case .block:
                let id = unique("P", avoiding: people, in: source)
                placeholder = "Name"
                newLines = ["\(indent)participant \(id) as \(placeholder)"]
            case .arrow:
                let here = at == header ? [] : participants(inLine: current)
                let from = here.first ?? people.first ?? "A"
                let to = people.first { $0 != from } ?? (from == "B" ? "A" : "B")
                placeholder = "Message"
                newLines = ["\(indent)\(from)->>\(to): \(placeholder)"]
            case .group:
                placeholder = "Every minute"
                newLines = ["\(indent)loop \(placeholder)", "\(indent)    ", "\(indent)end"]
            }
        default:
            return nil
        }
        lines.insert(contentsOf: newLines, at: at + 1)
        let start = lines[..<(at + 1)].reduce(0) { $0 + ($1 as NSString).length + 1 }
        let offset = (newLines[0] as NSString).range(of: placeholder).location
        return (lines.joined(separator: "\n"),
                NSRange(location: start + offset, length: (placeholder as NSString).length))
    }

    // MARK: Renaming a block from the picture

    private static let openers = ["(((", "[[", "[(", "[/", "[\\", "((", "([", "{{", "[", "(", "{", ">"]

    /// The flowchart with block `id` labelled `text`: the label where the block is first
    /// given one is replaced, or one is added to its first mention. nil if `id` is not there.
    static func renaming(_ source: String, id: String, to text: String) -> String? {
        let label = "\"" + text.replacingOccurrences(of: "\"", with: "#quot;") + "\""
        guard !id.isEmpty, let re = try? NSRegularExpression(
            pattern: "(?<![\\w-])" + NSRegularExpression.escapedPattern(for: id) + "(?![\\w-])") else { return nil }
        var lines = source.components(separatedBy: "\n")
        guard let header = headerLine(lines) else { return nil }
        func outsideQuotes(_ line: NSString, _ at: Int) -> Bool {
            var quotes = 0
            for i in 0..<at where line.character(at: i) == 34 { quotes += 1 }
            return quotes % 2 == 0
        }
        var firstMention: (line: Int, end: Int)?
        for i in (header + 1)..<lines.count {
            let ns = lines[i] as NSString
            if let skip = flowSkipLines, skip.firstMatch(in: lines[i], range: NSRange(location: 0, length: ns.length)) != nil { continue }
            for m in re.matches(in: lines[i], range: NSRange(location: 0, length: ns.length)) where outsideQuotes(ns, m.range.location) {
                let end = NSMaxRange(m.range)
                if firstMention == nil { firstMention = (i, end) }
                // `subgraph id [label]` may have a space before the label.
                var at = end
                if ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces) == "subgraph" {
                    while at < ns.length, ns.character(at: at) == 32 { at += 1 }
                }
                let rest = ns.substring(from: at)
                guard let opener = openers.first(where: { rest.hasPrefix($0) }) else { continue }
                let contentStart = at + (opener as NSString).length
                var contentEnd: Int?
                if contentStart < ns.length, ns.character(at: contentStart) == 34 {
                    let close = ns.range(of: "\"", range: NSRange(location: contentStart + 1, length: ns.length - contentStart - 1))
                    if close.location != NSNotFound { contentEnd = close.location + 1 }
                } else {
                    let closers = CharacterSet(charactersIn: "])}")
                    let close = ns.rangeOfCharacter(from: closers, options: [],
                                                    range: NSRange(location: contentStart, length: ns.length - contentStart))
                    if close.location != NSNotFound { contentEnd = close.location }
                }
                guard let contentEnd else { continue }
                lines[i] = ns.replacingCharacters(in: NSRange(location: contentStart, length: contentEnd - contentStart), with: label)
                return lines.joined(separator: "\n")
            }
        }
        guard let first = firstMention else { return nil }
        let ns = lines[first.line] as NSString
        lines[first.line] = ns.replacingCharacters(in: NSRange(location: first.end, length: 0), with: "[" + label + "]")
        return lines.joined(separator: "\n")
    }
}
