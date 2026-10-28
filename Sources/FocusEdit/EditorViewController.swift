import AppKit

/// The editor pane: a centered fixed-width writing column (FocusTextView).
/// Owns theme/size/font/Modus state and the writing aids (inline completion,
/// automatic pairing, list continuation), shows statistics in the window
/// subtitle, and forwards edits to the document and to the outline/preview.
final class EditorViewController: NSViewController, NSTextViewDelegate,
                                  NSMenuItemValidation, NSToolbarItemValidation {

    private(set) var editorSize: EditorSize = Preferences.editorSize
    private var columnWidth: CGFloat { editorSize.columnWidth }
    private(set) var theme: Theme = Preferences.resolvedTheme()
    private(set) var fontKind: FontKind = Preferences.fontKind
    private(set) var fontSize: CGFloat = Preferences.fontSize
    private(set) var documentKind: DocumentKind = .plain

    private let scrollView = NSScrollView()
    private(set) var textView = FocusTextView(frame: .zero)
    let sounds = TypewriterSounds()
    private let completion = CompletionEngine()
    private var appearanceObservation: NSKeyValueObservation?
    private var showStatistics = Preferences.showStatistics
    private var session = Session()
    private var wordCount = 0
    private var sessionTimer: Timer?
    let goalBar = GoalBar()
    let startView = StartView()
    private var lastEditWasTyping = false
    let vimCoach = VimCoachView()
    private(set) var vimEnabled = Preferences.vimMode

    private weak var document: FocusDocument?
    /// The file this window is editing, used to remember how it was last shown.
    var filePath: String? { document?.fileURL?.standardizedFileURL.path }
    /// Save As gives the document a path; the split view stores the current look under it.
    var onFileURLChanged: (() -> Void)?
    /// Split: the text fills its half of the window, instead of the fixed writing column.
    var fillsPane = false

    /// Called after any content change (text edit or load) so the split
    /// controller can refresh the outline and preview.
    var onTextChanged: (() -> Void)?
    /// Called when the cursor moves (the outline follows it).
    var onCursorMoved: ((Int) -> Void)?
    /// Called after a theme change (the preview follows light/dark).
    var onThemeChanged: (() -> Void)?
    /// Called after the text size changes (the preview zooms with the editor).
    var onFontSizeChanged: (() -> Void)?

    var plainText: String { textView.string }
    var themeIsDark: Bool { theme.isDark }

    /// The preview's own theme, or the editor's when it is set to follow.
    var previewTheme: Theme {
        guard let name = Preferences.previewThemeName else { return theme }
        if name == Theme.systemName { return .system() }
        return ThemeStore.allThemes().first { $0.name == name } ?? theme
    }

    var previewColors: PageColors { previewTheme.pageColors }

    override func loadView() {
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // Markdown/Fountain want straight quotes and plain dashes.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = fontKind.font(ofSize: fontSize)
        textView.editorFont = fontKind.font(ofSize: fontSize)
        textView.focusMode = Preferences.focusMode
        textView.delegate = self
        sounds.enabled = Preferences.soundsEnabled

        textView.autoPairingEnabled = Preferences.autoPairing
        textView.autocompleteEnabled = Preferences.autocomplete
        textView.completionProvider = { [weak self] prefix, linePrefix in
            self?.completion.suffix(forPrefix: prefix, linePrefix: linePrefix)
        }
        syncSystemPredictions()

        if let container = textView.textContainer {
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.lineFragmentPadding = 0
        }
        scrollView.documentView = textView
        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        vimCoach.isHidden = !vimEnabled
        vimCoach.setContentHuggingPriority(.required, for: .vertical)
        let stack = NSStackView(views: [scrollView, vimCoach])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        view = stack
        // The word-goal bar lies over the top edge of the text, so showing it moves nothing.
        goalBar.translatesAutoresizingMaskIntoConstraints = false
        stack.addSubview(goalBar)
        NSLayoutConstraint.activate([
            // Under the toolbar: the content runs beneath it (full-size content view).
            goalBar.topAnchor.constraint(equalTo: stack.safeAreaLayoutGuide.topAnchor),
            goalBar.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            goalBar.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            goalBar.heightAnchor.constraint(equalToConstant: 2),
        ])
        // The start screen sits over an empty untitled document (as on Windows).
        startView.isHidden = true
        startView.translatesAutoresizingMaskIntoConstraints = false
        stack.addSubview(startView)
        NSLayoutConstraint.activate([
            startView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            startView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor, constant: -20),
        ])
        startView.onNewFile = { NSApp.sendAction(#selector(AppDelegate.newFileWizard(_:)), to: nil, from: nil) }
        startView.onOpen = { NSDocumentController.shared.openDocument(nil) }
        startView.onOpenRecent = { url in
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSAlert(error: error).runModal() }
            }
        }

        textView.enableFileDropOpening()
        textView.openFileURLs = { urls in
            for url in urls {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        }

        apply(theme: theme)
        if vimEnabled { enableVim() }
        // The System theme follows macOS light/dark as it changes.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.theme.name == Theme.systemName,
                      self.theme.isDark != Theme.systemIsDark else { return }
                self.apply(theme: .system())
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateStatistics()
        updateStart()
        guard sessionTimer == nil else { return }
        // The session timer counts the seconds spent writing; the subtitle is redrawn while a goal is set.
        sessionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.session.tick()
            if Preferences.wordGoal > 0 { self.updateStatistics() }
        }
    }

    deinit { sessionTimer?.invalidate() }

    /// Palette "Word goal: N words" (0 = off); the session counts from now.
    func setWordGoal(_ words: Int) {
        Preferences.wordGoal = words
        session.reset(words: wordCount)
        updateStatistics()
    }

    // MARK: Vim mode

    private func enableVim() {
        let controller = VimController(textView: textView, coach: vimCoach)
        controller.perform = { [weak self] action in self?.performVim(action) }
        textView.vim = controller
        vimCoach.isHidden = false
    }

    private func disableVim() {
        textView.vim?.detach()
        textView.vim = nil
        vimCoach.isHidden = true
    }

    /// Snapshot demo: Vim mode on without changing the saved preference.
    func showVimForSnapshot(keys: [String]) {
        if !vimEnabled { vimEnabled = true; enableVim() }
        keys.forEach { textView.vim?.engine.handle($0) }
    }

    @objc func toggleVimMode(_ sender: Any?) {
        vimEnabled.toggle()
        Preferences.vimMode = vimEnabled
        if vimEnabled { enableVim() } else { disableVim() }
        view.window?.makeFirstResponder(textView)
    }

    private func performVim(_ action: VimAction) {
        switch action {
        case .save:
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: textView)
        case .close:
            view.window?.performClose(nil)
        case .saveAndClose:
            NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: textView)
            view.window?.performClose(nil)
        case .discardAndClose:
            document?.updateChangeCount(.changeCleared)
            view.window?.performClose(nil)
        case .help:
            NSApp.sendAction(Selector(("showHints:")), to: nil, from: textView)
        case .exitVim:
            if vimEnabled { toggleVimMode(nil) }
        }
    }

    // MARK: Document binding

    func attach(document: FocusDocument) { self.document = document }

    func loadContent(_ text: String, fileExtension ext: String) {
        _ = self.view
        applyKind(DocumentKind(fileExtension: ext))
        completion.update(text: text)
        textView.string = text
        textView.typingAttributes[.font] = fontKind.font(ofSize: fontSize)
        textView.typingAttributes[.foregroundColor] = theme.foreground
        layoutWritingColumn()
        textView.recomputeSyntax()
        textView.refreshFocusEffects()
        textView.needsDisplay = true
        wordCount = Session.countWords(text)
        session.reset(words: wordCount)
        updateStatistics()
        updateStart()
        onTextChanged?()
    }

    /// An untitled, untouched, empty document: nothing to edit yet, so offer the start screen.
    var isPristine: Bool {
        guard let document else { return false }
        return document.fileURL == nil && !document.isDocumentEdited && textView.string.isEmpty
    }

    func updateStart() {
        let show = isPristine && view.window != nil
        if show {
            startView.reload(recent: NSDocumentController.shared.recentDocumentURLs,
                             foreground: theme.foreground, dimmed: theme.dimmed, background: theme.background)
        }
        // The editor's own "Start writing…" line would sit under the panel.
        textView.placeholder = show ? "" : Self.placeholder(for: documentKind)
        if show != !startView.isHidden {
            startView.isHidden = !show
            textView.needsDisplay = true
        }
    }

    /// After Save As / rename to another extension: switch highlighting,
    /// completion and outline to the new type without reloading the text.
    func updateKind(fileExtension ext: String) {
        let kind = DocumentKind(fileExtension: ext)
        guard kind != documentKind else { return }
        applyKind(kind)
        completion.update(text: textView.string)
        textView.recomputeSyntax()
        textView.refreshFocusEffects()
        textView.needsDisplay = true
        onTextChanged?()
    }

    private func applyKind(_ kind: DocumentKind) {
        documentKind = kind
        textView.syntaxEngine = kind.makeHighlighter().map { SyntaxEngine(highlighter: $0) }
        textView.listContinuationEnabled = kind == .markdown
        textView.linkPasteEnabled = kind != .fountain
        textView.liveMarkdownEnabled = kind == .markdown && Preferences.liveMarkdown
        textView.placeholder = Self.placeholder(for: kind)
        completion.kind = kind
    }

    private static func placeholder(for kind: DocumentKind) -> String {
        switch kind {
        case .markdown: return "Start writing — # heading, **bold**, - list   ·   ⌘? hints"
        case .fountain: return "INT. LOCATION - DAY   ·   ⌘? hints"
        case .plain:    return "Start writing…   ·   ⌘? hints"
        }
    }

    /// Select + reveal a range (used by the outline sidebar).
    func scrollTo(range: NSRange) {
        guard range.location != NSNotFound else { return }
        view.window?.makeFirstResponder(textView)
        let safe = NSRange(location: min(range.location, textView.string.utf16.count), length: 0)
        textView.setSelectedRange(safe)
        textView.scrollLine(containing: safe.location, toHeight: 0.3)
        textView.refreshFocusEffects()
    }

    /// Palette "Go to line N": the start of line N (or the last line), in the middle of the view.
    func goToLine(_ number: Int) {
        let ns = textView.string as NSString
        var location = 0
        for _ in 1..<max(1, number) where location < ns.length {
            location = NSMaxRange(ns.lineRange(for: NSRange(location: location, length: 0)))
        }
        if location == ns.length, location > 0, number > 1, ns.character(at: location - 1) != 10 {
            location = ns.lineRange(for: NSRange(location: location - 1, length: 0)).location
        }
        view.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: location, length: 0))
        textView.scrollLine(containing: location, toHeight: 0.5)
        textView.refreshFocusEffects()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutWritingColumn()
        textView.refreshFocusEffects()
    }

    private func layoutWritingColumn() {
        let available = scrollView.contentSize
        let width: CGFloat
        let side: CGFloat
        if fillsPane {
            // The same side inset as the preview, so the two texts are one measure.
            side = 36
            width = max(160, available.width - side * 2)
        } else {
            // A narrow pane (the preview beside it, a small window) narrows the column too.
            width = max(120, min(columnWidth, available.width - 48))
            side = max(24, (available.width - width) / 2)
        }
        // The page runs under the toolbar. That band is not part of the writing area,
        // so a half-window pad measured from the whole window shoved the line downward.
        let covered = scrollView.contentInsets.top
        let visible = max(0, available.height - covered - scrollView.contentInsets.bottom)
        let vertical = textView.verticalPadding(forViewportHeight: visible, coveredTop: covered)
        textView.textContainer?.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: side, height: vertical)
    }

    /// Our own grey suggestion replaces the system inline predictions, so the
    /// two never show at once; with ours off, the system default applies.
    private func syncSystemPredictions() {
        if #available(macOS 14.0, *) {
            textView.inlinePredictionType = textView.autocompleteEnabled ? .no : .default
        }
    }

    // MARK: Theme

    func apply(theme: Theme) {
        self.theme = theme
        scrollView.backgroundColor = theme.background
        textView.backgroundColor = theme.background
        textView.drawsBackground = true
        textView.insertionPointColor = theme.cursor
        textView.textColor = theme.foreground
        textView.typingAttributes[.foregroundColor] = theme.foreground
        textView.activeTextColor = theme.foreground
        textView.dimmedTextColor = theme.dimmed
        vimCoach.apply(background: theme.background, foreground: theme.foreground)
        view.window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        textView.refreshFocusEffects()
        textView.needsDisplay = true
        if !startView.isHidden { updateStart() }
        onThemeChanged?()
    }

    // MARK: Statistics (window subtitle)

    /// The subtitle: words selected, or the session towards the goal, or the word count and
    /// reading time; the bar under the toolbar shows the progress while a goal is set.
    private func updateStatistics() {
        let goal = Preferences.wordGoal
        goalBar.isHidden = goal <= 0
        goalBar.progress = session.progress(goal: goal)
        guard let window = view.window else { return }
        guard showStatistics else { window.subtitle = ""; return }
        let selected = selectedWords()
        if selected > 0 {
            window.subtitle = "\(Session.plural(selected)) selected"
        } else if goal > 0 {
            let reached = session.progress(goal: goal) >= 1 ? " · goal reached" : ""
            window.subtitle = "+\(session.written) / \(goal) words · "
                + Session.formatDuration(ms: session.activeMs) + reached
        } else if wordCount > 0 {
            let minutes = max(1, Int((Double(wordCount) / 200.0).rounded(.up)))
            window.subtitle = "\(Session.plural(wordCount)) · \(minutes) min read"
        } else {
            window.subtitle = ""
        }
    }

    /// Words in the selection (a huge selection is not counted).
    private func selectedWords() -> Int {
        let sel = textView.selectedRange()
        guard sel.length > 0, sel.length <= 200_000, NSMaxRange(sel) <= (textView.string as NSString).length
        else { return 0 }
        return Session.countWords((textView.string as NSString).substring(with: sel))
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView,
                  shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        let replacement = replacementString ?? ""
        let isDeletion = replacement.isEmpty && affectedCharRange.length > 0
        sounds.playForEdit(replacement: replacement, isDeletion: isDeletion)
        if let vim = self.textView.vim, vim.engine.mode == .insert {
            vim.noteTyping(replacement, affected: affectedCharRange)
        }
        lastEditWasTyping = affectedCharRange.length == 0 && replacement.count == 1
            && replacement.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)
        return true
    }

    func textDidChange(_ notification: Notification) {
        textView.recomputeSyntax()
        textView.refreshFocusEffects()
        document?.noteTextEdited()
        completion.update(text: textView.string)
        textView.updateGhost(afterTyping: lastEditWasTyping)
        lastEditWasTyping = false
        if textView.string.utf16.count <= 1 { textView.needsDisplay = true }   // placeholder on/off
        wordCount = Session.countWords(textView.string)
        session.note(words: wordCount)
        if textView.typewriterScrollingEnabled {
            textView.scrollLine(containing: textView.selectedRange().location, toHeight: textView.typewriterAnchor)
        }
        updateStatistics()
        updateStart()
        onTextChanged?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        // Vim Normal mode: the cursor sits on a character, never past the line end.
        if let vim = textView.vim, vim.engine.mode == .normal {
            let sel = textView.selectedRange()
            let ns = textView.string as NSString
            if sel.length == 0, sel.location > 0, sel.location <= ns.length,
               sel.location == ns.length || ns.character(at: sel.location) == 10,
               ns.character(at: sel.location - 1) != 10 {
                textView.setSelectedRange(NSRange(location: sel.location - 1, length: 0))
                return
            }
        }
        textView.clearGhostIfMoved()
        textView.refreshFocusEffects()
        updateStatistics()
        onCursorMoved?(textView.selectedRange().location)
    }

    /// Full completion list (⌥Esc): document words and Fountain cues first,
    /// then the system dictionary suggestions.
    func textView(_ textView: NSTextView, completions words: [String],
                  forPartialWordRange charRange: NSRange,
                  indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
        let ns = textView.string as NSString
        let prefix = ns.substring(with: charRange)
        let lineStart = ns.lineRange(for: charRange).location
        let linePrefix = ns.substring(with: NSRange(location: lineStart,
                                                    length: NSMaxRange(charRange) - lineStart))
        var result = completion.completions(forPrefix: prefix, linePrefix: linePrefix)
        for w in words where !result.contains(w) { result.append(w) }
        index?.pointee = 0
        return result
    }

    // MARK: Modus / View / Edit actions (responder chain)

    @objc func toggleTypewriterScrolling(_ sender: Any?) {
        textView.typewriterScrollingEnabled.toggle()
        layoutWritingColumn()
        textView.refreshFocusEffects()
        if textView.typewriterScrollingEnabled {
            textView.scrollLine(containing: textView.selectedRange().location, toHeight: textView.typewriterAnchor)
        }
    }

    @objc func selectFocusMode(_ sender: NSMenuItem) {
        guard let mode = FocusTextView.FocusMode(rawValue: sender.tag) else { return }
        setFocusMode(mode)
    }

    /// Toolbar button: Off → Sentence → Paragraph → Off.
    @objc func cycleFocusMode(_ sender: Any?) {
        setFocusMode(FocusTextView.FocusMode(rawValue: (textView.focusMode.rawValue + 1) % 3) ?? .off)
    }

    private func setFocusMode(_ mode: FocusTextView.FocusMode) {
        textView.focusMode = mode
        Preferences.focusMode = mode
        textView.refreshFocusEffects()
    }

    @objc func toggleTypewriterSounds(_ sender: Any?) {
        sounds.enabled.toggle()
        Preferences.soundsEnabled = sounds.enabled
    }

    @objc func toggleAutoPairing(_ sender: Any?) {
        textView.autoPairingEnabled.toggle()
        Preferences.autoPairing = textView.autoPairingEnabled
    }

    @objc func toggleAutocomplete(_ sender: Any?) {
        textView.autocompleteEnabled.toggle()
        Preferences.autocomplete = textView.autocompleteEnabled
        if !textView.autocompleteEnabled { textView.clearGhost() }
        syncSystemPredictions()
    }

    @objc func selectTheme(_ sender: NSMenuItem) {
        let themes = ThemeStore.allThemes()
        guard sender.tag >= 0, sender.tag < themes.count else { return }
        apply(theme: themes[sender.tag])
        Preferences.themeName = theme.name
    }

    /// Tag −1 follows the editor. Any other tag is that theme, kept for the preview alone.
    @objc func selectPreviewTheme(_ sender: NSMenuItem) {
        if sender.tag < 0 {
            Preferences.previewThemeName = nil
        } else {
            let themes = ThemeStore.allThemes()
            guard sender.tag < themes.count else { return }
            Preferences.previewThemeName = themes[sender.tag].name
        }
        onThemeChanged?()
    }

    @objc func selectEditorSize(_ sender: NSMenuItem) {
        guard let size = EditorSize(rawValue: CGFloat(sender.tag)) else { return }
        editorSize = size
        Preferences.editorSize = size
        layoutWritingColumn()
        textView.refreshFocusEffects()
    }

    /// Toolbar Full Screen. (Not `toggleFullScreen:` itself: NSWindow validates that one
    /// as a menu item and crashes on a toolbar item.)
    @objc func fullScreenFromToolbar(_ sender: Any?) {
        view.window?.toggleFullScreen(sender)
    }

    /// Toolbar: Small → Medium → Large → Small (as the Windows button).
    @objc func cycleEditorSize(_ sender: Any?) {
        let all = EditorSize.allCases
        let next = all[((all.firstIndex(of: editorSize) ?? 0) + 1) % all.count]
        let item = NSMenuItem()
        item.tag = Int(next.rawValue)
        selectEditorSize(item)
    }

    /// Toolbar: System → Monospace → Serif → System.
    @objc func cycleFontKind(_ sender: Any?) {
        let all = FontKind.allCases
        let next = all[((all.firstIndex(of: fontKind) ?? 0) + 1) % all.count]
        let item = NSMenuItem()
        item.tag = next.rawValue
        selectFontKind(item)
    }

    @objc func selectFontKind(_ sender: NSMenuItem) {
        guard let kind = FontKind(rawValue: sender.tag) else { return }
        fontKind = kind
        Preferences.fontKind = kind
        applyFont()
    }

    /// Zoom, as on Windows: ⌘+ / ⌘− and ⌘-scroll step by 2 points, ⌘0 goes back to the default.
    static let defaultFontSize: CGFloat = 16
    static func zoomedFontSize(_ size: CGFloat, by delta: CGFloat) -> CGFloat {
        min(40, max(10, size + delta))
    }

    @objc func increaseTextSize(_ sender: Any?) { setTextSize(Self.zoomedFontSize(fontSize, by: +2)) }
    @objc func decreaseTextSize(_ sender: Any?) { setTextSize(Self.zoomedFontSize(fontSize, by: -2)) }
    @objc func resetTextSize(_ sender: Any?) { setTextSize(Self.defaultFontSize) }

    private func setTextSize(_ size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        Preferences.fontSize = fontSize
        applyFont()
        onFontSizeChanged?()
    }

    private func applyFont() {
        let font = fontKind.font(ofSize: fontSize)
        textView.editorFont = font
        textView.font = font
        textView.typingAttributes[.font] = font
        layoutWritingColumn()
        textView.recomputeSyntax()
        textView.refreshFocusEffects()
    }

    /// Modus ▸ Live Markup: hide the marks away from the cursor, or always show them.
    @objc func toggleLiveMarkdown(_ sender: Any?) {
        Preferences.liveMarkdown.toggle()
        textView.liveMarkdownEnabled = documentKind == .markdown && Preferences.liveMarkdown
        textView.refreshFocusEffects()
    }

    @objc func toggleStatistics(_ sender: Any?) {
        showStatistics.toggle()
        Preferences.showStatistics = showStatistics
        updateStatistics()
    }

    // MARK: Menu validation

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleTypewriterScrolling(_:)):
            item.state = textView.typewriterScrollingEnabled ? .on : .off
        case #selector(selectFocusMode(_:)):
            item.state = (item.tag == textView.focusMode.rawValue) ? .on : .off
        case #selector(toggleTypewriterSounds(_:)):
            item.state = sounds.enabled ? .on : .off
        case #selector(toggleAutoPairing(_:)):
            item.state = textView.autoPairingEnabled ? .on : .off
        case #selector(toggleAutocomplete(_:)):
            item.state = textView.autocompleteEnabled ? .on : .off
        case #selector(selectTheme(_:)):
            let themes = ThemeStore.allThemes()
            let match = item.tag >= 0 && item.tag < themes.count && themes[item.tag].name == theme.name
            item.state = match ? .on : .off
        case #selector(selectPreviewTheme(_:)):
            if item.tag < 0 {
                item.state = Preferences.previewThemeName == nil ? .on : .off
            } else {
                let themes = ThemeStore.allThemes()
                let match = item.tag < themes.count && themes[item.tag].name == Preferences.previewThemeName
                item.state = match ? .on : .off
            }
        case #selector(selectEditorSize(_:)):
            item.state = (CGFloat(item.tag) == editorSize.rawValue) ? .on : .off
        case #selector(selectFontKind(_:)):
            item.state = (item.tag == fontKind.rawValue) ? .on : .off
        case #selector(toggleVimMode(_:)):
            item.state = vimEnabled ? .on : .off
        case #selector(toggleLiveMarkdown(_:)):
            item.state = Preferences.liveMarkdown ? .on : .off
            return documentKind == .markdown
        case #selector(toggleStatistics(_:)):
            item.title = showStatistics ? "Hide Word Count" : "Show Word Count"
        default:
            break
        }
        return true
    }

    // MARK: Toolbar validation (accent-tinted icon = mode is on)

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.action {
        case #selector(toggleTypewriterScrolling(_:)):
            ToolbarSymbol.update(item, "character.cursor.ibeam", on: textView.typewriterScrollingEnabled)
        case #selector(toggleTypewriterSounds(_:)):
            ToolbarSymbol.update(item, sounds.enabled ? "speaker.wave.2" : "speaker.slash",
                                 on: sounds.enabled)
        case #selector(toggleVimMode(_:)):
            ToolbarSymbol.update(item, "text:Vim", on: vimEnabled)
        case #selector(cycleFontKind(_:)):
            item.toolTip = "Font: \(fontKind.title) — click to change, arrow for the list"
        case #selector(cycleFocusMode(_:)):
            ToolbarSymbol.update(item, "scope", on: textView.focusMode != .off)
            item.toolTip = "Focus: \(textView.focusMode.title) — click to change, arrow for the list"
        default:
            break
        }
        return true
    }
}

/// The thin word-goal progress line under the toolbar: accent colour, green when reached.
final class GoalBar: NSView {
    var progress: Double = 0 { didSet { if progress != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.25).setFill()
        bounds.fill()
        (progress >= 1 ? NSColor.systemGreen : NSColor.controlAccentColor).setFill()
        NSRect(x: 0, y: 0, width: bounds.width * CGFloat(progress), height: bounds.height).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
