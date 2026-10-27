import AppKit

/// One line of the command palette.
struct PaletteCommand {
    let title: String
    /// Shown dimmed on the right.
    var shortcut = ""
    /// Extra words that find the command ("dark", "night" for a theme).
    var keywords = ""
    let run: () -> Void
}

/// Finding commands by a few typed letters. Mirrors `windows/src/palette.ts`.
enum PaletteSearch {

    /// How well `query` matches `text`: lower is better, nil = no match. Every word of the query must match.
    static func matchScore(_ query: String, _ text: String) -> Int? {
        let haystack = text.lowercased() as NSString
        var total = 0
        for word in query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            let at = haystack.range(of: word).location
            if at != NSNotFound {
                // Earlier is better, and the start of a word is better than the middle of one.
                let wordStart = at == 0 || " \t\n:/-.".utf16.contains(haystack.character(at: at - 1))
                total += at + (wordStart ? 0 : 20)
                continue
            }
            // Letters in order ("tdark" → "Theme: Dark"): a weaker match.
            var from = 0
            for unit in word.utf16 {
                var found = NSNotFound
                var i = from
                while i < haystack.length {
                    if haystack.character(at: i) == unit { found = i; break }
                    i += 1
                }
                guard found != NSNotFound else { return nil }
                from = found + 1
            }
            total += 100 + from
        }
        return total
    }

    /// The commands that match, best first; with an empty query all of them in their own order.
    static func filter(_ commands: [PaletteCommand], _ query: String) -> [PaletteCommand] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return commands }
        return commands.enumerated()
            .compactMap { i, c in matchScore(query, "\(c.title) \(c.keywords)").map { (c, $0, i) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.2 < $1.2 }
            .map { $0.0 }
    }

    /// The key equivalent of the main-menu item with this action (and tag), as "⇧⌘P".
    static func shortcut(for action: Selector, tag: Int? = nil, in menu: NSMenu? = NSApp.mainMenu) -> String {
        guard let menu else { return "" }
        for item in menu.items {
            if let sub = item.submenu {
                let found = shortcut(for: action, tag: tag, in: sub)
                if !found.isEmpty { return found }
            } else if item.action == action, tag == nil || item.tag == tag, !item.keyEquivalent.isEmpty {
                return format(item.keyEquivalent, item.keyEquivalentModifierMask)
            }
        }
        return ""
    }

    static func format(_ key: String, _ mask: NSEvent.ModifierFlags) -> String {
        var flags = mask
        // An upper-case key equivalent means Shift.
        if key != key.lowercased() { flags.insert(.shift) }
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        switch key {
        case "\u{1b}": s += "⎋"
        case "\r": s += "↩"
        default: s += key.uppercased()
        }
        return s
    }
}

/// The palette panel: a search field and the list under it, over the top of the
/// document window. ↑/↓ choose, Return runs, Esc or a click elsewhere closes,
/// and the keyboard goes back to the text.
final class CommandPaletteController: NSObject, NSTextFieldDelegate, NSTableViewDataSource,
                                      NSTableViewDelegate, NSWindowDelegate {

    private let panel: NSPanel
    private let field = NSTextField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var heightConstraint: NSLayoutConstraint!
    private var provider: (String) -> [PaletteCommand] = { _ in [] }
    private var shown: [PaletteCommand] = []
    private weak var parent: NSWindow?
    private var onClose: (() -> Void)?
    private var closing = false

    private static let width: CGFloat = 520
    private static let rowHeight: CGFloat = 28
    private static let visibleRows = 10

    var isOpen: Bool { panel.isVisible }

    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        field.placeholderString = "Type a command…"
        field.font = .systemFont(ofSize: 17)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked(_:))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let line = NSBox()
        line.boxType = .separator
        for v in [field, line, scroll] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(v)
        }
        heightConstraint = scroll.heightAnchor.constraint(equalToConstant: Self.rowHeight)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: effect.topAnchor, constant: 12),
            field.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            field.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            line.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            line.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: line.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -6),
            effect.widthAnchor.constraint(equalToConstant: Self.width),
            heightConstraint,
        ])
        panel.contentView = effect
    }

    /// `commands(query)` returns what to list for what has been typed so far.
    func open(over window: NSWindow, dark: Bool, commands: @escaping (String) -> [PaletteCommand],
              onClose: @escaping () -> Void) {
        provider = commands
        parent = window
        self.onClose = onClose
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        field.stringValue = ""
        refresh()
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        place()
        if Snapshot.isActive {
            panel.alphaValue = 0
            panel.orderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.makeFirstResponder(field)
    }

    /// Snapshot: type `query` and hand back the panel's picture and frame.
    func snapshot(query: String) -> (NSBitmapImageRep, NSRect)? {
        field.stringValue = query
        refresh()
        guard let content = panel.contentView,
              let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.layoutSubtreeIfNeeded()
        content.cacheDisplay(in: content.bounds, to: rep)
        return (rep, panel.frame)
    }

    func close() {
        guard panel.isVisible, !closing else { return }
        closing = true
        defer { closing = false }
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
        onClose?()
        onClose = nil
    }

    /// Centred, a little below the top of the window's content.
    private func place() {
        guard let parent else { return }
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: Self.width, height: 100)
        let top = parent.frame.minY + parent.contentLayoutRect.maxY - 40
        panel.setFrame(NSRect(x: parent.frame.midX - size.width / 2, y: top - size.height,
                              width: size.width, height: size.height), display: true)
    }

    private func refresh() {
        shown = provider(field.stringValue)
        table.reloadData()
        let rows = max(1, min(Self.visibleRows, shown.count))
        heightConstraint.constant = CGFloat(rows) * Self.rowHeight
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
        table.scrollRowToVisible(0)
        if panel.isVisible { place() }
    }

    private func run(_ row: Int) {
        guard row >= 0, row < shown.count else { return }
        let command = shown[row]
        close()
        command.run()
    }

    @objc private func clicked(_ sender: Any?) { run(table.clickedRow) }

    private func move(_ delta: Int) {
        guard !shown.isEmpty else { return }
        let row = min(shown.count - 1, max(0, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) { refresh() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(+1)
        case #selector(NSResponder.pageUp(_:)), #selector(NSResponder.scrollPageUp(_:)): move(-Self.visibleRows)
        case #selector(NSResponder.pageDown(_:)), #selector(NSResponder.scrollPageDown(_:)): move(+Self.visibleRows)
        case #selector(NSResponder.insertNewline(_:)): run(table.selectedRow)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    // MARK: NSWindowDelegate

    /// A click outside the panel closes it.
    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { max(1, shown.count) }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !shown.isEmpty }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSView()
        let title = NSTextField(labelWithString: shown.isEmpty ? "No matching command" : shown[row].title)
        title.font = .systemFont(ofSize: 13.5)
        title.lineBreakMode = .byTruncatingTail
        if shown.isEmpty { title.textColor = .secondaryLabelColor }
        let key = NSTextField(labelWithString: shown.isEmpty ? "" : shown[row].shortcut)
        key.font = .systemFont(ofSize: 12)
        key.textColor = .secondaryLabelColor
        key.alignment = .right
        key.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [title, key] {
            v.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(v)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            key.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            key.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            key.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// A borderless panel that can take the keyboard (for the search field).
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - The document window's commands

extension MainSplitViewController {

    /// View ▸ Command Palette… (⇧⌘P).
    @objc func showCommandPalette(_ sender: Any?) {
        guard let window = view.window else { return }
        if palette.isOpen { palette.close(); return }
        palette.open(over: window, dark: editor.themeIsDark, commands: { [weak self] query in
            self?.paletteCommands(query) ?? []
        }, onClose: { [weak self] in
            guard let self else { return }
            self.view.window?.makeFirstResponder(self.viewMode == .preview ? self.preview.view : self.editor.textView)
        })
    }

    /// What the palette lists for what has been typed; a number also offers a word goal and a line.
    func paletteCommands(_ query: String) -> [PaletteCommand] {
        var list = PaletteSearch.filter(allCommands(), query)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if let number = Int(trimmed), number > 0, trimmed.allSatisfy(\.isNumber) {
            list.insert(contentsOf: [
                PaletteCommand(title: "Word goal: \(number) words") { [weak self] in self?.editor.setWordGoal(number) },
                PaletteCommand(title: "Go to line \(number)") { [weak self] in self?.editor.goToLine(number) },
            ], at: 0)
        }
        return list
    }

    private func allCommands() -> [PaletteCommand] {
        let key = { (action: String, tag: Int?) in PaletteSearch.shortcut(for: Selector(action), tag: tag) }
        func send(_ action: String) -> () -> Void {
            { NSApp.sendAction(Selector(action), to: nil, from: nil) }
        }
        func command(_ title: String, _ action: String, keywords: String = "") -> PaletteCommand {
            PaletteCommand(title: title, shortcut: key(action, nil), keywords: keywords, run: send(action))
        }
        /// Actions that read the choice from a menu item's tag.
        func tagged(_ title: String, _ action: String, _ tag: Int, keywords: String = "") -> PaletteCommand {
            PaletteCommand(title: title, shortcut: key(action, tag), keywords: keywords) {
                let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: "")
                item.tag = tag
                NSApp.sendAction(Selector(action), to: nil, from: item)
            }
        }
        let markdown = editor.documentKind == .markdown
        let html = editor.documentKind.supportsHTML

        var list: [PaletteCommand] = [
            command("New File…", "newFileWizard:", keywords: "create wizard steps template txt text md markdown rtf rich"),
            command("New document", "newDocument:"),
            command("Open…", "openDocument:"),
            command("Save", "saveDocument:"),
            command("Save As…", "saveDocumentAs:"),
            command("Close file", "closeFile:", keywords: "close window start screen"),
        ]
        if html {
            list += [
                command("Export as HTML…", "exportAsHTML:"),
                command("Copy as HTML", "copyAsHTML:"),
            ]
        }
        list += [
            command("Export as PDF…", "exportAsPDF:"),
            command("Print…", "printEditor:", keywords: "pdf paper"),
        ]
        if html {
            let viewKey = key("togglePreview:", nil)
            list += [
                PaletteCommand(title: "View: Edit", shortcut: viewKey, keywords: "source write") { [weak self] in self?.setView(.edit) },
                PaletteCommand(title: "View: Split", keywords: "side by side live preview") { [weak self] in self?.setView(.split) },
                PaletteCommand(title: "View: Preview", keywords: "read reading") { [weak self] in self?.setView(.preview) },
            ]
        }
        list += [
            command(outlineItem.isCollapsed ? "Outline: show" : "Outline: hide", "toggleOutline:", keywords: "headings"),
            command(libraryItem.isCollapsed ? "Library: show" : "Library: hide", "toggleLibrary:", keywords: "files folder sidebar"),
        ]
        for mode in [FocusTextView.FocusMode.off, .sentence, .paragraph] {
            list.append(tagged("Focus: \(mode.title)", "selectFocusMode:", mode.rawValue,
                               keywords: "highlight dim sentence paragraph block"))
        }
        let tv = editor.textView
        list += [
            command(tv.typewriterScrollingEnabled ? "Typewriter scrolling: off" : "Typewriter scrolling: on",
                    "toggleTypewriterScrolling:", keywords: "centre center keep active line fixed"),
            command(editor.sounds.enabled ? "Typewriter sounds: off" : "Typewriter sounds: on",
                    "toggleTypewriterSounds:", keywords: "audio click keys"),
        ]
        let themeWords = ["System": "auto follow macos appearance", "Light": "day white", "Dark": "night black", "Sepia": "paper warm"]
        for (i, theme) in ThemeStore.allThemes().enumerated() {
            list.append(tagged("Theme: \(theme.name)", "selectTheme:", i, keywords: themeWords[theme.name] ?? "colours"))
        }
        list.append(command("Edit Themes…", "editThemes:", keywords: "colours custom"))
        for size in EditorSize.allCases {
            list.append(tagged("Column width: \(size.title)", "selectEditorSize:", Int(size.rawValue), keywords: "editor size"))
        }
        for font in FontKind.allCases {
            list.append(tagged("Font: \(font.title)", "selectFontKind:", font.rawValue))
        }
        list += [
            command("Text size: larger", "increaseTextSize:", keywords: "bigger zoom"),
            command("Text size: smaller", "decreaseTextSize:", keywords: "zoom"),
            command("Text size: actual", "resetTextSize:", keywords: "zoom reset default"),
            command("Full screen", "toggleFullScreen:"),
            command(editor.vimEnabled ? "Vim mode: turn off" : "Vim mode: turn on", "toggleVimMode:", keywords: "learn"),
            command(tv.autocompleteEnabled ? "Suggest completions: off" : "Suggest completions: on",
                    "toggleAutocomplete:", keywords: "grey word ghost"),
            command(tv.autoPairingEnabled ? "Automatic pairing: off" : "Automatic pairing: on",
                    "toggleAutoPairing:", keywords: "brackets quotes"),
        ]
        if markdown {
            list += [
                command(Preferences.liveMarkdown ? "Markup: always show the marks" : "Markup: hide the marks away from the cursor",
                        "toggleLiveMarkdown:", keywords: "markdown symbols asterisks hashes wysiwyg live"),
                command("Format: Bold", "mdBold:"),
                command("Format: Italic", "mdItalic:"),
                command("Format: Link", "mdLink:"),
                command("Format: Inline Code", "mdCode:"),
                command("Format: Heading", "mdHeading:"),
                command("Format: Blockquote", "mdBlockquote:"),
                command("Format: Bulleted List", "mdUnorderedList:", keywords: "unordered"),
                command("Format: Numbered List", "mdOrderedList:", keywords: "ordered"),
            ]
        }
        for goal in [250, 500, 1000, 2000] {
            list.append(PaletteCommand(title: "Word goal: \(goal) words", keywords: "target session progress timer") {
                [weak self] in self?.editor.setWordGoal(goal)
            })
        }
        list.append(PaletteCommand(title: "Word goal: off", keywords: "target session progress timer") {
            [weak self] in self?.editor.setWordGoal(0)
        })
        list += [
            command("Hints and shortcuts", "showHints:", keywords: "help keys"),
            command("About FocusEdit", "showAbout:", keywords: "version developer github"),
            command("Open the welcome tour", "showWelcomeTour:", keywords: "introduction help start"),
        ]
        for url in NSDocumentController.shared.recentDocumentURLs {
            list.append(PaletteCommand(title: "Open recent: \(url.lastPathComponent)",
                                       keywords: url.deletingLastPathComponent().path) {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            })
        }
        return list
    }
}
