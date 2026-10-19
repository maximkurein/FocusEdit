import AppKit

/// Trailing sidebar listing the document headings; selecting one jumps the
/// editor to that line.
final class OutlineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    var onSelect: ((NSRange) -> Void)?

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let placeholder = NSTextField(labelWithString: "No outline available.")
    private var items: [OutlineItem] = []

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

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(placeholder)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 8),
        ])
        view = container
    }

    func update(text: NSString, kind: DocumentKind) {
        items = OutlineExtractor.items(from: text, kind: kind)
        placeholder.isHidden = !items.isEmpty
        scrollView.isHidden = items.isEmpty
        tableView.reloadData()
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
