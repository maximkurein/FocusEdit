import AppKit

/// Document window content: [Library | Editor | Outline] with collapsible
/// sidebars, plus HTML preview/export and the Library menu actions. Routed to
/// via the responder chain from the menu.
final class MainSplitViewController: NSSplitViewController, NSMenuItemValidation, NSToolbarItemValidation {

    let library = LibraryViewController()
    let editor = EditorViewController()
    let outline = OutlineViewController()

    private var libraryItem: NSSplitViewItem!
    private var editorItem: NSSplitViewItem!
    private var outlineItem: NSSplitViewItem!

    private var previewController: PreviewWindowController?

    override func viewDidLoad() {
        super.viewDidLoad()

        libraryItem = NSSplitViewItem(sidebarWithViewController: library)
        libraryItem.minimumThickness = 180
        libraryItem.maximumThickness = 360
        libraryItem.canCollapse = true

        editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 380

        // macOS 14+: a trailing inspector (floating glass panel on macOS 26).
        if #available(macOS 14.0, *) {
            outlineItem = NSSplitViewItem(inspectorWithViewController: outline)
        } else {
            outlineItem = NSSplitViewItem(sidebarWithViewController: outline)
        }
        outlineItem.minimumThickness = 180
        outlineItem.maximumThickness = 360
        outlineItem.canCollapse = true

        addSplitViewItem(libraryItem)
        addSplitViewItem(editorItem)
        addSplitViewItem(outlineItem)

        libraryItem.isCollapsed = !Preferences.showLibrary
        outlineItem.isCollapsed = !Preferences.showOutline

        editor.onTextChanged = { [weak self] in self?.contentChanged() }
        outline.onSelect = { [weak self] range in self?.editor.scrollTo(range: range) }
        library.onOpenFile = { url in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    /// Entry point used by the document after it sets content.
    func loadDocument(_ text: String, fileExtension ext: String) {
        editor.loadContent(text, fileExtension: ext)
    }

    private func contentChanged() {
        outline.update(text: editor.plainText as NSString, kind: editor.documentKind)
        if let pc = previewController, pc.window?.isVisible == true {
            pc.update(markdown: editor.plainText, dark: editor.themeIsDark)
        }
    }

    /// Editor actions (Modus, Format, theme…) keep working when the library or
    /// outline has keyboard focus: the editor isn't in that responder chain,
    /// so offer it as a supplemental target.
    override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if editor.responds(to: action) { return editor }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    /// The system sidebar toolbar button toggles the library (and remembers it).
    override func toggleSidebar(_ sender: Any?) {
        toggleLibrary(sender)
    }

    // MARK: Hints popover

    private var hintsPopover: NSPopover?

    @objc func showHints(_ sender: Any?) {
        if let shown = hintsPopover, shown.isShown {
            shown.performClose(nil)
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = HintsViewController(kind: editor.documentKind)
        popover.appearance = NSAppearance(named: editor.themeIsDark ? .darkAqua : .aqua)
        hintsPopover = popover

        if #available(macOS 14.0, *), let item = sender as? NSToolbarItem {
            popover.show(relativeTo: item)
        } else if #available(macOS 14.0, *),
                  let item = view.window?.toolbar?.items.first(where: { $0.itemIdentifier == .hints }),
                  view.window?.toolbar?.isVisible == true {
            popover.show(relativeTo: item)
        } else {
            let anchor = editor.view
            popover.show(relativeTo: NSRect(x: anchor.bounds.midX, y: anchor.bounds.maxY - 8,
                                            width: 1, height: 1),
                         of: anchor, preferredEdge: .minY)
        }
    }

    // MARK: Sidebar toggles

    @objc func toggleLibrary(_ sender: Any?) {
        libraryItem.animator().isCollapsed.toggle()
        Preferences.showLibrary = !libraryItem.isCollapsed
    }

    @objc func toggleOutline(_ sender: Any?) {
        outlineItem.animator().isCollapsed.toggle()
        Preferences.showOutline = !outlineItem.isCollapsed
    }

    // MARK: Library menu

    @objc func linkLibraryDirectory(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Link"
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            self?.library.link(url: url)
            if self?.libraryItem.isCollapsed == true { self?.toggleLibrary(nil) }
        }
    }

    // MARK: Preview / export

    @objc func togglePreview(_ sender: Any?) {
        guard editor.documentKind.supportsHTML else { NSSound.beep(); return }
        if let pc = previewController, pc.window?.isVisible == true {
            pc.close()
        } else {
            let pc = previewController ?? PreviewWindowController()
            previewController = pc
            pc.update(markdown: editor.plainText, dark: editor.themeIsDark)
            pc.showWindow(nil)
        }
    }

    @objc func exportAsHTML(_ sender: Any?) {
        guard editor.documentKind.supportsHTML else { NSSound.beep(); return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "export.html"
        panel.beginSheetModal(for: view.window ?? NSApp.keyWindow ?? NSWindow()) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let self else { return }
            let html = MarkdownToHTML.document(self.editor.plainText, dark: false)
            try? html.data(using: .utf8)?.write(to: url)
        }
    }

    @objc func copyAsHTML(_ sender: Any?) {
        guard editor.documentKind.supportsHTML else { NSSound.beep(); return }
        let html = MarkdownToHTML.document(editor.plainText, dark: false)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(html, forType: .html)
        pb.setString(html, forType: .string)
    }

    // MARK: Validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleLibrary(_:)):
            item.title = libraryItem.isCollapsed ? "Show Library" : "Hide Library"
        case #selector(toggleOutline(_:)):
            item.title = outlineItem.isCollapsed ? "Show Outline" : "Hide Outline"
        case #selector(togglePreview(_:)):
            let visible = previewController?.window?.isVisible == true
            item.title = visible ? "Hide Preview" : "Show Preview"
            return editor.documentKind.supportsHTML
        case #selector(exportAsHTML(_:)), #selector(copyAsHTML(_:)):
            return editor.documentKind.supportsHTML
        default:
            break
        }
        return true
    }
}
