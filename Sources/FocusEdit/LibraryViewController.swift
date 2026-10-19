import AppKit

/// A node in the library tree (a linked folder and its documents/subfolders).
final class FileNode {
    let url: URL
    let isDirectory: Bool
    private var loaded: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    var title: String { url.lastPathComponent }

    static let documentExtensions: Set<String> = ["txt", "md", "markdown", "mdown", "mkd", "fountain", "rtf"]

    var children: [FileNode] {
        if let loaded { return loaded }
        guard isDirectory else { loaded = []; return [] }
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let nodes: [FileNode] = entries.compactMap { child in
            let dir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if dir { return FileNode(url: child, isDirectory: true) }
            guard Self.documentExtensions.contains(child.pathExtension.lowercased()) else { return nil }
            return FileNode(url: child, isDirectory: false)
        }
        loaded = nodes.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        return loaded!
    }
}

/// Leading sidebar: browse a linked folder; double-click opens a document.
final class LibraryViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    var onOpenFile: ((URL) -> Void)?

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let placeholder = NSTextField(wrappingLabelWithString:
        "No library linked.\nLibrary ▸ Link Directory… or drag a folder here.")
    private var root: FileNode?

    override func loadView() {
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.style = .sourceList
        outlineView.rowSizeStyle = .default
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked)
        outlineView.registerForDraggedTypes([.fileURL])

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        placeholder.textColor = .tertiaryLabelColor
        placeholder.font = .systemFont(ofSize: 11)
        placeholder.alignment = .center
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scrollView)
        container.addSubview(placeholder)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
        ])
        view = container

        if let path = Preferences.libraryPath {
            link(url: URL(fileURLWithPath: path))
        } else {
            refreshPlaceholder()
        }
    }

    func link(url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        Preferences.libraryPath = url.path
        root = FileNode(url: url, isDirectory: true)
        outlineView.reloadData()
        refreshPlaceholder()
    }

    private func refreshPlaceholder() {
        placeholder.isHidden = root != nil
        scrollView.isHidden = root == nil
    }

    @objc private func doubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode, !node.isDirectory else { return }
        onOpenFile?(node.url)
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let node = item as? FileNode { return node.children.count }
        return root?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FileNode { return node.children[index] }
        return root!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView)
            ?? {
                let c = NSTableCellView()
                let image = NSImageView()
                let tf = NSTextField(labelWithString: "")
                image.translatesAutoresizingMaskIntoConstraints = false
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.lineBreakMode = .byTruncatingTail
                c.addSubview(image); c.addSubview(tf)
                c.imageView = image; c.textField = tf
                c.identifier = id
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    tf.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
        cell.textField?.stringValue = node.title
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: node.url.path)
        return cell
    }
}
