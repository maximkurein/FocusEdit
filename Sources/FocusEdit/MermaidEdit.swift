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
}
