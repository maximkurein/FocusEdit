import AppKit

/// Text-editing menu commands: Markdown formatting, CriticMarkup, indentation,
/// print and PDF export. All edits go through shouldChangeText/didChangeText so
/// undo, highlighting, statistics and the dirty flag update automatically.
extension EditorViewController {

    // MARK: Low-level edit

    private func replaceText(_ range: NSRange, with string: String) {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: string)
        textView.didChangeText()
    }

    /// Wrap the selection (or the caret) with `prefix`/`suffix`.
    private func wrapSelection(_ prefix: String, _ suffix: String) {
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        if sel.length > 0 {
            let inner = ns.substring(with: sel)
            replaceText(sel, with: prefix + inner + suffix)
            textView.setSelectedRange(NSRange(location: sel.location + (prefix as NSString).length,
                                              length: (inner as NSString).length))
        } else {
            replaceText(sel, with: prefix + suffix)
            textView.setSelectedRange(NSRange(location: sel.location + (prefix as NSString).length, length: 0))
        }
    }

    /// Transform each line in the selection (or caret line).
    private func transformLines(_ transform: (String, Int) -> String) {
        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: textView.selectedRange())
        var lines = ns.substring(with: lineRange).components(separatedBy: "\n")
        for i in lines.indices where !(i == lines.count - 1 && lines[i].isEmpty) {
            lines[i] = transform(lines[i], i)
        }
        let replacement = lines.joined(separator: "\n")
        replaceText(lineRange, with: replacement)
        textView.setSelectedRange(NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }

    // MARK: Markdown formatting

    @objc func mdBold(_ sender: Any?)      { wrapSelection("**", "**") }
    @objc func mdItalic(_ sender: Any?)    { wrapSelection("*", "*") }
    @objc func mdCode(_ sender: Any?)      { wrapSelection("`", "`") }
    @objc func mdLink(_ sender: Any?)      { wrapSelection("[", "](https://)") }
    @objc func mdHeading(_ sender: Any?)   { transformLines { line, _ in "# " + line } }
    @objc func mdBlockquote(_ sender: Any?) { transformLines { line, _ in "> " + line } }
    @objc func mdUnorderedList(_ sender: Any?) { transformLines { line, _ in "- " + line } }
    @objc func mdOrderedList(_ sender: Any?)   { transformLines { line, i in "\(i + 1). " + line } }

    @objc func indentLines(_ sender: Any?) { transformLines { line, _ in "\t" + line } }
    @objc func unindentLines(_ sender: Any?) {
        transformLines { line, _ in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            var l = line
            var removed = 0
            while removed < 4, l.hasPrefix(" ") { l.removeFirst(); removed += 1 }
            return l
        }
    }

    // MARK: CriticMarkup

    @objc func cmAddition(_ sender: Any?)  { wrapSelection("{++", "++}") }
    @objc func cmDeletion(_ sender: Any?)  { wrapSelection("{--", "--}") }
    @objc func cmHighlight(_ sender: Any?) { wrapSelection("{==", "==}") }
    @objc func cmComment(_ sender: Any?)   { wrapSelection("{>>", "<<}") }

    @objc func cmAccept(_ sender: Any?) { resolveCriticMarkup(accept: true) }
    @objc func cmReject(_ sender: Any?) { resolveCriticMarkup(accept: false) }

    /// Resolve CriticMarkup in the selection (or the whole document if none).
    private func resolveCriticMarkup(accept: Bool) {
        let full = NSRange(location: 0, length: (textView.string as NSString).length)
        let sel = textView.selectedRange()
        let range = sel.length > 0 ? sel : full
        let source = (textView.string as NSString).substring(with: range)
        let resolved = Self.applyCriticMarkup(to: source, accept: accept)
        guard resolved != source else { return }
        replaceText(range, with: resolved)
        textView.setSelectedRange(NSRange(location: range.location, length: (resolved as NSString).length))
    }

    static func applyCriticMarkup(to text: String, accept: Bool) -> String {
        var s = text
        func sub(_ pattern: String, _ template: String) {
            guard let re = RegexUtil.regex(pattern, [.dotMatchesLineSeparators]) else { return }
            let m = NSMutableString(string: s)
            re.replaceMatches(in: m, range: NSRange(location: 0, length: m.length), withTemplate: template)
            s = m as String
        }
        sub(#"\{~~(.+?)~>(.+?)~~\}"#, accept ? "$2" : "$1")  // substitution
        sub(#"\{\+\+(.+?)\+\+\}"#, accept ? "$1" : "")        // addition
        sub(#"\{--(.+?)--\}"#, accept ? "" : "$1")            // deletion
        sub(#"\{==(.+?)==\}"#, "$1")                           // highlight → keep text
        sub(#"\{>>(.+?)<<\}"#, "")                             // comment → remove
        return s
    }

    // MARK: Print / PDF

    @objc func printEditor(_ sender: Any?) {
        let op = NSPrintOperation(view: textView)
        op.printInfo.horizontalPagination = .fit
        op.run()
    }

    @objc func exportAsPDF(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "export.pdf"
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            let data = self.textView.dataWithPDF(inside: self.textView.bounds)
            try? data.write(to: url)
        }
    }
}
