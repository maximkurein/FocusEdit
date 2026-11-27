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

    /// Mermaid works in Markdown, plain text (a ```mermaid block) and diagram files.
    var diagramsAllowed: Bool { documentKind == .markdown || documentKind == .plain || documentKind == .mermaid }

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

    /// Block, Arrow or Group (tag = `MermaidEdit.Element`) after the cursor's line, with
    /// its placeholder text selected so typing replaces it.
    @objc func insertDiagramElement(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag ?? 0
        guard let element = MermaidEdit.Element(rawValue: tag), let range = currentDiagramRange else {
            NSSound.beep()
            return
        }
        let all = textView.string as NSString
        let source = all.substring(with: range)
        let caret = min(max(textView.selectedRange().location - range.location, 0), (source as NSString).length)
        let line = (source as NSString).substring(to: caret).components(separatedBy: "\n").count - 1
        guard let result = MermaidEdit.inserting(element, in: source, afterLine: line) else {
            NSSound.beep()
            return
        }
        replaceText(in: range, with: result.source,
                    select: NSRange(location: range.location + result.select.location, length: result.select.length))
        textView.scrollRangeToVisible(textView.selectedRange())
        view.window?.makeFirstResponder(textView)
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
        case #selector(insertDiagramElement(_:)):
            return currentDiagramSource.map(MermaidEdit.canInsertElements) ?? false
        case #selector(setDiagramDirection(_:)):
            guard let source = currentDiagramSource, let dir = MermaidEdit.direction(source) else {
                item.state = .off
                return false
            }
            item.state = Self.diagramDirections.indices.contains(item.tag)
                && Self.diagramDirections[item.tag] == dir ? .on : .off
            return true
        case #selector(setDiagramBlockShape(_:)):
            let p = diagramProperties
            item.state = p?.shape?.rawValue == item.tag && p?.block != nil ? .on : .off
            return p?.block != nil
        case #selector(setDiagramBlockColor(_:)):
            let p = diagramProperties
            let current = p?.color.map { $0.rawValue + 1 } ?? (p?.styled == true ? -1 : 0)
            item.state = current == item.tag && p?.block != nil ? .on : .off
            return p?.block != nil
        case #selector(setDiagramArrow(_:)):
            let p = diagramProperties
            item.state = p?.arrow?.rawValue == item.tag ? .on : .off
            return p?.arrow != nil
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

    /// A block renamed in the picture (double-click on it): its label in the text changes.
    func renameDiagramNode(source: String, id: String, text: String) {
        guard let diagram = range(ofDiagram: source),
              let renamed = MermaidEdit.renaming((textView.string as NSString).substring(with: diagram),
                                                 id: id, to: text) else {
            NSSound.beep()
            return
        }
        replaceText(in: diagram, with: renamed)
        if let line = MermaidEdit.lineRange(in: renamed, nodeID: id, label: text) {
            textView.setSelectedRange(NSRange(location: diagram.location + NSMaxRange(line), length: 0))
        }
    }

    // MARK: Mouse editing in the picture

    /// The document's own text of the diagram the preview drew from `source`, and where it is.
    private func diagramText(_ source: String) -> (range: NSRange, text: String)? {
        guard let range = range(ofDiagram: source) else { return nil }
        return (range, (textView.string as NSString).substring(with: range))
    }

    /// Dragged from one block to another: an arrow between them.
    func connectDiagramNodes(source: String, from: String, to: String) {
        guard let d = diagramText(source),
              let changed = MermaidEdit.connecting(d.text, from: from, to: to) else { NSSound.beep(); return }
        replaceText(in: d.range, with: changed)
    }

    /// The block menu in the picture: `next`, `duplicate` or `delete`.
    func diagramNodeAction(source: String, id: String, action: String) {
        guard let d = diagramText(source) else { NSSound.beep(); return }
        let range = d.range, text = d.text
        switch action {
        case "next":
            guard let r = MermaidEdit.addingNext(text, id: id) else { NSSound.beep(); return }
            replaceText(in: range, with: r.source,
                        select: NSRange(location: range.location + r.select.location, length: r.select.length))
            textView.scrollRangeToVisible(textView.selectedRange())
        case "duplicate":
            guard let r = MermaidEdit.duplicating(text, id: id) else { NSSound.beep(); return }
            replaceText(in: range, with: r.source)
        case "delete":
            guard let changed = MermaidEdit.deleting(text, id: id) else { NSSound.beep(); return }
            replaceText(in: range, with: changed)
        default:
            break
        }
    }

    // MARK: Properties of the block / arrow on the cursor's line

    struct DiagramProperties: Equatable {
        var block: String?
        var shape: MermaidEdit.Shape?
        var color: MermaidEdit.Color?
        var styled = false
        var arrow: MermaidEdit.Arrow?
    }

    /// The diagram under the cursor, its text and the cursor's line in it (0-based).
    private var cursorInDiagram: (range: NSRange, text: String, line: Int)? {
        guard let range = currentDiagramRange else { return nil }
        let text = (textView.string as NSString).substring(with: range)
        let caret = min(max(textView.selectedRange().location - range.location, 0), (text as NSString).length)
        let line = (text as NSString).substring(to: caret).components(separatedBy: "\n").count - 1
        return (range, text, line)
    }

    /// The diagram under the cursor and the block on the cursor's line, for the preview
    /// to outline it; nil outside a flowchart block.
    var cursorDiagramBlock: (source: String, id: String)? {
        guard let c = cursorInDiagram, ["flowchart", "graph"].contains(MermaidEdit.diagramType(c.text) ?? ""),
              let id = MermaidEdit.block(c.text, line: c.line) else { return nil }
        return (c.text, id)
    }

    // MARK: Completion inside a diagram

    /// Suggestions while typing in a diagram: its block ids, Mermaid words for its kind,
    /// the diagram kinds on its first line, config values in its front matter. nil
    /// outside a diagram (the usual word completion applies).
    func diagramCompletions(prefix: String, linePrefix: String) -> [String]? {
        guard diagramsAllowed, let c = cursorInDiagram else { return nil }
        return MermaidEdit.completions(prefix: prefix, linePrefix: linePrefix, source: c.text, line: c.line)
    }

    /// What the Properties of the Diagrams tab show; nil outside a flowchart.
    var diagramProperties: DiagramProperties? {
        guard let c = cursorInDiagram, ["flowchart", "graph"].contains(MermaidEdit.diagramType(c.text) ?? "") else { return nil }
        var p = DiagramProperties()
        p.arrow = MermaidEdit.arrow(c.text, line: c.line)
        if let id = MermaidEdit.block(c.text, line: c.line) {
            p.block = id
            p.shape = MermaidEdit.shape(c.text, id: id)
            p.color = MermaidEdit.color(c.text, id: id)
            p.styled = MermaidEdit.hasStyle(c.text, id: id)
        }
        return p
    }

    private func editCursorBlock(_ change: (String, String, Int) -> String?) {
        guard let c = cursorInDiagram, let id = MermaidEdit.block(c.text, line: c.line),
              let changed = change(c.text, id, c.line), changed != c.text else { NSSound.beep(); return }
        let caret = textView.selectedRange()
        replaceText(in: c.range, with: changed)
        textView.setSelectedRange(NSRange(location: min(caret.location, (textView.string as NSString).length), length: 0))
    }

    /// Edit ▸ Diagram ▸ Block Shape (tag = `MermaidEdit.Shape`).
    @objc func setDiagramBlockShape(_ sender: Any?) {
        guard let shape = MermaidEdit.Shape(rawValue: (sender as? NSMenuItem)?.tag ?? -1) else { return }
        editCursorBlock { text, id, _ in MermaidEdit.settingShape(text, id: id, shape) }
    }

    /// Edit ▸ Diagram ▸ Block Colour (tag 0 = none, then `MermaidEdit.Color` + 1).
    @objc func setDiagramBlockColor(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? 0
        editCursorBlock { text, id, _ in MermaidEdit.settingColor(text, id: id, MermaidEdit.Color(rawValue: tag - 1)) }
    }

    /// Edit ▸ Diagram ▸ Arrow (tag = `MermaidEdit.Arrow`): the arrow on the cursor's line.
    @objc func setDiagramArrow(_ sender: Any?) {
        guard let kind = MermaidEdit.Arrow(rawValue: (sender as? NSMenuItem)?.tag ?? -1),
              let c = cursorInDiagram, let changed = MermaidEdit.settingArrow(c.text, line: c.line, kind),
              changed != c.text else { NSSound.beep(); return }
        let caret = textView.selectedRange()
        replaceText(in: c.range, with: changed)
        textView.setSelectedRange(NSRange(location: min(caret.location, (textView.string as NSString).length), length: 0))
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
