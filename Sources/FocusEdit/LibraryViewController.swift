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

/// Leading sidebar, the Library: one folder you choose, shown as a tree of the
/// documents FocusEdit opens (txt, md, rtf, fountain) and its subfolders.
/// Double-click opens a document (or opens and closes a subfolder). Choose the folder with the header
/// button, Library ▸ Link Directory…, or by dropping a folder on the sidebar.
final class LibraryViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {

    var onOpenFile: ((URL) -> Void)?

    private let scrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let placeholder = NSTextField(wrappingLabelWithString:
        "Keep a folder of your writing here: its documents (.txt, .md, .rtf, .fountain) "
        + "are listed and open with a double-click.")
    private let chooseButton = NSButton(title: "Choose Folder…", target: nil, action: #selector(MainSplitViewController.linkLibraryDirectory(_:)))
    private let titleLabel = NSTextField(labelWithString: "LIBRARY")
    private let folderLabel = NSTextField(labelWithString: "")
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

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        placeholder.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 11)
        placeholder.alignment = .center
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small
        let empty = NSStackView(views: [placeholder, chooseButton])
        empty.orientation = .vertical
        empty.spacing = 10
        empty.translatesAutoresizingMaskIntoConstraints = false
        emptyState = empty

        // Header: what this is, which folder, and buttons to change or reload it.
        titleLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        folderLabel.font = .systemFont(ofSize: 12, weight: .medium)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let change = headerButton("folder.badge.gearshape", "Choose another folder (Library ▸ Link Directory…)",
                                  #selector(MainSplitViewController.linkLibraryDirectory(_:)))
        let reload = headerButton("arrow.clockwise", "Reload the folder", #selector(reloadFolder))
        reload.target = self
        let names = NSStackView(views: [titleLabel, folderLabel])
        names.orientation = .vertical
        names.alignment = .leading
        names.spacing = 1
        let header = NSStackView(views: [names, NSView(), reload, change])
        header.orientation = .horizontal
        header.spacing = 4
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 6, right: 8)
        header.translatesAutoresizingMaskIntoConstraints = false
        headerView = header

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let container = DropView()
        container.onDropFolder = { [weak self] url in self?.link(url: url) }
        container.addSubview(header)
        container.addSubview(scrollView)
        container.addSubview(empty)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 14),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14),
            placeholder.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
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
        folderLabel.stringValue = url.lastPathComponent
        folderLabel.toolTip = url.path
        outlineView.reloadData()
        refreshPlaceholder()
    }

    private var emptyState: NSView?
    private var headerView: NSView?

    private func refreshPlaceholder() {
        emptyState?.isHidden = root != nil
        headerView?.isHidden = root == nil
        scrollView.isHidden = root == nil
    }

    private func headerButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                              target: nil, action: action)
        button.isBordered = false
        button.toolTip = tip
        button.contentTintColor = .secondaryLabelColor
        return button
    }

    /// Files added or removed outside the app appear when the folder is read again.
    @objc func reloadFolder() {
        guard let url = root?.url else { return }
        let expanded = (0..<outlineView.numberOfRows).compactMap { row -> URL? in
            guard let node = outlineView.item(atRow: row) as? FileNode, outlineView.isItemExpanded(node) else { return nil }
            return node.url
        }
        link(url: url)
        // Open the same subfolders again (rows appear as their parents expand).
        var row = 0
        while row < outlineView.numberOfRows {
            if let node = outlineView.item(atRow: row) as? FileNode, expanded.contains(node.url) {
                outlineView.expandItem(node)
            }
            row += 1
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        reloadFolder()
    }

    @objc private func doubleClicked() {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? FileNode else { return }
        if node.isDirectory {
            outlineView.isItemExpanded(node) ? outlineView.collapseItem(node) : outlineView.expandItem(node)
        } else {
            onOpenFile?(node.url)
        }
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

/// The sidebar accepts a folder dropped on it: that folder becomes the library.
private final class DropView: NSView {
    var onDropFolder: ((URL) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func folder(_ sender: NSDraggingInfo) -> URL? {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]
        guard let url = urls?.first,
              (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
        return url
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { folder(sender) == nil ? [] : .link }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = folder(sender) else { return false }
        onDropFolder?(url)
        return true
    }
}
