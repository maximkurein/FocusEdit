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

    // MARK: Blocks: definition, shape, colour, arrows (mouse editing and Properties)

    /// A block's shape and how Mermaid writes it.
    enum Shape: Int, CaseIterable {
        case rectangle, rounded, stadium, subroutine, database, circle, decision, hexagon, parallelogram, flag

        var title: String {
            ["Rectangle", "Rounded", "Stadium", "Subroutine", "Database", "Circle", "Decision", "Hexagon",
             "Parallelogram", "Flag"][rawValue]
        }
        var open: String { ["[", "(", "([", "[[", "[(", "((", "{", "{{", "[/", ">"][rawValue] }
        var close: String { ["]", ")", "])", "]]", ")]", "))", "}", "}}", "/]", "]"][rawValue] }

        /// The shape an opener starts (the longest that fits).
        static func starting(_ rest: String) -> Shape? {
            if rest.hasPrefix("(((") { return .circle }
            return allCases.sorted { $0.open.count > $1.open.count }.first { rest.hasPrefix($0.open) }
        }
    }

    /// Where a block is given its shape and label: the line, the id and the span from the
    /// id through the closing bracket, the label inside (with its quotes) and the shape.
    struct Definition {
        let line: Int
        let id: NSRange
        let span: NSRange
        let label: NSRange
        let shape: Shape
    }

    private static func idPattern(_ id: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: "(?<![\\w-])" + NSRegularExpression.escapedPattern(for: id) + "(?![\\w-])")
    }

    private static func outsideQuotes(_ line: NSString, _ at: Int) -> Bool {
        var quotes = 0
        for i in 0..<at where line.character(at: i) == 34 { quotes += 1 }
        return quotes % 2 == 0
    }

    /// Lines of a flowchart that may hold blocks (after the kind line, not styles or comments).
    private static func blockLines(_ lines: [String]) -> Range<Int>? {
        guard let header = headerLine(lines), header + 1 <= lines.count else { return nil }
        return (header + 1)..<lines.count
    }

    private static func isSkipped(_ line: String) -> Bool {
        guard let skip = flowSkipLines else { return false }
        return skip.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// The shape and label of `id` right after `idEnd` in `line`, if it has them there.
    private static func shapeAfter(_ ns: NSString, _ idEnd: Int) -> (shape: Shape, label: NSRange, end: Int)? {
        let rest = ns.substring(from: idEnd)
        guard let shape = Shape.starting(rest) else { return nil }
        let triple = shape == .circle && rest.hasPrefix("(((")
        let open = triple ? "(((" : shape.open
        let close = triple ? ")))" : shape.close
        let start = idEnd + (open as NSString).length
        guard start <= ns.length else { return nil }
        var closeAt: Int
        if start < ns.length, ns.character(at: start) == 34 {
            let q = ns.range(of: "\"", range: NSRange(location: start + 1, length: ns.length - start - 1))
            guard q.location != NSNotFound else { return nil }
            let c = ns.range(of: close, range: NSRange(location: q.location + 1, length: ns.length - q.location - 1))
            guard c.location != NSNotFound else { return nil }
            closeAt = c.location
            // The label is the quoted part; anything between it and the bracket stays.
            return (shape, NSRange(location: start, length: q.location + 1 - start), closeAt + (close as NSString).length)
        }
        var c = ns.range(of: close, range: NSRange(location: start, length: ns.length - start))
        if shape == .parallelogram, c.location == NSNotFound {
            c = ns.range(of: "\\]", range: NSRange(location: start, length: ns.length - start))
        }
        guard c.location != NSNotFound else { return nil }
        closeAt = c.location
        return (shape, NSRange(location: start, length: closeAt - start), closeAt + (close as NSString).length)
    }

    /// Where block `id` gets its shape and label; nil if it never does (a bare `A --> B`).
    static func definition(_ source: String, id: String) -> Definition? {
        let lines = source.components(separatedBy: "\n")
        guard let range = blockLines(lines), let re = idPattern(id) else { return nil }
        for i in range where !isSkipped(lines[i]) {
            let ns = lines[i] as NSString
            for m in re.matches(in: lines[i], range: NSRange(location: 0, length: ns.length))
            where outsideQuotes(ns, m.range.location) {
                var at = NSMaxRange(m.range)
                if ns.substring(to: m.range.location).trimmingCharacters(in: .whitespaces) == "subgraph" {
                    while at < ns.length, ns.character(at: at) == 32 { at += 1 }
                }
                guard let found = shapeAfter(ns, at) else { continue }
                return Definition(line: i, id: m.range,
                                  span: NSRange(location: m.range.location, length: found.end - m.range.location),
                                  label: found.label, shape: found.shape)
            }
        }
        return nil
    }

    /// The first line that mentions block `id` (outside labels), and where.
    private static func firstMention(_ lines: [String], id: String) -> (line: Int, id: NSRange)? {
        guard let range = blockLines(lines), let re = idPattern(id) else { return nil }
        for i in range where !isSkipped(lines[i]) {
            let ns = lines[i] as NSString
            if let m = re.matches(in: lines[i], range: NSRange(location: 0, length: ns.length))
                .first(where: { outsideQuotes(ns, $0.range.location) }) {
                return (i, m.range)
            }
        }
        return nil
    }

    /// The shape of block `id` (a bare id is a rectangle); nil if it is not in the diagram.
    static func shape(_ source: String, id: String) -> Shape? {
        if let d = definition(source, id: id) { return d.shape }
        return firstMention(source.components(separatedBy: "\n"), id: id) == nil ? nil : .rectangle
    }

    /// Block `id` drawn as `shape`, its label kept (a bare id gets itself as the label).
    static func settingShape(_ source: String, id: String, _ shape: Shape) -> String? {
        var lines = source.components(separatedBy: "\n")
        if let d = definition(source, id: id) {
            let ns = lines[d.line] as NSString
            let label = ns.substring(with: d.label)
            let text = ns.substring(with: d.id) + shape.open + label + shape.close
            lines[d.line] = ns.replacingCharacters(in: d.span, with: text)
            return lines.joined(separator: "\n")
        }
        guard let m = firstMention(lines, id: id) else { return nil }
        let ns = lines[m.line] as NSString
        lines[m.line] = ns.replacingCharacters(in: NSRange(location: NSMaxRange(m.id), length: 0),
                                               with: shape.open + "\"" + id + "\"" + shape.close)
        return lines.joined(separator: "\n")
    }

    /// Fill colours for the Properties colour menu (light fills, readable text).
    enum Color: Int, CaseIterable {
        case blue, green, yellow, red, purple, gray

        var title: String { ["Blue", "Green", "Yellow", "Red", "Purple", "Gray"][rawValue] }
        var style: String {
            [
                "fill:#dbeafe,stroke:#2563eb,color:#1e3a8a",
                "fill:#dcfce7,stroke:#16a34a,color:#14532d",
                "fill:#fef9c3,stroke:#ca8a04,color:#713f12",
                "fill:#fee2e2,stroke:#dc2626,color:#7f1d1d",
                "fill:#f3e8ff,stroke:#9333ea,color:#581c87",
                "fill:#f3f4f6,stroke:#6b7280,color:#111827",
            ][rawValue]
        }
    }

    private static func styleLines(_ lines: [String], id: String) -> [Int] {
        lines.indices.filter {
            let parts = lines[$0].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
            return parts.count >= 2 && parts[0] == "style" && parts[1] == Substring(id)
        }
    }

    /// The colour of block `id` from its `style` line: one of ours, or nil (none or another).
    static func color(_ source: String, id: String) -> Color? {
        let lines = source.components(separatedBy: "\n")
        guard let i = styleLines(lines, id: id).last else { return nil }
        let parts = lines[i].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        return Color.allCases.first { $0.style == String(parts[2]) }
    }

    /// Does block `id` have a `style` line of any colour?
    static func hasStyle(_ source: String, id: String) -> Bool {
        !styleLines(source.components(separatedBy: "\n"), id: id).isEmpty
    }

    /// Block `id` filled with `color` (nil removes its `style` lines).
    static func settingColor(_ source: String, id: String, _ color: Color?) -> String {
        var lines = source.components(separatedBy: "\n")
        let existing = styleLines(lines, id: id)
        if let color, let last = existing.last {
            let lead = String(lines[last].prefix { $0 == " " || $0 == "\t" })
            lines[last] = lead + "style \(id) " + color.style
            for i in existing.dropLast().reversed() { lines.remove(at: i) }
            return lines.joined(separator: "\n")
        }
        for i in existing.reversed() { lines.remove(at: i) }
        guard let color else { return lines.joined(separator: "\n") }
        return appendingLine("style \(id) " + color.style, to: lines)
    }

    /// `text` as a new last line of the diagram, indented like its first statement.
    private static func appendingLine(_ text: String, to lines: [String]) -> String {
        var lines = lines
        var end = lines.count
        while end > 0, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        let header = headerLine(lines) ?? 0
        let first = lines.indices.first { $0 > header && !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        var lead = first.map { String(lines[$0].prefix { $0 == " " || $0 == "\t" }) } ?? "    "
        if lead.isEmpty { lead = "    " }
        lines.insert(lead + text, at: end)
        return lines.joined(separator: "\n")
    }

    /// Arrow A → B as a new last line.
    static func connecting(_ source: String, from: String, to: String) -> String? {
        guard !from.isEmpty, !to.isEmpty, from != to else { return nil }
        return appendingLine("\(from) --> \(to)", to: source.components(separatedBy: "\n"))
    }

    /// A new block after block `id`, joined to it by an arrow; with the placeholder to select.
    static func addingNext(_ source: String, id: String) -> (source: String, select: NSRange)? {
        var lines = source.components(separatedBy: "\n")
        let at = definition(source, id: id)?.line ?? firstMention(lines, id: id)?.line
        guard let at else { return nil }
        let new = unique("n", avoiding: nodeIDs(source), in: source)
        var lead = String(lines[at].prefix { $0 == " " || $0 == "\t" })
        if lead.isEmpty { lead = "    " }
        let line = lead + "\(id) --> \(new)[\"Next\"]"
        lines.insert(line, at: at + 1)
        let start = lines[...at].reduce(0) { $0 + ($1 as NSString).length + 1 }
        return (lines.joined(separator: "\n"),
                NSRange(location: start + (line as NSString).range(of: "Next").location, length: 4))
    }

    /// A copy of block `id` (same shape and label) on the line after its definition.
    static func duplicating(_ source: String, id: String) -> (source: String, id: String)? {
        var lines = source.components(separatedBy: "\n")
        let new = unique("n", avoiding: nodeIDs(source), in: source)
        if let d = definition(source, id: id) {
            let ns = lines[d.line] as NSString
            let lead = String(lines[d.line].prefix { $0 == " " || $0 == "\t" })
            lines.insert((lead.isEmpty ? "    " : lead) + new + ns.substring(with: NSRange(
                location: NSMaxRange(d.id), length: NSMaxRange(d.span) - NSMaxRange(d.id))), at: d.line + 1)
            return (lines.joined(separator: "\n"), new)
        }
        guard let m = firstMention(lines, id: id) else { return nil }
        var lead = String(lines[m.line].prefix { $0 == " " || $0 == "\t" })
        if lead.isEmpty { lead = "    " }
        lines.insert(lead + new + "[\"\(id)\"]", at: m.line + 1)
        return (lines.joined(separator: "\n"), new)
    }

    /// The diagram without block `id`: lines that only define or link it go; another block
    /// defined on such a line keeps its definition on a line of its own; its `style`,
    /// `class` and `click` lines go too. nil for a group (subgraph) or an unknown id.
    static func deleting(_ source: String, id: String) -> String? {
        var lines = source.components(separatedBy: "\n")
        guard let range = blockLines(lines), let re = idPattern(id), firstMention(lines, id: id) != nil else { return nil }
        var out: [String] = Array(lines[..<range.lowerBound])
        for i in range {
            let line = lines[i]
            let body = line.trimmingCharacters(in: .whitespaces)
            let words = body.split(separator: " ")
            if words.count >= 2, ["style", "class", "click"].contains(String(words[0])),
               words[1].split(separator: ",").contains(Substring(id)) {
                continue
            }
            if words.first == "subgraph", words.count >= 2, words[1].hasPrefix(id) {
                if flowIDs(inLine: line).first == id { return nil }
            }
            if isSkipped(line) { out.append(line); continue }
            let ns = line as NSString
            let hits = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
                .filter { outsideQuotes(ns, $0.range.location) }
            guard !hits.isEmpty else { out.append(line); continue }
            // Keep the other blocks this line gives a shape to.
            let lead = String(line.prefix { $0 == " " || $0 == "\t" })
            for other in flowIDs(inLine: line) where other != id {
                guard let r = idPattern(other) else { continue }
                for m in r.matches(in: line, range: NSRange(location: 0, length: ns.length))
                where outsideQuotes(ns, m.range.location) {
                    if let found = shapeAfter(ns, NSMaxRange(m.range)) {
                        out.append(lead + ns.substring(with: NSRange(location: m.range.location,
                                                                       length: found.end - m.range.location)))
                        break
                    }
                }
            }
        }
        lines = out
        return lines.joined(separator: "\n")
    }

    // MARK: Arrow kinds

    enum Arrow: Int, CaseIterable {
        case arrow, dotted, thick, line, both

        var title: String { ["Arrow  -->", "Dotted  -.->", "Thick  ==>", "Line  ---", "Both Ways  <-->"][rawValue] }
        var text: String { ["-->", "-.->", "==>", "---", "<-->"][rawValue] }
    }

    private static let labelledLink = try? NSRegularExpression(
        pattern: #"(?<![<\-=.])(--|==|-\.)\s+([^>\n|]*?)\s+(-->|==>|\.->|---)"#)
    private static let plainLink = try? NSRegularExpression(pattern: #"<?(?:-\.+->|-\.+-|={2,}>|-{2,}>|-{3,}|={3,})"#)

    /// The kind of the first arrow on `line` outside labels, and where it is.
    private static func firstArrow(_ line: String) -> (arrow: Arrow, range: NSRange, label: String?)? {
        let ns = line as NSString
        let all = NSRange(location: 0, length: ns.length)
        var best: (Arrow, NSRange, String?)?
        if let re = labelledLink, let m = re.matches(in: line, range: all).first(where: { outsideQuotes(ns, $0.range.location) }) {
            let start = ns.substring(with: m.range(at: 1))
            let kind: Arrow = start == "==" ? .thick : start == "-." ? .dotted : .arrow
            best = (kind, m.range, ns.substring(with: m.range(at: 2)))
        }
        if let re = plainLink, let m = re.matches(in: line, range: all).first(where: { outsideQuotes(ns, $0.range.location) }),
           best == nil || m.range.location < best!.1.location {
            let t = ns.substring(with: m.range)
            let kind: Arrow = t.hasPrefix("<") ? .both : t.contains(".") ? .dotted : t.hasPrefix("=") ? .thick
                : t.hasSuffix(">") ? .arrow : .line
            best = (kind, m.range, nil)
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    /// The arrow on line `line` (0-based) of a flowchart, if there is one.
    static func arrow(_ source: String, line: Int) -> Arrow? {
        let lines = source.components(separatedBy: "\n")
        guard let range = blockLines(lines), range.contains(line), !isSkipped(lines[line]) else { return nil }
        return firstArrow(lines[line])?.arrow
    }

    /// The first arrow on line `line` turned into `kind` (a `-- text -->` label moves to `|text|`).
    static func settingArrow(_ source: String, line: Int, _ kind: Arrow) -> String? {
        var lines = source.components(separatedBy: "\n")
        guard let range = blockLines(lines), range.contains(line), !isSkipped(lines[line]),
              let found = firstArrow(lines[line]) else { return nil }
        let text = found.label.map { kind.text + "|" + $0 + "|" } ?? kind.text
        lines[line] = (lines[line] as NSString).replacingCharacters(in: found.range, with: text)
        return lines.joined(separator: "\n")
    }

    /// The block a line is about: the first id on it (for Properties).
    static func block(_ source: String, line: Int) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard let range = blockLines(lines), range.contains(line) else { return nil }
        let body = lines[line].trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("style ") || body.hasPrefix("class ") {
            return body.split(separator: " ").dropFirst().first.map(String.init)
        }
        return flowIDs(inLine: lines[line]).first
    }

    // MARK: Completion

    static let diagramKinds = [
        "flowchart", "graph", "sequenceDiagram", "classDiagram", "stateDiagram-v2", "erDiagram", "gantt",
        "mindmap", "timeline", "architecture-beta", "pie", "journey", "gitGraph", "quadrantChart",
        "xychart-beta", "block-beta", "kanban", "sankey-beta", "requirementDiagram",
    ]

    private static let keywords: [String: [String]] = [
        "flowchart": ["subgraph", "end", "direction", "style", "classDef", "class", "click", "linkStyle"],
        "sequenceDiagram": ["participant", "actor", "loop", "alt", "else", "opt", "par", "and", "critical",
                            "break", "rect", "end", "Note", "activate", "deactivate", "autonumber", "over"],
        "classDiagram": ["class", "namespace", "note", "direction"],
        "stateDiagram-v2": ["state", "note", "direction", "end"],
        "gantt": ["title", "dateFormat", "axisFormat", "section", "excludes", "todayMarker", "done", "active",
                  "crit", "milestone", "after"],
        "timeline": ["title", "section"],
        "pie": ["title", "showData"],
        "journey": ["title", "section"],
        "architecture-beta": ["group", "service", "junction", "cloud", "database", "server", "internet", "disk"],
    ]

    private static let configWords = ["config", "look", "layout", "theme", "title", "handDrawn", "classic",
                                      "elk", "dagre", "default", "neutral", "dark", "forest", "base"]

    /// Words to offer for `prefix` while typing on line `line` (0-based) of a diagram:
    /// the kinds on its first line, config words in its front matter, else its block ids
    /// (or participants) and then Mermaid's words for its kind.
    static func completions(prefix: String, linePrefix: String, source: String, line: Int) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let lines = source.components(separatedBy: "\n")
        func matching(_ words: [String], caseSensitive: Bool) -> [String] {
            let p = caseSensitive ? prefix : prefix.lowercased()
            return words.filter {
                let w = caseSensitive ? $0 : $0.lowercased()
                return w.hasPrefix(p) && w != p
            }
        }
        if let end = frontMatter(lines), line < end {
            return matching(configWords, caseSensitive: false)
        }
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", frontMatter(lines) == nil {
            return matching(configWords, caseSensitive: false)
        }
        let header = headerLine(lines)
        if header == nil || header == line {
            return linePrefix.trimmingCharacters(in: .whitespaces) == prefix
                ? matching(diagramKinds, caseSensitive: false) : []
        }
        var type = diagramType(source) ?? ""
        if type == "graph" { type = "flowchart" }
        let names = type == "flowchart" ? nodeIDs(source) : type == "sequenceDiagram" ? participants(source) : []
        var out: [String] = []
        for w in matching(names, caseSensitive: true) + matching(keywords[type] ?? [], caseSensitive: false)
        where !out.contains(w) {
            out.append(w)
        }
        return out
    }
}
