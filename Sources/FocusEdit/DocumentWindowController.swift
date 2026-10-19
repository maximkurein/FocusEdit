import AppKit

extension NSToolbarItem.Identifier {
    static let focusMode = NSToolbarItem.Identifier("focusedit.focusMode")
    static let typewriter = NSToolbarItem.Identifier("focusedit.typewriter")
    static let sounds = NSToolbarItem.Identifier("focusedit.sounds")
    static let theme = NSToolbarItem.Identifier("focusedit.theme")
    static let preview = NSToolbarItem.Identifier("focusedit.preview")
    static let hints = NSToolbarItem.Identifier("focusedit.hints")
    static let outline = NSToolbarItem.Identifier("focusedit.outline")
}

/// SF Symbol images for toolbar items; an "on" state is drawn in the accent color.
enum ToolbarSymbol {
    static func image(_ name: String, on: Bool = false) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: name) else { return nil }
        guard on else { return base }
        let tinted = base.withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))
        tinted?.isTemplate = false
        return tinted
    }

    /// Swap the image only when the state actually changes (validation runs often).
    static func update(_ item: NSToolbarItem, _ name: String, on: Bool) {
        let key = "\(name)|\(on)"
        guard item.symbolStateKey != key else { return }
        item.image = image(name, on: on)
        item.symbolStateKey = key
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
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.contentViewController = split
        // Setting a contentViewController resizes the window to the view's
        // fitting size, so pin an explicit size (no frame autosave — a
        // degenerate saved frame must never collapse the window again).
        window.setContentSize(NSSize(width: 1100, height: 760))
        window.minSize = NSSize(width: 560, height: 420)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.titleVisibility = .visible
        self.init(window: window)
        window.delegate = self

        let toolbar = NSToolbar(identifier: "FocusEditToolbar.v1")
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

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace,
         .focusMode, .typewriter, .sounds, .theme, .space, .preview, .hints, .outline]
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
            item.toolTip = "Focus highlighting — click to cycle Off · Sentence · Paragraph, arrow for the list"
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
        case .theme:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = ToolbarSymbol.image("circle.lefthalf.filled")
            item.label = "Theme"
            item.paletteLabel = "Theme"
            item.toolTip = "Theme — Light, Dark, Sepia or your own"
            let menu = NSMenu()
            menu.delegate = self      // rebuilt on open: custom themes appear immediately
            item.menu = menu
            return item
        case .preview:
            return button(id, "eye", "Preview",
                          "Live HTML preview — Markdown only (⇧⌘P)", "togglePreview:")
        case .hints:
            return button(id, "questionmark.circle", "Hints",
                          "Hints and shortcuts (⌘?)", "showHints:")
        case .outline:
            return button(id, "sidebar.right", "Outline",
                          "Show or hide the outline (⌥⌘O)", "toggleOutline:")
        default:
            return nil
        }
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
        menu.removeAllItems()
        for (i, theme) in ThemeStore.allThemes().enumerated() {
            let mi = NSMenuItem(title: theme.name, action: Selector(("selectTheme:")), keyEquivalent: "")
            mi.tag = i
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Edit Themes…", action: Selector(("editThemes:")), keyEquivalent: ""))
    }
}
