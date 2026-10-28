import AppKit

/// Document window content: [Library | Editor | Preview | Outline] with collapsible
/// sidebars and preview pane, plus HTML export and the Library menu actions. Routed to
/// via the responder chain from the menu.
final class MainSplitViewController: NSSplitViewController, NSMenuItemValidation, NSToolbarItemValidation {

    let library = LibraryViewController()
    let editor = EditorViewController()
    let preview = PreviewViewController()
    let outline = OutlineViewController()

    private(set) var libraryItem: NSSplitViewItem!
    private var editorItem: NSSplitViewItem!
    private var previewItem: NSSplitViewItem!
    private var scrollObserver: NSObjectProtocol?
    /// The editor that was just moved by code ignores its own scrolling for a moment.
    private var editorQuietUntil = Date.distantPast
    private(set) var outlineItem: NSSplitViewItem!
    let palette = CommandPaletteController()
    /// Editor's share of the editor+preview area. 0.5 until the reader drags the divider.
    private var editorShare: CGFloat = 0.5
    /// This file has been shown in Split, so reopening uses the saved divider.
    private var seenSplit = false
    /// Ignore the resize notification caused by our own positioning.
    private var applyingLayout = false

    override func viewDidLoad() {
        super.viewDidLoad()

        libraryItem = NSSplitViewItem(sidebarWithViewController: library)
        libraryItem.minimumThickness = 180
        libraryItem.maximumThickness = 360
        libraryItem.canCollapse = true

        editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 320
        editorItem.holdingPriority = NSLayoutConstraint.Priority(251)

        // The live preview beside the text; hidden until View ▸ Show Preview.
        previewItem = NSSplitViewItem(viewController: preview)
        previewItem.minimumThickness = 320
        previewItem.holdingPriority = NSLayoutConstraint.Priority(251)
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
        editor.onCursorMoved = { [weak self] location in self?.outline.setCursor(location) }
        editor.onThemeChanged = { [weak self] in
            guard let self, !self.previewItem.isCollapsed else { return }
            self.preview.update(markdown: self.editor.plainText, colors: self.editor.previewColors)
        }
        preview.fontSize = Double(editor.fontSize)
        editor.onFontSizeChanged = { [weak self] in
            guard let self else { return }
            self.preview.fontSize = Double(self.editor.fontSize)
        }
        startZoomMonitor()
        library.onOpenFile = { url in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
        editor.onFileURLChanged = { [weak self] in self?.saveAppearance() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(splitResized(_:)),
            name: NSSplitView.didResizeSubviewsNotification, object: splitView)
    }

    /// Entry point used by the document after it sets content.
    func loadDocument(_ text: String, fileExtension ext: String) {
        editor.loadContent(text, fileExtension: ext)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateViewSwitcher() // the toolbar did not exist yet when the document loaded
    }

    private func contentChanged() {
        if !editor.documentKind.supportsHTML, viewMode != .edit { setView(.edit) }
        updateViewSwitcher() // Save As can change the kind: Fountain has no preview
        outline.update(text: editor.plainText as NSString, kind: editor.documentKind)
        if !previewItem.isCollapsed {
            preview.update(markdown: editor.plainText, colors: editor.previewColors)
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

    // MARK: Close file

    /// File ▸ Close File (⌘W): as on Windows, closing the last document keeps a window
    /// with an empty one and the start screen. (The window's close button closes it all.)
    @objc func closeFile(_ sender: Any?) {
        guard let window = view.window else { return }
        let frame = window.frame
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        // (If the Save sheet is cancelled the window stays; the observer only acts on a real close.)
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            DispatchQueue.main.async {
                guard NSDocumentController.shared.documents.isEmpty,
                      let doc = try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true) else { return }
                doc.windowControllers.first?.window?.setFrame(frame, display: true)
            }
        }
        window.performClose(sender)
    }
    private var closeObserver: NSObjectProtocol?

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
        // Fountain stays in the editor; plain text and Markdown preview, as on Windows.
        if mode != .edit, !editor.documentKind.supportsHTML { return }
        let tv = editor.textView
        editor.fillsPane = mode == .split
        preview.fillsPane = mode == .split
        switch mode {
        case .edit, .split:
            if from == .edit {
                preview.update(markdown: editor.plainText, colors: editor.previewColors)
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
            if mode == .split {
                // The first time this file is split, open both halves wide enough to read.
                // After that, the divider stays where the reader left it.
                let fit = !seenSplit && !Snapshot.isActive
                if fit { editorShare = 0.5 }
                seenSplit = true
                previewItem.isCollapsed = false
                editorItem.isCollapsed = false
                editorItem.canCollapse = false
                if fit { widenForSplit() }
            }
            view.window?.makeFirstResponder(tv)
            stopEscapeMonitor()
        case .preview:
            // The page opens where the cursor was.
            let ratio = ViewMode.ratio(forCaret: tv.selectedRange().location, in: tv.string)
            if from == .edit {
                preview.update(markdown: editor.plainText, colors: editor.previewColors)
                syncScrolling()
            }
            previewItem.isCollapsed = false
            editorItem.canCollapse = true
            editorItem.isCollapsed = true
            preview.scroll(toRatio: ratio)
            view.window?.makeFirstResponder(preview.view)
            startEscapeMonitor()
        }
        if mode == .split {
            splitView.layoutSubtreeIfNeeded()
            placeEditor(share: editorShare)
        }
        // Passed in, not read back: the split pane may still be animating.
        updateViewSwitcher(mode)
        saveAppearance()
    }

    /// The toolbar's Edit | Split | Preview shows `mode` (default: the current one).
    func updateViewSwitcher(_ mode: ViewMode? = nil) {
        ViewSwitcher.show(mode ?? viewMode, previewable: editor.documentKind.supportsHTML,
                          in: view.window?.toolbar)
    }

    /// The Edit | Split | Preview switcher in the toolbar.
    @objc func selectViewMode(_ sender: Any?) {
        guard let group = sender as? NSToolbarItemGroup,
              ViewMode.allCases.indices.contains(group.selectedIndex) else { return }
        let mode = ViewMode.allCases[group.selectedIndex]
        if mode != .edit, !editor.documentKind.supportsHTML { NSSound.beep(); return }
        setView(mode)
    }

    // MARK: Remembered layout

    /// After the window is on screen (and an empty document has handed over its frame),
    /// put back the view, the pane sizes and the window size this file was closed with.
    func restoreAppearanceIfNeeded() {
        guard !Snapshot.isActive, let path = editor.filePath,
              let saved = DocumentAppearanceStore.load(path) else { return }
        seenSplit = saved.seenSplit
        editorShare = CGFloat(saved.editorShare)
        if let window = view.window,
           DocumentAppearanceStore.usable(width: saved.contentWidth, height: saved.contentHeight) {
            resize(window, content: NSSize(width: saved.contentWidth, height: saved.contentHeight))
        }
        if let mode = ViewMode(storage: saved.mode) {
            setView(mode)
            if mode == .split { placeEditor(share: editorShare) }
        }
    }

    /// Write the current look under the file's path. Untitled documents have nothing to key.
    func saveAppearance() {
        guard !Snapshot.isActive, !applyingLayout, let path = editor.filePath, let window = view.window else { return }
        if viewMode == .split {
            let share = currentEditorShare()
            if share > 0.15, share < 0.85 { editorShare = share }
        }
        let size = window.contentRect(forFrameRect: window.frame).size
        guard DocumentAppearanceStore.usable(width: size.width, height: size.height) else { return }
        DocumentAppearanceStore.save(DocumentAppearance(
            mode: viewMode.storage, editorShare: Double(editorShare),
            contentWidth: Double(size.width), contentHeight: Double(size.height),
            seenSplit: seenSplit), for: path)
    }

    /// The first Split uses a reading width. A window that is already wider is narrowed to it.
    private func widenForSplit() {
        guard let window = view.window else { return }
        let sidebars = (libraryItem.isCollapsed ? 0 : library.view.bounds.width)
            + (outlineItem.isCollapsed ? 0 : outline.view.bounds.width)
        let screen = window.screen?.visibleFrame.width ?? 1600
        let current = window.contentRect(forFrameRect: window.frame).width
        let wanted = ReadingLayout.contentWidth(sidebars: sidebars, screenWidth: screen, current: current)
        guard abs(wanted - current) > 8 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        resize(window, content: NSSize(width: wanted, height: content.height))
    }

    /// Keep the top edge where it is, and keep the window on its screen.
    private func resize(_ window: NSWindow, content size: NSSize) {
        let current = window.contentRect(forFrameRect: window.frame)
        var frame = window.frameRect(forContentRect: NSRect(
            x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height))
        if let screen = window.screen?.visibleFrame {
            frame.size.width = min(frame.width, screen.width)
            frame.size.height = min(frame.height, screen.height)
            frame.origin.x = min(max(frame.origin.x, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.origin.y, screen.minY), screen.maxY - frame.height)
        }
        applyingLayout = true
        window.setFrame(frame, display: true)
        applyingLayout = false
    }

    /// Put the divider so the editor occupies `share` of the area it shares with the preview.
    private func placeEditor(share: CGFloat) {
        guard viewMode == .split else { return }
        splitView.layoutSubtreeIfNeeded()
        let left = editor.view.frame.minX
        let right = outlineItem.isCollapsed ? splitView.bounds.maxX : outline.view.frame.minX
        let available = right - left
        guard available > 1 else { return }
        let editorW = ReadingLayout.editorWidth(available: available, share: share)
        applyingLayout = true
        splitView.setPosition(left + editorW, ofDividerAt: 1)
        applyingLayout = false
        editor.view.needsLayout = true
    }

    private func currentEditorShare() -> CGFloat {
        let editorW = editor.view.frame.width
        let previewW = preview.view.frame.width
        let sum = editorW + previewW
        guard sum > 1 else { return editorShare }
        return editorW / sum
    }

    @objc private func splitResized(_ notification: Notification) {
        guard !applyingLayout, viewMode == .split else { return }
        saveAppearance()
    }

    // MARK: Zoom with ⌘-scroll

    /// ⌘ + mouse wheel or trackpad scroll zooms the editor and the preview together, as
    /// Ctrl+wheel does on Windows. A trackpad sends many small deltas: they add up to a step.
    private var zoomMonitor: Any?
    private var zoomScroll: CGFloat = 0

    private func startZoomMonitor() {
        guard zoomMonitor == nil else { return }
        zoomMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.view.window,
                  event.modifierFlags.intersection([.command, .option, .control]) == .command else { return event }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 24 : event.scrollingDeltaY
            if event.phase == .began { self.zoomScroll = 0 }
            self.zoomScroll += delta
            if self.zoomScroll >= 1 {
                self.editor.increaseTextSize(nil)
                self.zoomScroll = 0
            } else if self.zoomScroll <= -1 {
                self.editor.decreaseTextSize(nil)
                self.zoomScroll = 0
            }
            return nil
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
        if let zoomMonitor { NSEvent.removeMonitor(zoomMonitor) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
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
enum ViewMode: CaseIterable {
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

    var storage: String {
        switch self {
        case .edit: return "edit"
        case .split: return "split"
        case .preview: return "preview"
        }
    }

    init?(storage: String) {
        switch storage {
        case "edit": self = .edit
        case "split": self = .split
        case "preview": self = .preview
        default: return nil
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
