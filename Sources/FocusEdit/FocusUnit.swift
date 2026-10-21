import AppKit

/// The block of text "Paragraph" focus keeps lit: the lines around the caret up to the blank
/// lines. A heading is a block of its own, and so is each list item with the lines that continue
/// it. The same rule as `focusUnit` in windows/src/focus.ts.
enum FocusUnit {
    private static let listItem = RegexUtil.regex(#"^\s*([-*+]|\d+[.)])\s+"#)
    private static let heading = RegexUtil.regex(#"^\s{0,3}#{1,6}\s"#)

    static func range(in ns: NSString, around location: Int) -> NSRange {
        let length = ns.length
        func lineRange(at position: Int) -> NSRange { ns.lineRange(for: NSRange(location: position, length: 0)) }
        func text(_ range: NSRange) -> String {
            ns.substring(with: range).trimmingCharacters(in: .newlines)
        }
        func isBlank(_ range: NSRange) -> Bool { text(range).trimmingCharacters(in: .whitespaces).isEmpty }
        func isHeading(_ range: NSRange) -> Bool { !RegexUtil.matches(heading, in: text(range)).isEmpty }
        func starts(_ range: NSRange) -> Bool {
            isHeading(range) || !RegexUtil.matches(listItem, in: text(range)).isEmpty
        }

        let current = lineRange(at: min(max(location, 0), length))
        if length == 0 || isBlank(current) { return current }

        var first = current
        while !starts(first), first.location > 0 {
            let previous = lineRange(at: first.location - 1)
            if isBlank(previous) || isHeading(previous) { break }
            first = previous
        }
        var last = current
        if isHeading(first) {
            last = first
        } else {
            while NSMaxRange(last) < length {
                let next = lineRange(at: NSMaxRange(last))
                if isBlank(next) || starts(next) { break }
                last = next
            }
        }
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
}
