import AppKit

extension NSToolbarItem.Identifier {
    static let focusMode = NSToolbarItem.Identifier("focusedit.focusMode")
    static let typewriter = NSToolbarItem.Identifier("focusedit.typewriter")
    static let sounds = NSToolbarItem.Identifier("focusedit.sounds")
    static let vim = NSToolbarItem.Identifier("focusedit.vim")
    static let theme = NSToolbarItem.Identifier("focusedit.theme")
    static let preview = NSToolbarItem.Identifier("focusedit.preview")
    static let hints = NSToolbarItem.Identifier("focusedit.hints")
    static let outline = NSToolbarItem.Identifier("focusedit.outline")
    static let newFile = NSToolbarItem.Identifier("focusedit.newFile")
    static let open = NSToolbarItem.Identifier("focusedit.open")
    static let save = NSToolbarItem.Identifier("focusedit.save")
    static let saveAs = NSToolbarItem.Identifier("focusedit.saveAs")
    static let print = NSToolbarItem.Identifier("focusedit.print")
    static let font = NSToolbarItem.Identifier("focusedit.font")
    static let fullScreen = NSToolbarItem.Identifier("focusedit.fullScreen")
}

/// SF Symbol images for toolbar items; an "on" state is drawn in the accent color.
enum ToolbarSymbol {
    static func image(_ name: String, on: Bool = false) -> NSImage? {
        // "text:Vim" draws the word itself: a button that is a name, not a picture.
        if name.hasPrefix("text:") { return textImage(String(name.dropFirst(5)), on: on) }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: name) else { return nil }
        guard on else { return base }
        let tinted = base.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))
        tinted?.isTemplate = false
        return tinted
    }

    private static func textImage(_ text: String, on: Bool) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: on ? NSColor.controlAccentColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        // A drawing handler is redrawn per appearance, so labelColor follows light and dark.
        return NSImage(size: NSSize(width: ceil(size.width) + 4, height: ceil(size.height)), flipped: false) { _ in
            (text as NSString).draw(at: NSPoint(x: 2, y: 0), withAttributes: attributes)
            return true
        }
    }

    /// Swap the image only when the state actually changes (validation runs often).
    static func update(_ item: NSToolbarItem, _ name: String, on: Bool) {
        let key = "\(name)|\(on)"
        guard item.symbolStateKey != key else { return }
        item.image = image(name, on: on)
        item.symbolStateKey = key
    }
}

/// Edit | Split | Preview as three segments, like the Windows toolbar. The selection is
/// set by `MainSplitViewController.setView`, so ⌥⌘P, Esc and the palette move it too.
/// Not a subclass: the group initialisers are Objective-C factories that return a plain group.
enum ViewSwitcher {

    static func make(_ id: NSToolbarItem.Identifier) -> NSToolbarItemGroup {
        // Symbols, not words: three word segments push Hints and Outline into the overflow menu.
        let images = ["text.alignleft", "rectangle.split.2x1", "eye"].compactMap { ToolbarSymbol.image($0) }
        let item = NSToolbarItemGroup(itemIdentifier: id, images: images, selectionMode: .selectOne,
                                      labels: ViewMode.allCases.map { $0.title },
                                      target: nil, action: Selector(("selectViewMode:")))
        for (sub, mode) in zip(item.subitems, ViewMode.allCases) { sub.toolTip = mode.title }
        item.label = "View"
        item.paletteLabel = "View: Edit, Split, Preview"
        item.toolTip = "View: Edit · Split (live preview beside the text) · Preview — plain text and Markdown (⌥⌘P cycles, Esc back to editing)"
        item.controlRepresentation = .expanded
        item.selectedIndex = 0
        return item
    }

    /// Show `mode` as selected; Split and Preview are off for documents without a preview (Fountain).
    static func show(_ mode: ViewMode, previewable: Bool, in toolbar: NSToolbar?) {
        guard let group = toolbar?.items.first(where: { $0.itemIdentifier == .preview }) as? NSToolbarItemGroup
        else { return }
        if let index = ViewMode.allCases.firstIndex(of: mode), group.selectedIndex != index {
            group.selectedIndex = index
        }
        for (i, item) in group.subitems.enumerated() where i > 0 { item.isEnabled = previewable }
    }
}

private var stateKeyHandle: UInt8 = 0
private extension NSToolbarItem {
    var symbolStateKey: String? {
        get { objc_getAssociatedObject(self, &stateKeyHandle) as? String }
        set { objc_setAssociatedObject(self, &stateKeyHandle, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }
}

/// Document window: unified toolbar with SF Symbols (Liquid Glass on macOS 26),
/// tooltips with shortcuts, distraction-free full screen.
final class DocumentWindowController: NSWindowController, NSToolbarDelegate,
                                      NSWindowDelegate, NSMenuDelegate {

    convenience init(split: MainSplitViewController) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentViewController = split
        // Setting a contentViewController resizes the window to the view's
        // fitting size, so pin an explicit size (no frame autosave — a
        // degenerate saved frame must never collapse the window again).
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.minSize = NSSize(width: 560, height: 420)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titleVisibility = .visible
        self.init(window: window)
        window.delegate = self

        // v6: the column-width button is gone (1.6.9). v7: a Print button (1.6.11).
        // A saved layout would keep the old set.
        let toolbar = NSToolbar(identifier: "FocusEditToolbar.v7")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.center()
    }

    // MARK: Full screen: hide toolbar and menu bar until the pointer goes up.

    func window(_ window: NSWindow,
                willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions)
        -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideToolbar, .autoHideMenuBar]
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        (contentViewController as? MainSplitViewController)?.saveAppearance()
    }

    func windowWillClose(_ notification: Notification) {
        (contentViewController as? MainSplitViewController)?.noteWindowClosing()
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .newFile, .open, .save, .saveAs, .print, .flexibleSpace,
         .focusMode, .typewriter, .sounds, .vim, .theme, .font, .fullScreen,
         .space, .preview, .hints, .outline]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .focusMode:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = ToolbarSymbol.image("scope")
            item.label = "Focus"
            item.paletteLabel = "Focus"
            item.toolTip = "Focus highlighting — click to cycle Off · Sentence · Paragraph (up to the blank line), arrow for the list"
            item.action = Selector(("cycleFocusMode:"))
            item.showsIndicator = true
            let menu = NSMenu()
            for mode in [FocusTextView.FocusMode.off, .sentence, .paragraph] {
                let mi = NSMenuItem(title: mode.title, action: Selector(("selectFocusMode:")), keyEquivalent: "")
                mi.tag = mode.rawValue
                menu.addItem(mi)
            }
            item.menu = menu
            return item

        case .typewriter:
            return button(id, "character.cursor.ibeam", "Typewriter",
                          "Keep the active line centred (⌘T)", "toggleTypewriterScrolling:")
        case .sounds:
            return button(id, "speaker.wave.2", "Sounds",
                          "Typewriter sounds (⌘U)", "toggleTypewriterSounds:")
        case .vim:
            return button(id, "text:Vim", "Vim",
                          "Vim mode for learning — Normal/Insert modes with a coach under the text", "toggleVimMode:")
        case .theme:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = ToolbarSymbol.image("circle.lefthalf.filled")
            item.label = "Theme"
            item.paletteLabel = "Theme"
            item.toolTip = "Theme — editor and preview. The preview follows the editor until you give it its own"
            let menu = NSMenu()
            menu.delegate = self      // rebuilt on open: custom themes appear immediately
            item.menu = menu
            return item
        case .preview:
            return ViewSwitcher.make(id)
        case .hints:
            return button(id, "questionmark.circle", "Hints",
                          "Hints and shortcuts (⌘?)", "showHints:")
        case .outline:
            return button(id, "sidebar.right", "Outline",
                          "Show or hide the outline (⌥⌘O)", "toggleOutline:")
        case .font:
            return cycleMenu(id, "textformat", "Font", "cycleFontKind:", "selectFontKind:",
                             FontKind.allCases.map { ($0.title, $0.rawValue) })
        case .fullScreen:
            return button(id, "arrow.up.left.and.arrow.down.right", "Full Screen",
                          "Full screen — the toolbar and the menu bar hide (⌃⌘F)", "fullScreenFromToolbar:")
        case .newFile:
            return button(id, "doc.badge.plus", "New File",
                          "New File… — .txt, .md or .rtf, from a template (⇧⌘N)", "newFileWizard:")
        case .open:
            return button(id, "folder", "Open", "Open a file (⌘O)", "openDocument:")
        case .save:
            return button(id, "square.and.arrow.down", "Save", "Save (⌘S)", "saveDocument:")
        case .saveAs:
            return button(id, "square.and.arrow.down.on.square", "Save As",
                          "Save As… — a new name, folder or format: .txt, .md, .rtf (⇧⌘S)", "saveDocumentAs:")
        case .print:
            return button(id, "printer", "Print",
                          "Print — or save as PDF from the print dialog (⌘P)", "printEditor:")
        default:
            return nil
        }
    }

    /// A button that steps through the choices on click; its arrow lists them (like Focus).
    private func cycleMenu(_ id: NSToolbarItem.Identifier, _ symbol: String, _ label: String,
                           _ cycle: String, _ select: String, _ choices: [(String, Int)]) -> NSToolbarItem {
        let item = NSMenuToolbarItem(itemIdentifier: id)
        item.image = ToolbarSymbol.image(symbol)
        item.label = label
        item.paletteLabel = label
        item.action = Selector(cycle)
        item.showsIndicator = true
        let menu = NSMenu()
        for (title, tag) in choices {
            let mi = NSMenuItem(title: title, action: Selector(select), keyEquivalent: "")
            mi.tag = tag
            menu.addItem(mi)
        }
        item.menu = menu
        return item
    }

    private func button(_ id: NSToolbarItem.Identifier, _ symbol: String, _ label: String,
                        _ tip: String, _ action: String) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = ToolbarSymbol.image(symbol)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.action = Selector(action)
        item.isBordered = true
        return item
    }

    // MARK: Theme menu (built on open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        ThemeMenu.fill(menu)
    }
}
