import AppKit

/// Light highlighting for a Mermaid diagram file (.mmd): the diagram kind on its first
/// line, keywords, arrows, quoted labels and %% comments. Per line, like the others;
/// Mermaid's statements are line-oriented, so no state is carried between lines.
struct MermaidHighlighter: SyntaxHighlighter {
    /// `flowchart LR`, `sequenceDiagram`, … — the line that says what is drawn.
    private static let diagramKind = RegexUtil.regex(
        #"^\s*(flowchart|graph|sequenceDiagram|classDiagram(?:-v2)?|stateDiagram(?:-v2)?|erDiagram|gantt|pie|journey|mindmap|timeline|gitGraph|quadrantChart|requirementDiagram|C4Context|C4Container|C4Component|C4Dynamic|C4Deployment|sankey(?:-beta)?|xychart(?:-beta)?|block(?:-beta)?|packet(?:-beta)?|kanban|architecture(?:-beta)?|radar(?:-beta)?|treemap(?:-beta)?)\b.*$"#)
    private static let keyword = RegexUtil.regex(
        #"(?<![\w-])(subgraph|end|direction|participant|actor|activate|deactivate|note|Note|loop|alt|else|opt|par|and|critical|break|rect|autonumber|section|title|dateFormat|axisFormat|excludes|class|classDef|style|linkStyle|click|state|accTitle|accDescr)(?![\w-])"#)
    /// -->, ---, -.->, ==>, ->>, -->>, --x, --o, <-->, -- text -->, ~~~ …
    private static let arrow = RegexUtil.regex(#"<?(?:-{2,}|-\.+-|={2,}|~{3,}|-{1,2}>>?)[->xo]?>?"#)
    private static let quoted = RegexUtil.regex(#""[^"\n]*""#)
    private static let edgeLabel = RegexUtil.regex(#"\|[^|\n]*\|"#)

    func tokens(forLine line: String) -> [SyntaxToken] {
        let whole = NSRange(line.startIndex..., in: line)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("%%") {
            return [SyntaxToken(range: whole, role: .quote)]
        }
        if !RegexUtil.matches(Self.diagramKind, in: line).isEmpty {
            return [SyntaxToken(range: whole, role: .heading)]
        }
        var tokens: [SyntaxToken] = []
        // Text in quotes or |pipes| is a label: nothing inside it is a keyword or arrow.
        var labels: [NSRange] = []
        for re in [Self.edgeLabel, Self.quoted] {
            for m in RegexUtil.matches(re, in: line) where !labels.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) {
                labels.append(m.range)
                tokens.append(SyntaxToken(range: m.range, role: .emphasis))
            }
        }
        func free(_ r: NSRange) -> Bool { !labels.contains { NSIntersectionRange($0, r).length > 0 } }
        for m in RegexUtil.matches(Self.keyword, in: line) where free(m.range) {
            tokens.append(SyntaxToken(range: m.range, role: .strong))
        }
        for m in RegexUtil.matches(Self.arrow, in: line) where free(m.range) {
            tokens.append(SyntaxToken(range: m.range, role: .link))
        }
        // A comment after a statement.
        if let r = line.range(of: "%%") {
            let start = NSRange(r, in: line).location
            let tail = NSRange(location: start, length: whole.length - start)
            if free(tail) {
                tokens.removeAll { $0.range.location >= start }
                tokens.append(SyntaxToken(range: tail, role: .quote))
            }
        }
        return tokens.sorted { $0.range.location < $1.range.location }
    }
}
