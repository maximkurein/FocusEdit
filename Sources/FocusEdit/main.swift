import AppKit

// MARK: - Headless self-test (verify the syntax engine without a GUI)

if let i = CommandLine.arguments.firstIndex(of: "--makeicon"), i + 1 < CommandLine.arguments.count {
    IconFactory.writeIconSet(to: CommandLine.arguments[i + 1])
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    let md = """
    # Heading one
    Some **bold** and *italic* and `code` here.
    > a blockquote line
    - a list item
    [a link](https://example.com)
    plain paragraph
    """
    let engine = SyntaxEngine(highlighter: MarkdownHighlighter())
    let tokens = engine.tokens(for: md as NSString)
    let ns = md as NSString
    print("Markdown tokens: \(tokens.count)")
    for t in tokens {
        let text = ns.substring(with: t.range).replacingOccurrences(of: "\n", with: "⏎")
        print("  \(t.role)  \(NSStringFromRange(t.range))  \"\(text)\"")
    }

    let fountain = """
    INT. HOUSE - DAY
    MARY
    (whispering)
    Hello there.
    CUT TO:
    """
    let fe = SyntaxEngine(highlighter: FountainHighlighter())
    let ft = fe.tokens(for: fountain as NSString)
    let fns = fountain as NSString
    print("Fountain tokens: \(ft.count)")
    for t in ft {
        print("  \(t.role)  \"\(fns.substring(with: t.range))\"")
    }
    exit(0)
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Optional file passed on the command line (dev convenience for launching
    /// straight into a document without the LaunchServices `open` path).
    private var launchFileURL: URL? = {
        for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
            let url = URL(fileURLWithPath: arg)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MenuBuilder.build()
        if let url = launchFileURL {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
        // Direct-exec launches don't always come frontmost; force it after the
        // document window is created.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    // Auto-open an untitled document only when no file was provided.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        launchFileURL == nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // LaunchServices "Open With" / drag-to-dock.
    func application(_ sender: NSApplication, open urls: [URL]) {
        for url in urls {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
    }

    // MARK: Templates

    @objc func newMarkdownTemplate(_ sender: Any?) {
        openTemplate(ext: "md", text: Templates.markdown)
    }
    @objc func newFountainTemplate(_ sender: Any?) {
        openTemplate(ext: "fountain", text: Templates.fountain)
    }
    private func openTemplate(ext: String, text: String) {
        guard let doc = try? NSDocumentController.shared
            .openUntitledDocumentAndDisplay(true) as? FocusDocument else { return }
        doc.applyTemplate(text, fileExtension: ext)
    }

    // MARK: Theme editor

    private var themeEditor: ThemeEditorWindowController?

    @objc func editThemes(_ sender: Any?) {
        let seed = frontSplit()?.editor.theme ?? .light
        let editor = ThemeEditorWindowController(seed: seed)
        editor.onSave = { theme in
            NSApp.mainMenu = MenuBuilder.build()
            self.frontSplit()?.editor.apply(theme: theme)
            Preferences.themeName = theme.name
        }
        themeEditor = editor
        editor.showWindow(nil)
        editor.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func frontSplit() -> MainSplitViewController? {
        (NSApp.keyWindow?.contentViewController as? MainSplitViewController)
            ?? (NSApp.mainWindow?.contentViewController as? MainSplitViewController)
    }
}

enum Templates {
    static let markdown = """
    # Title

    Start writing here.

    ## Section

    - point one
    - point two
    """

    static let fountain = """
    Title: Untitled
    Credit: written by
    Author: Your Name

    INT. SOMEWHERE - DAY

    A description of the scene.

    CHARACTER
    Dialogue goes here.
    """
}

// MARK: - Main menu (built in code; no MainMenu.nib)

enum MenuBuilder {
    static func build() -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "About FocusEdit",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide FocusEdit",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FocusEdit",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // File menu — standard NSDocument actions via the responder chain
        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "New", action: Selector(("newDocument:")), keyEquivalent: "n")
        let tmplParent = NSMenuItem(title: "New From Template", action: nil, keyEquivalent: "")
        let tmplMenu = NSMenu(title: "New From Template")
        tmplParent.submenu = tmplMenu
        tmplMenu.addItem(item("Markdown", Selector(("newMarkdownTemplate:")), ""))
        tmplMenu.addItem(item("Fountain", Selector(("newFountainTemplate:")), ""))
        fileMenu.addItem(tmplParent)
        fileMenu.addItem(withTitle: "Open…", action: Selector(("openDocument:")), keyEquivalent: "o")

        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        openRecent.submenu = recentMenu
        recentMenu.addItem(withTitle: "Clear Menu",
                           action: Selector(("clearRecentDocuments:")), keyEquivalent: "")
        fileMenu.addItem(openRecent)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenu.addItem(withTitle: "Save", action: Selector(("saveDocument:")), keyEquivalent: "s")
        let saveAs = NSMenuItem(title: "Save As…", action: Selector(("saveDocumentAs:")), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileMenu.addItem(withTitle: "Revert to Saved",
                         action: Selector(("revertDocumentToSaved:")), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Print…", Selector(("printEditor:")), "p"))
        fileMenu.addItem(item("Export as HTML…", Selector(("exportAsHTML:")), ""))
        fileMenu.addItem(item("Export as PDF…", Selector(("exportAsPDF:")), ""))

        // Edit menu
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        editMenu.addItem(item("Copy as HTML", Selector(("copyAsHTML:")), ""))

        // Find & Replace via the text view's find bar
        let findParent = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        findParent.submenu = findMenu
        func findItem(_ title: String, _ tag: Int, _ key: String,
                      _ mask: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: Selector(("performFindPanelAction:")), keyEquivalent: key)
            it.tag = tag
            it.keyEquivalentModifierMask = mask
            it.target = nil
            return it
        }
        findMenu.addItem(findItem("Find…", 1, "f"))
        findMenu.addItem(findItem("Find and Replace…", 12, "f", [.command, .option]))
        findMenu.addItem(findItem("Find Next", 2, "g"))
        findMenu.addItem(findItem("Find Previous", 3, "g", [.command, .shift]))
        findMenu.addItem(findItem("Use Selection for Find", 7, "e"))
        editMenu.addItem(findParent)

        // Format (Markdown)
        let fmtParent = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        let fmtMenu = NSMenu(title: "Format")
        fmtParent.submenu = fmtMenu
        fmtMenu.addItem(item("Bold", Selector(("mdBold:")), "b"))
        fmtMenu.addItem(item("Italic", Selector(("mdItalic:")), "i"))
        fmtMenu.addItem(item("Inline Code", Selector(("mdCode:")), ""))
        fmtMenu.addItem(item("Link", Selector(("mdLink:")), "k"))
        fmtMenu.addItem(.separator())
        fmtMenu.addItem(item("Heading", Selector(("mdHeading:")), ""))
        fmtMenu.addItem(item("Blockquote", Selector(("mdBlockquote:")), ""))
        fmtMenu.addItem(item("Unordered List", Selector(("mdUnorderedList:")), ""))
        fmtMenu.addItem(item("Ordered List", Selector(("mdOrderedList:")), ""))
        fmtMenu.addItem(.separator())
        fmtMenu.addItem(item("Indent", Selector(("indentLines:")), "]"))
        fmtMenu.addItem(item("Unindent", Selector(("unindentLines:")), "["))
        editMenu.addItem(fmtParent)

        // CriticMarkup
        let cmParent = NSMenuItem(title: "CriticMarkup", action: nil, keyEquivalent: "")
        let cmMenu = NSMenu(title: "CriticMarkup")
        cmParent.submenu = cmMenu
        cmMenu.addItem(item("Addition", Selector(("cmAddition:")), ""))
        cmMenu.addItem(item("Deletion", Selector(("cmDeletion:")), ""))
        cmMenu.addItem(item("Highlight", Selector(("cmHighlight:")), ""))
        cmMenu.addItem(item("Comment", Selector(("cmComment:")), ""))
        cmMenu.addItem(.separator())
        cmMenu.addItem(item("Accept Change", Selector(("cmAccept:")), ""))
        cmMenu.addItem(item("Reject Change", Selector(("cmReject:")), ""))
        editMenu.addItem(cmParent)

        // Modus menu
        let modusItem = NSMenuItem()
        mainMenu.addItem(modusItem)
        let modusMenu = NSMenu(title: "Modus")
        modusItem.submenu = modusMenu

        modusMenu.addItem(item("Keep Active Line Fixed",
                               Selector(("toggleTypewriterScrolling:")), "t"))

        let focusParent = NSMenuItem(title: "Focus Highlighting", action: nil, keyEquivalent: "")
        let focusMenu = NSMenu(title: "Focus Highlighting")
        focusParent.submenu = focusMenu
        for (mode, key) in [(FocusTextView.FocusMode.off, "0"),
                            (.sentence, "1"), (.paragraph, "2")] {
            let it = item(mode.title, Selector(("selectFocusMode:")), key)
            it.tag = mode.rawValue
            focusMenu.addItem(it)
        }
        modusMenu.addItem(focusParent)

        modusMenu.addItem(item("Typewriter Sounds", Selector(("toggleTypewriterSounds:")), "u"))

        // View menu
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu

        let themeParent = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "Theme")
        themeParent.submenu = themeMenu
        for (i, theme) in ThemeStore.allThemes().enumerated() {
            let it = item(theme.name, Selector(("selectTheme:")), "")
            it.tag = i
            themeMenu.addItem(it)
        }
        themeMenu.addItem(.separator())
        themeMenu.addItem(item("Edit Themes…", Selector(("editThemes:")), ""))
        viewMenu.addItem(themeParent)

        let sizeParent = NSMenuItem(title: "Editor Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu(title: "Editor Size")
        sizeParent.submenu = sizeMenu
        for size in EditorSize.allCases {
            let it = item(size.title, Selector(("selectEditorSize:")), "")
            it.tag = Int(size.rawValue)
            sizeMenu.addItem(it)
        }
        viewMenu.addItem(sizeParent)

        let fontParent = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        let fontMenu = NSMenu(title: "Font")
        fontParent.submenu = fontMenu
        for kind in FontKind.allCases {
            let it = item(kind.title, Selector(("selectFontKind:")), "")
            it.tag = kind.rawValue
            fontMenu.addItem(it)
        }
        viewMenu.addItem(fontParent)

        viewMenu.addItem(.separator())
        viewMenu.addItem(item("Increase Text Size", Selector(("increaseTextSize:")), "+"))
        viewMenu.addItem(item("Decrease Text Size", Selector(("decreaseTextSize:")), "-"))
        viewMenu.addItem(.separator())
        let outlineToggle = item("Show Outline", Selector(("toggleOutline:")), "o")
        outlineToggle.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(outlineToggle)
        viewMenu.addItem(item("Show Statistics", Selector(("toggleStatistics:")), ""))
        let previewToggle = item("Show Preview", Selector(("togglePreview:")), "p")
        previewToggle.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(previewToggle)

        // Library menu
        let libraryItem = NSMenuItem()
        mainMenu.addItem(libraryItem)
        let libraryMenu = NSMenu(title: "Library")
        libraryItem.submenu = libraryMenu
        let libToggle = item("Show Library", Selector(("toggleLibrary:")), "l")
        libToggle.keyEquivalentModifierMask = [.command, .option]
        libraryMenu.addItem(libToggle)
        libraryMenu.addItem(item("Link Directory…", Selector(("linkLibraryDirectory:")), ""))

        return mainMenu
    }

    /// Menu item with nil target so the action travels the responder chain
    /// to the front window's EditorViewController.
    private static func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = nil
        return it
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
