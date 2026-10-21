import AppKit

/// Document window content: [Library | Editor | Preview | Outline] with collapsible
/// sidebars and preview pane, plus HTML export and the Library menu actions. Routed to
/// via the responder chain from the menu.
final class MainSplitViewController: NSSplitViewController, NSMenuItemValidation, NSToolbarItemValidation {

    let library = LibraryViewController()
    let editor = EditorViewController()
    let preview = PreviewViewController()
    let outline = OutlineViewController()

    private var libraryItem: NSSplitViewItem!
    private var editorItem: NSSplitViewItem!
    private var previewItem: NSSplitViewItem!
    private var scrollObserver: NSObjectProtocol?
    /// The editor that was just moved by code ignores its own scrolling for a moment.
    private var editorQuietUntil = Date.distantPast
    private var outlineItem: NSSplitViewItem!

    override func viewDidLoad() {
        super.viewDidLoad()

        libraryItem = NSSplitViewItem(sidebarWithViewController: library)
        libraryItem.minimumThickness = 180
        libraryItem.maximumThickness = 360
        libraryItem.canCollapse = true

        editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 380

        // The live preview beside the text; hidden until View ▸ Show Preview.
        previewItem = NSSplitViewItem(viewController: preview)
        previewItem.minimumThickness = 300
        previewItem.canCollapse = true
        previewItem.isCollapsed = true

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
        addSplitViewItem(previewItem)
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
        if !editor.documentKind.supportsHTML, viewMode != .edit { setView(.edit) }
        outline.update(text: editor.plainText as NSString, kind: editor.documentKind)
        if !previewItem.isCollapsed {
            preview.update(markdown: editor.plainText, dark: editor.themeIsDark)
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
        popover.contentViewController = HintsViewController(kind: editor.documentKind, vim: editor.vimEnabled)
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

    // MARK: Preview beside the text / export

    var viewMode: ViewMode {
        if previewItem.isCollapsed { return .edit }
        return editorItem.isCollapsed ? .preview : .split
    }

    /// View ▸ Preview (⌥⌘P) and the eye button: Edit → Split → Preview → Edit.
    @objc func togglePreview(_ sender: Any?) {
        guard editor.documentKind.supportsHTML else { NSSound.beep(); return }
        setView(viewMode.next)
    }

    func setView(_ mode: ViewMode) {
        let from = viewMode
        guard mode != from else { return }
        let tv = editor.textView
        switch mode {
        case .edit, .split:
            if from == .edit {
                preview.update(markdown: editor.plainText, dark: editor.themeIsDark)
                syncScrolling()
            }
            if from == .preview {
                // Back to the text where the reader was.
                let caret = ViewMode.lineStart(forRatio: preview.currentRatio, in: tv.string)
                editorItem.isCollapsed = false
                editorItem.canCollapse = false
                tv.setSelectedRange(NSRange(location: caret, length: 0))
                tv.scrollLine(containing: caret, toHeight: 0.5)
                tv.refreshFocusEffects()
            }
            if mode == .edit { previewItem.animator().isCollapsed = true }
            if mode == .split, previewItem.isCollapsed { previewItem.animator().isCollapsed = false }
            view.window?.makeFirstResponder(tv)
            stopEscapeMonitor()
        case .preview:
            // The page opens where the cursor was.
            let ratio = ViewMode.ratio(forCaret: tv.selectedRange().location, in: tv.string)
            if from == .edit {
                preview.update(markdown: editor.plainText, dark: editor.themeIsDark)
                syncScrolling()
            }
            previewItem.isCollapsed = false
            editorItem.canCollapse = true
            editorItem.isCollapsed = true
            preview.scroll(toRatio: ratio)
            view.window?.makeFirstResponder(preview.view)
            startEscapeMonitor()
        }
    }

    /// Esc in Preview goes back to editing (the web view would swallow a menu key).
    private var escapeMonitor: Any?

    private func startEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53, event.window === self.view.window,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  self.viewMode == .preview else { return event }
            self.setView(.edit)
            return nil
        }
    }

    private func stopEscapeMonitor() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    /// Scrolling the editor scrolls the preview and the other way round (relative position).
    private func syncScrolling() {
        guard scrollObserver == nil, let clip = editor.textView.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { [weak self] _ in
            guard let self, !self.previewItem.isCollapsed, Date() >= self.editorQuietUntil else { return }
            self.preview.scroll(toRatio: self.editorScrollRatio())
        }
        preview.onScroll = { [weak self] ratio in self?.scrollEditor(toRatio: ratio) }
    }

    private func editorScrollRatio() -> Double {
        guard let scroll = editor.textView.enclosingScrollView, let doc = scroll.documentView else { return 0 }
        let span = doc.frame.height - scroll.contentView.bounds.height
        return span > 0 ? Double(scroll.contentView.bounds.origin.y / span) : 0
    }

    private func scrollEditor(toRatio ratio: Double) {
        guard let scroll = editor.textView.enclosingScrollView, let doc = scroll.documentView else { return }
        let span = max(0, doc.frame.height - scroll.contentView.bounds.height)
        editorQuietUntil = Date().addingTimeInterval(0.25)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(ratio) * span))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        stopEscapeMonitor()
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

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(togglePreview(_:)):
            ToolbarSymbol.update(item, "eye", on: viewMode != .edit)
            item.toolTip = "View: \(viewMode.title) — click for \(viewMode.next.title) (⌥⌘P)"
            return editor.documentKind.supportsHTML
        case #selector(toggleOutline(_:)):
            ToolbarSymbol.update(item, "sidebar.right", on: !outlineItem.isCollapsed)
        default:
            break
        }
        return true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleLibrary(_:)):
            item.title = libraryItem.isCollapsed ? "Show Library" : "Hide Library"
        case #selector(toggleOutline(_:)):
            item.title = outlineItem.isCollapsed ? "Show Outline" : "Hide Outline"
        case #selector(togglePreview(_:)):
            item.title = viewMode.menuTitle
            return editor.documentKind.supportsHTML
        case #selector(exportAsHTML(_:)), #selector(copyAsHTML(_:)):
            return editor.documentKind.supportsHTML
        default:
            break
        }
        return true
    }
}

/// Edit (text only) → Split (text and live preview) → Preview (the page only).
enum ViewMode {
    case edit, split, preview

    var next: ViewMode {
        switch self {
        case .edit: return .split
        case .split: return .preview
        case .preview: return .edit
        }
    }

    var title: String {
        switch self {
        case .edit: return "Edit"
        case .split: return "Split"
        case .preview: return "Preview"
        }
    }

    /// The View menu item says what choosing it does.
    var menuTitle: String {
        switch self {
        case .edit: return "Show Preview"
        case .split: return "Preview Only"
        case .preview: return "Back to Editing"
        }
    }

    /// Where the cursor's line sits in the text, 0 (first line) to 1 (last line).
    static func ratio(forCaret caret: Int, in text: String) -> Double {
        let ns = text as NSString
        let total = lineCount(ns)
        guard total > 1 else { return 0 }
        let line = lineCount(ns.substring(to: min(caret, ns.length)) as NSString) - 1
        return Double(line) / Double(total - 1)
    }

    /// The start of the line at `ratio` of the text (the reading place in the preview).
    static func lineStart(forRatio ratio: Double, in text: String) -> Int {
        let ns = text as NSString
        let total = lineCount(ns)
        let target = Int((min(1, max(0, ratio)) * Double(total - 1)).rounded())
        var line = 0, location = 0
        while line < target, location < ns.length {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            line += 1
        }
        return location
    }

    private static func lineCount(_ ns: NSString) -> Int {
        var count = 1
        for i in 0..<ns.length where ns.character(at: i) == 10 { count += 1 }
        return count
    }
}
