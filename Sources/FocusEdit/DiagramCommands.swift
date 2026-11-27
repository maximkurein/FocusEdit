import AppKit

/// The Diagram menu (and its palette commands): templates, direction, look, layout and
/// theme of the Mermaid diagram under the cursor, plus the way back from the picture to
/// the text (a clicked block, a syntax error). The text edits are `MermaidEdit`'s.
extension EditorViewController {

    static let diagramDirections = ["TB", "LR", "BT", "RL"]
    static let diagramLooks: [(title: String, value: String?)] = [("Classic", nil), ("Hand-drawn", "handDrawn")]
    static let diagramLayouts: [(title: String, value: String?)] = [("Standard", nil), ("ELK (large diagrams)", "elk")]
    static let diagramThemes: [(title: String, value: String?)] = [
        ("Same as the Preview", nil), ("Default", "default"), ("Neutral", "neutral"), ("Dark", "dark"), ("Forest", "forest"),
    ]

    /// Mermaid works in Markdown and in diagram files.
    var diagramsAllowed: Bool { documentKind == .markdown || documentKind == .mermaid }

    /// The source range of the diagram under the cursor.
    var currentDiagramRange: NSRange? {
        MermaidEdit.diagramRange(in: textView.string as NSString,
                                 cursor: textView.selectedRange().location, kind: documentKind)
    }

    private var currentDiagramSource: String? {
        currentDiagramRange.map { (textView.string as NSString).substring(with: $0) }
    }

    /// Replace `range` through the text view, so it can be undone and everything follows.
    private func replaceText(in range: NSRange, with text: String, select: NSRange? = nil) {
        guard textView.shouldChangeText(in: range, replacementString: text) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: text)
        textView.didChangeText()
        if let select { textView.setSelectedRange(select) }
    }

    private func editCurrentDiagram(_ change: (String) -> String?) {
        guard let range = currentDiagramRange else {
            NSSound.beep()
            return
        }
        let source = (textView.string as NSString).substring(with: range)
        guard let changed = change(source), changed != source else {
            NSSound.beep()
            return
        }
        let caret = textView.selectedRange()
        replaceText(in: range, with: changed)
        // Keep the cursor in the diagram (front matter may have moved the text below it).
        let shift = (changed as NSString).length - (source as NSString).length
        let location = min(max(range.location, caret.location + (caret.location > range.location ? shift : 0)),
                           (textView.string as NSString).length)
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    // MARK: Actions (tags index the lists above)

    @objc func insertDiagramTemplate(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        guard diagramsAllowed, MermaidEdit.templates.indices.contains(tag) else { NSSound.beep(); return }
        let template = MermaidEdit.templates[tag]
        let text = MermaidEdit.insertion(template, kind: documentKind)
        let all = textView.string as NSString
        if documentKind == .mermaid {
            // A diagram file holds one diagram: the template replaces it (⌘Z brings it back).
            replaceText(in: NSRange(location: 0, length: all.length), with: text,
                        select: NSRange(location: 0, length: 0))
            return
        }
        // Markdown: a block of its own at the cursor, on fresh lines.
        let at = textView.selectedRange()
        let before = at.location > 0 && all.character(at: at.location - 1) != 10 ? "\n\n" : ""
        replaceText(in: at, with: before + text,
                    select: NSRange(location: at.location + (before as NSString).length + 11, length: 0))
    }

    @objc func setDiagramDirection(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        guard Self.diagramDirections.indices.contains(tag) else { return }
        editCurrentDiagram { MermaidEdit.settingDirection($0, Self.diagramDirections[tag]) }
    }

    @objc func setDiagramLook(_ sender: Any?) {
        setDiagramConfig("look", Self.diagramLooks, sender)
    }

    @objc func setDiagramLayout(_ sender: Any?) {
        setDiagramConfig("layout", Self.diagramLayouts, sender)
    }

    @objc func setDiagramTheme(_ sender: Any?) {
        setDiagramConfig("theme", Self.diagramThemes, sender)
    }

    private func setDiagramConfig(_ key: String, _ options: [(title: String, value: String?)], _ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        guard options.indices.contains(tag) else { return }
        editCurrentDiagram { MermaidEdit.settingConfig($0, key: key, value: options[tag].value) }
    }

    /// Check marks and enabled state for the Diagram menu.
    func validateDiagramItem(_ item: NSMenuItem) -> Bool? {
        func mark(_ key: String, _ options: [(title: String, value: String?)]) -> Bool {
            guard let source = currentDiagramSource else { item.state = .off; return false }
            item.state = options.indices.contains(item.tag)
                && options[item.tag].value == MermaidEdit.configValue(source, key: key) ? .on : .off
            return true
        }
        switch item.action {
        case #selector(insertDiagramTemplate(_:)):
            return diagramsAllowed
        case #selector(setDiagramDirection(_:)):
            guard let source = currentDiagramSource, let dir = MermaidEdit.direction(source) else {
                item.state = .off
                return false
            }
            item.state = Self.diagramDirections.indices.contains(item.tag)
                && Self.diagramDirections[item.tag] == dir ? .on : .off
            return true
        case #selector(setDiagramLook(_:)): return mark("look", Self.diagramLooks)
        case #selector(setDiagramLayout(_:)): return mark("layout", Self.diagramLayouts)
        case #selector(setDiagramTheme(_:)): return mark("theme", Self.diagramThemes)
        default: return nil
        }
    }

    // MARK: From the picture back to the text

    /// Where `source` (a diagram as the preview drew it) is in the document.
    private func range(ofDiagram source: String) -> NSRange? {
        let all = textView.string as NSString
        if documentKind == .mermaid { return NSRange(location: 0, length: all.length) }
        let found = all.range(of: source)
        return found.location == NSNotFound ? nil : found
    }

    /// A block clicked in the preview: put the cursor on the line that defines it.
    func revealDiagramNode(source: String, id: String, label: String) {
        guard let diagram = range(ofDiagram: source),
              let line = MermaidEdit.lineRange(in: source, nodeID: id, label: label) else { return }
        let target = NSRange(location: diagram.location + line.location, length: line.length)
        guard NSMaxRange(target) <= (textView.string as NSString).length else { return }
        textView.setSelectedRange(NSRange(location: target.location + (line.length > 0 ? line.length : 0), length: 0))
        textView.scrollRangeToVisible(target)
        textView.showFindIndicator(for: target)
        view.window?.makeFirstResponder(textView)
    }

    /// The line Mermaid could not read gets a red dotted underline until the next edit.
    func markDiagramError(source: String, line: Int) {
        clearDiagramError()
        guard let diagram = range(ofDiagram: source),
              let lineRange = MermaidEdit.lineRange(in: source, line: line),
              let lm = textView.layoutManager else { return }
        var target = NSRange(location: diagram.location + lineRange.location, length: lineRange.length)
        guard NSMaxRange(target) <= (textView.string as NSString).length else { return }
        if target.length == 0 { target.length = min(1, (textView.string as NSString).length - target.location) }
        lm.addTemporaryAttributes([
            .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
            .underlineColor: NSColor.systemRed,
        ], forCharacterRange: target)
    }

    func clearDiagramError() {
        guard let lm = textView.layoutManager else { return }
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        lm.removeTemporaryAttribute(.underlineStyle, forCharacterRange: all)
        lm.removeTemporaryAttribute(.underlineColor, forCharacterRange: all)
    }
}
