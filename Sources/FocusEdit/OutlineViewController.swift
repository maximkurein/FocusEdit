import AppKit

/// Trailing sidebar listing the document headings; selecting one jumps the
/// editor to that line. The heading the cursor is under stays selected.
///
/// In Markdown, plain text and diagram files a second tab, Diagrams, lists the Mermaid diagrams
/// instead (`MermaidEdit.diagrams`), with buttons below that add a block, an arrow or a
/// group to the diagram under the cursor, and a menu of templates.
final class OutlineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    enum Tab: Int { case headings, diagrams }

    var onSelect: ((NSRange) -> Void)?
    /// Block / Arrow / Group (a `MermaidEdit.Element`) for the diagram under the cursor.
    var onInsertElement: ((Int) -> Void)?
    /// A template (index in `MermaidEdit.templates`) at the cursor.
    var onInsertTemplate: ((Int) -> Void)?
    /// A Properties menu was used: the editor action and the item's tag.
    var onProperty: ((Selector, Int) -> Void)?
    /// The Properties became visible and want the cursor's block.
    var onShowProperties: (() -> Void)?

    private let propertiesTitle = NSTextField(labelWithString: "")
    private let shapePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let colorPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let arrowPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var properties: EditorViewController.DiagramProperties?

    private let tabs = NSSegmentedControl(labels: ["Headings", "Diagrams"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let toolbar = NSStackView()
    private var tab: Tab = .headings
    /// The tab chosen for Markdown; a diagram file always shows its diagram.
    private var markdownTab: Tab = .headings
    private var kind: DocumentKind = .plain
    private var text: NSString = ""
    /// The list starts under the tabs and ends above the buttons, or uses that room
    /// when they are hidden.
    private var listUnderTabs: NSLayoutConstraint?
    private var listAtTop: NSLayoutConstraint?
    private var listAboveToolbar: NSLayoutConstraint?
    private var listAtBottom: NSLayoutConstraint?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let placeholder = NSTextField(labelWithString: "No outline available.")
    private var items: [OutlineItem] = []
    private var cursor = 0

    override func loadView() {
        let column = NSTableColumn(identifier: .init("title"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .default
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .sourceList
        tableView.target = self
        tableView.action = #selector(rowClicked)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 11)
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.controlSize = .small
        tabs.segmentDistribution = .fillEqually
        tabs.selectedSegment = 0
        tabs.translatesAutoresizingMaskIntoConstraints = false

        // Below the diagram list: add to the diagram under the cursor.
        func button(_ title: String, _ symbol: String, _ element: MermaidEdit.Element, _ tip: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: #selector(elementClicked(_:)))
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            b.imagePosition = .imageLeading
            b.controlSize = .small
            b.bezelStyle = .rounded
            b.tag = element.rawValue
            b.toolTip = tip
            return b
        }
        let templates = NSPopUpButton(frame: .zero, pullsDown: true)
        templates.controlSize = .small
        templates.addItem(withTitle: "Template")
        for (i, t) in MermaidEdit.templates.enumerated() {
            templates.addItem(withTitle: t.title)
            templates.lastItem?.tag = i
            templates.lastItem?.target = self
            templates.lastItem?.action = #selector(templateChosen(_:))
        }
        templates.toolTip = "Insert a ready diagram at the cursor"
        let row = NSStackView(views: [
            button("Block", "square", .block, "Add a block (a participant in a sequence) after the cursor's line"),
            button("Arrow", "arrow.right", .arrow, "Add an arrow from the block on the cursor's line (a message in a sequence)"),
            button("Group", "square.dashed", .group, "Add a group (subgraph; a loop in a sequence)"),
        ])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 4
        // Properties of the block / arrow on the cursor's line (flowcharts).
        func fill(_ popup: NSPopUpButton, _ titles: [String], _ tags: [Int], _ action: Selector) {
            popup.controlSize = .small
            popup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            for (t, tag) in zip(titles, tags) {
                popup.addItem(withTitle: t)
                popup.lastItem?.tag = tag
            }
            popup.target = self
            popup.action = action
        }
        fill(shapePopup, MermaidEdit.Shape.allCases.map(\.title), MermaidEdit.Shape.allCases.map(\.rawValue),
             #selector(shapeChosen(_:)))
        fill(colorPopup, ["None"] + MermaidEdit.Color.allCases.map(\.title) + ["Custom"],
             Array(0...MermaidEdit.Color.allCases.count) + [-1], #selector(colorChosen(_:)))
        colorPopup.lastItem?.isEnabled = false
        colorPopup.autoenablesItems = false
        fill(arrowPopup, MermaidEdit.Arrow.allCases.map(\.title), MermaidEdit.Arrow.allCases.map(\.rawValue),
             #selector(arrowChosen(_:)))
        propertiesTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        propertiesTitle.textColor = .secondaryLabelColor
        propertiesTitle.lineBreakMode = .byTruncatingTail
        func label(_ text: String) -> NSTextField {
            let l = NSTextField(labelWithString: text)
            l.font = .systemFont(ofSize: 11)
            l.textColor = .secondaryLabelColor
            return l
        }
        let grid = NSGridView(views: [
            [label("Shape"), shapePopup],
            [label("Color"), colorPopup],
            [label("Arrow"), arrowPopup],
        ])
        grid.rowSpacing = 4
        grid.columnSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        toolbar.orientation = .vertical
        toolbar.alignment = .width
        toolbar.spacing = 4
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 8, right: 6)
        toolbar.setViews([propertiesTitle, grid, row, templates], in: .top)
        toolbar.setCustomSpacing(8, after: grid)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(tabs)
        container.addSubview(scrollView)
        container.addSubview(placeholder)
        container.addSubview(toolbar)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        listUnderTabs = scrollView.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 4)
        listAtTop = scrollView.topAnchor.constraint(equalTo: container.topAnchor)
        listAboveToolbar = scrollView.bottomAnchor.constraint(equalTo: toolbar.topAnchor)
        listAtBottom = scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
        ])
        view = container
        showChrome()
    }

    /// The tabs only where there can be diagrams; the buttons only on the Diagrams tab.
    private func showChrome() {
        let diagramsPossible = kind == .markdown || kind == .plain || kind == .mermaid
        tabs.isHidden = !diagramsPossible || kind == .mermaid
        listUnderTabs?.isActive = false
        listAtTop?.isActive = false
        (tabs.isHidden ? listAtTop : listUnderTabs)?.isActive = true
        toolbar.isHidden = tab != .diagrams
        listAboveToolbar?.isActive = false
        listAtBottom?.isActive = false
        (toolbar.isHidden ? listAtBottom : listAboveToolbar)?.isActive = true
        tabs.selectedSegment = tab.rawValue
    }

    @objc private func tabChanged() {
        markdownTab = Tab(rawValue: tabs.selectedSegment) ?? .headings
        tab = markdownTab
        reload()
    }

    @objc private func shapeChosen(_ sender: NSPopUpButton) {
        onProperty?(#selector(EditorViewController.setDiagramBlockShape(_:)), sender.selectedTag())
    }

    @objc private func colorChosen(_ sender: NSPopUpButton) {
        onProperty?(#selector(EditorViewController.setDiagramBlockColor(_:)), sender.selectedTag())
    }

    @objc private func arrowChosen(_ sender: NSPopUpButton) {
        onProperty?(#selector(EditorViewController.setDiagramArrow(_:)), sender.selectedTag())
    }

    /// Properties are worth computing only while the Diagrams tab is on screen.
    var showsProperties: Bool { isViewLoaded && tab == .diagrams }

    /// The block / arrow on the cursor's line, or nil outside a flowchart.
    func setProperties(_ p: EditorViewController.DiagramProperties?) {
        guard p != properties || propertiesTitle.stringValue.isEmpty else { return }
        properties = p
        let block = p?.block
        if let block {
            propertiesTitle.stringValue = "Block " + block + (p?.arrow != nil ? " · arrow" : "")
        } else if p?.arrow != nil {
            propertiesTitle.stringValue = "Arrow"
        } else {
            propertiesTitle.stringValue = p == nil ? "Properties: in a flowchart" : "Properties: put the cursor on a block"
        }
        shapePopup.isEnabled = block != nil
        colorPopup.isEnabled = block != nil
        arrowPopup.isEnabled = p?.arrow != nil
        shapePopup.selectItem(withTag: p?.shape?.rawValue ?? 0)
        colorPopup.selectItem(withTag: p?.color.map { $0.rawValue + 1 } ?? (p?.styled == true ? -1 : 0))
        arrowPopup.selectItem(withTag: p?.arrow?.rawValue ?? 0)
    }

    @objc private func elementClicked(_ sender: NSButton) {
        onInsertElement?(sender.tag)
    }

    @objc private func templateChosen(_ sender: NSMenuItem) {
        onInsertTemplate?(sender.tag)
    }

    /// Show the Diagrams tab (Edit ▸ Diagram ▸ Show Diagram List).
    func showDiagrams() {
        guard kind == .markdown || kind == .plain || kind == .mermaid else { return }
        if kind != .mermaid { markdownTab = .diagrams }
        tab = .diagrams
        reload()
    }

    func update(text: NSString, kind: DocumentKind) {
        self.text = text
        self.kind = kind
        switch kind {
        case .mermaid: tab = .diagrams
        case .markdown, .plain: tab = markdownTab
        default: tab = .headings
        }
        reload()
    }

    private func reload() {
        items = tab == .diagrams
            ? MermaidEdit.diagrams(in: text, kind: kind)
            : OutlineExtractor.items(from: text, kind: kind)
        placeholder.stringValue = tab == .diagrams
            ? "No diagrams yet."
            : "No outline available."
        placeholder.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty
        if isViewLoaded { showChrome() }
        tableView.reloadData()
        showActive(force: true)
        if tab == .diagrams { onShowProperties?() }
    }

    /// The cursor moved: select the heading it belongs to (cheap; runs on every move).
    func setCursor(_ location: Int) {
        cursor = location
        showActive(force: false)
    }

    private func showActive(force: Bool) {
        let active = (tab == .diagrams
            ? items.firstIndex { cursor >= $0.range.location && cursor <= NSMaxRange($0.range) }
            : OutlineExtractor.active(items, cursor: cursor)) ?? -1
        guard force || active != tableView.selectedRow else { return }
        if active >= 0 {
            tableView.selectRowIndexes([active], byExtendingSelection: false)
            tableView.scrollRowToVisible(active)
        } else {
            tableView.deselectAll(nil)
        }
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard row >= 0, row < items.count else { return }
        onSelect?(items[row].range)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                let tf = NSTextField(labelWithString: "")
                tf.lineBreakMode = .byTruncatingTail
                tf.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(tf)
                c.textField = tf
                c.identifier = id
                NSLayoutConstraint.activate([
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -6),
                ])
                c.addConstraint(tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 6))
                return c
            }()

        let item = items[row]
        let indent = String(repeating: "   ", count: max(0, item.level - 1))
        cell.textField?.stringValue = indent + item.title
        cell.textField?.font = .systemFont(ofSize: item.level == 1 ? 12 : 11,
                                           weight: item.level == 1 ? .medium : .regular)
        cell.textField?.textColor = item.level == 1 ? .labelColor : .secondaryLabelColor
        return cell
    }
}
