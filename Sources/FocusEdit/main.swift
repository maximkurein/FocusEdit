import AppKit

// MARK: - Headless self-test (verify the syntax engine without a GUI)

if let i = CommandLine.arguments.firstIndex(of: "--makeicon"), i + 1 < CommandLine.arguments.count {
    IconFactory.writeIconSet(to: CommandLine.arguments[i + 1])
    exit(0)
}

if CommandLine.arguments.contains("--make-default") {
    _ = NSApplication.shared
    exit(DefaultEditor.runFromCommandLine())
}

if CommandLine.arguments.contains("--selftest") {
    _ = NSApplication.shared      // text views need an app object
    exit(SelfTest.run())
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Optional file passed on the command line (dev convenience for launching
    /// straight into a document without the LaunchServices `open` path).
    private var launchFileURL: URL? = {
        let args = Array(CommandLine.arguments.dropFirst())
        for (i, arg) in args.enumerated() where !arg.hasPrefix("-") {
            if i > 0, ["--snapshot", "--theme", "--view", "--palette", "--goal"].contains(args[i - 1]) { continue }   // option values
            let url = URL(fileURLWithPath: arg)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }()

    /// The first start without a file shows the welcome tour instead of an empty document.
    /// (`--snapshot out.png --welcome` shows it without touching the remembered flag.)
    private lazy var welcomeDue = Snapshot.isActive
        ? CommandLine.arguments.contains("--welcome")
        : !Welcome.wasShown && launchFileURL == nil

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MenuBuilder.build()
        // Remembered on every start, as on Windows: a first start with a file skips the tour.
        if !welcomeDue, !Snapshot.isActive { Welcome.markShown() }
        // Autosave elsewhere: after a crash the unsaved text is offered back at the next launch.
        NSDocumentController.shared.autosavingDelay = 60
        if let url = launchFileURL {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        }
        // Direct-exec launches don't always come frontmost; force it after the
        // document window is created.
        if !Snapshot.isActive {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.schedule(to: CommandLine.arguments[i + 1])
        }
    }

    // Auto-open an untitled document only when no file was provided.
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        launchFileURL == nil
    }

    /// No file and nothing restored: the welcome tour once, then empty documents.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        if welcomeDue {
            welcomeDue = false
            if !Snapshot.isActive { Welcome.markShown() }
            Welcome.open()
            return true
        }
        return (try? NSDocumentController.shared.openUntitledDocumentAndDisplay(true)) != nil
    }

    @objc func showWelcomeTour(_ sender: Any?) {
        Welcome.open()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting with unsaved changes always asks (Save / Don't Save / Cancel, or Review
    /// Changes… for several). With autosave elsewhere and window restoration macOS would
    /// otherwise quit silently and only offer the text back at the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = NSDocumentController.shared
        guard !Snapshot.isActive, controller.documents.contains(where: \.isDocumentEdited) else { return .terminateNow }
        controller.reviewUnsavedDocuments(
            withAlertTitle: nil, cancellable: true, delegate: self,
            didReviewAllSelector: #selector(documentController(_:didReviewAll:contextInfo:)), contextInfo: nil)
        return .terminateLater
    }

    @objc private func documentController(_ controller: NSDocumentController, didReviewAll: Bool,
                                          contextInfo: UnsafeMutableRawPointer?) {
        NSApp.reply(toApplicationShouldTerminate: didReviewAll)
    }

    // Dock click with no windows: a new document, also after a launch with a file.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSDocumentController.shared.newDocument(nil) }
        return false
    }

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
    /// File ▸ New File…: the three-step dialog, then the file on disk, opened in a window.
    @objc func newFileWizard(_ sender: Any?) {
        guard let choice = NewFileWizard().run() else { return }
        let url = NewFile.freeURL(
            folder: choice.folder, name: NewFile.fileName(choice.name, format: choice.format))
        let text = NewFile.startingText(
            choice.template, format: choice.format, title: choice.name, date: NewFile.isoDate())
        do {
            try NewFile.data(format: choice.format, text: text).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error { NSAlert(error: error).runModal() }
        }
    }

    private func openTemplate(ext: String, text: String) {
        guard let doc = try? NSDocumentController.shared
            .openUntitledDocumentAndDisplay(true) as? FocusDocument else { return }
        doc.applyTemplate(text, fileExtension: ext)
    }

    // MARK: Theme editor

    private var themeEditor: ThemeEditorWindowController?

    /// The standard About panel (name, version, icon) plus the developer and the project page.
    @objc func showAbout(_ sender: Any?) {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: centered,
        ]
        let credits = NSMutableAttributedString(string: "Developer: Kurein M.N.\n", attributes: base)
        var link = base
        link[.link] = URL(string: "https://github.com/maximkurein/FocusEdit")
        credits.append(NSAttributedString(string: "github.com/maximkurein/FocusEdit", attributes: link))
        // Optional and quiet: one line, only here.
        var coffee = base
        coffee[.foregroundColor] = NSColor.secondaryLabelColor
        coffee[.link] = URL(string: "https://github.com/maximkurein/FocusEdit#support")
        credits.append(NSAttributedString(string: "\n☕ Buy the developer a coffee", attributes: coffee))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func makeDefaultEditor(_ sender: Any?) {
        DefaultEditor.runInteractively()
    }

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
        appMenu.addItem(item("About FocusEdit", #selector(AppDelegate.showAbout(_:)), ""))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Make Default Editor for .txt and .rtf", #selector(AppDelegate.makeDefaultEditor(_:)), ""))
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
        fileMenu.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        let newFile = NSMenuItem(title: "New File…", action: #selector(AppDelegate.newFileWizard(_:)), keyEquivalent: "N")
        newFile.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(newFile)
        let tmplParent = NSMenuItem(title: "New From Template", action: nil, keyEquivalent: "")
        let tmplMenu = NSMenu(title: "New From Template")
        tmplParent.submenu = tmplMenu
        tmplMenu.addItem(item("Markdown", #selector(AppDelegate.newMarkdownTemplate(_:)), ""))
        tmplMenu.addItem(item("Fountain", #selector(AppDelegate.newFountainTemplate(_:)), ""))
        fileMenu.addItem(tmplParent)
        fileMenu.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")

        let openRecent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        openRecent.submenu = recentMenu
        recentMenu.addItem(withTitle: "Clear Menu",
                           action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        fileMenu.addItem(openRecent)

        fileMenu.addItem(.separator())
        fileMenu.addItem(item("Close File", Selector(("closeFile:")), "w"))
        fileMenu.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "S")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        fileMenu.addItem(withTitle: "Revert to Saved",
                         action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
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
            let it = NSMenuItem(title: title, action: #selector(NSTextView.performFindPanelAction(_:)), keyEquivalent: key)
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

        // Writing aids
        editMenu.addItem(.separator())
        editMenu.addItem(item("Suggest Completions", Selector(("toggleAutocomplete:")), ""))
        editMenu.addItem(item("Automatic Pairing", Selector(("toggleAutoPairing:")), ""))
        let completeWord = item("Complete Word", #selector(NSTextView.complete(_:)), "\u{1b}")
        completeWord.keyEquivalentModifierMask = [.option]
        editMenu.addItem(completeWord)

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
        // No key equivalents: ⌘0/⌘1/⌘2 clash with users' own shortcuts. The toolbar
        // button cycles the modes; System Settings ▸ Keyboard ▸ App Shortcuts can bind keys.
        for mode in [FocusTextView.FocusMode.off, .sentence, .paragraph] {
            let it = item(mode.title, Selector(("selectFocusMode:")), "")
            it.tag = mode.rawValue
            focusMenu.addItem(it)
        }
        modusMenu.addItem(focusParent)

        modusMenu.addItem(item("Typewriter Sounds", Selector(("toggleTypewriterSounds:")), "u"))
        modusMenu.addItem(item("Live Markup (hide marks away from the cursor)", Selector(("toggleLiveMarkdown:")), ""))
        modusMenu.addItem(.separator())
        modusMenu.addItem(item("Vim Mode (learning)", Selector(("toggleVimMode:")), ""))

        // View menu
        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewItem.submenu = viewMenu

        let themeParent = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "Theme")
        themeParent.submenu = themeMenu
        ThemeMenu.fill(themeMenu)
        viewMenu.addItem(themeParent)

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
        // ⌘= (no Shift) zooms in too, as on Windows and in browsers.
        let increaseAlias = item("Increase Text Size", Selector(("increaseTextSize:")), "=")
        increaseAlias.isHidden = true
        increaseAlias.allowsKeyEquivalentWhenHidden = true
        viewMenu.addItem(increaseAlias)
        viewMenu.addItem(item("Decrease Text Size", Selector(("decreaseTextSize:")), "-"))
        viewMenu.addItem(item("Actual Text Size", Selector(("resetTextSize:")), "0"))
        viewMenu.addItem(.separator())
        let outlineToggle = item("Show Outline", Selector(("toggleOutline:")), "o")
        outlineToggle.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(outlineToggle)
        viewMenu.addItem(item("Show Word Count", Selector(("toggleStatistics:")), ""))
        let previewToggle = item("Show Preview", Selector(("togglePreview:")), "p")
        previewToggle.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(previewToggle)
        let paletteItem = item("Command Palette…", Selector(("showCommandPalette:")), "p")
        paletteItem.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(paletteItem)
        viewMenu.addItem(.separator())
        let toolbarToggle = item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t")
        toolbarToggle.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(toolbarToggle)
        viewMenu.addItem(item("Customize Toolbar…",
                              #selector(NSWindow.runToolbarCustomizationPalette(_:)), ""))
        let fullScreen = item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreen)

        // Library menu
        let libraryItem = NSMenuItem()
        mainMenu.addItem(libraryItem)
        let libraryMenu = NSMenu(title: "Library")
        libraryItem.submenu = libraryMenu
        let libToggle = item("Show Library", Selector(("toggleLibrary:")), "l")
        libToggle.keyEquivalentModifierMask = [.command, .option]
        libraryMenu.addItem(libToggle)
        libraryMenu.addItem(item("Link Directory…", Selector(("linkLibraryDirectory:")), ""))

        // Window menu (AppKit lists open windows and tabs here)
        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowItem.submenu = windowMenu
        windowMenu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        windowMenu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:)), ""))
        NSApp.windowsMenu = windowMenu

        // Help menu (AppKit adds the menu search field)
        let helpItem = NSMenuItem()
        mainMenu.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpItem.submenu = helpMenu
        helpMenu.addItem(item("FocusEdit Hints", Selector(("showHints:")), "?"))
        helpMenu.addItem(item("Welcome Tour", #selector(AppDelegate.showWelcomeTour(_:)), ""))
        NSApp.helpMenu = helpMenu

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

// Settings saved under the old bundle identifier come along once (not for snapshots).
if !Snapshot.isActive { Preferences.migrateFromPreviousBundleIdentifier() }

// A snapshot must not reopen (and then close) the user's restored windows and autosaves:
// ignore saved state for this launch only (argument domain, never written to disk).
if Snapshot.isActive {
    var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    arguments["ApplePersistenceIgnoreState"] = true
    UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
