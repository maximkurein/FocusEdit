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
    private var showStatistics = Preferences.showStatistics
    private var lastEditWasTyping = false

    private weak var document: FocusDocument?

    /// Called after any content change (text edit or load) so the split
    /// controller can refresh the outline and preview.
    var onTextChanged: (() -> Void)?

    var plainText: String { textView.string }
    var themeIsDark: Bool { theme.isDark }

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
        view = scrollView

        textView.enableFileDropOpening()
        textView.openFileURLs = { urls in
            for url in urls {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            }
        }

        apply(theme: theme)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        updateStatistics()
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
        updateStatistics()
        onTextChanged?()
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
        textView.scrollRangeToVisible(safe)
        textView.refreshFocusEffects()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutWritingColumn()
        textView.refreshFocusEffects()
    }

    private func layoutWritingColumn() {
        let available = scrollView.contentSize
        let side = max(24, (available.width - columnWidth) / 2)
        let vertical = textView.verticalPadding(forViewportHeight: available.height)
        textView.textContainer?.size = NSSize(width: columnWidth, height: CGFloat.greatestFiniteMagnitude)
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
        view.window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        textView.refreshFocusEffects()
        textView.needsDisplay = true
    }

    // MARK: Statistics (window subtitle)

    private func updateStatistics() {
        guard let window = view.window else { return }
        guard showStatistics else { window.subtitle = ""; return }
        let words = textView.string.split { $0.isWhitespace }.count
        guard words > 0 else { window.subtitle = ""; return }
        let minutes = max(1, Int((Double(words) / 200.0).rounded(.up)))
        window.subtitle = "\(words) word\(words == 1 ? "" : "s") · \(minutes) min read"
    }

    // MARK: NSTextViewDelegate

    func textView(_ textView: NSTextView,
                  shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        let replacement = replacementString ?? ""
        let isDeletion = replacement.isEmpty && affectedCharRange.length > 0
        sounds.playForEdit(replacement: replacement, isDeletion: isDeletion)
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
        updateStatistics()
        onTextChanged?()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView.clearGhostIfMoved()
        textView.refreshFocusEffects()
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
        textView.refreshFocusEffects()
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

    @objc func selectEditorSize(_ sender: NSMenuItem) {
        guard let size = EditorSize(rawValue: CGFloat(sender.tag)) else { return }
        editorSize = size
        Preferences.editorSize = size
        layoutWritingColumn()
        textView.refreshFocusEffects()
    }

    @objc func selectFontKind(_ sender: NSMenuItem) {
        guard let kind = FontKind(rawValue: sender.tag) else { return }
        fontKind = kind
        Preferences.fontKind = kind
        applyFont()
    }

    @objc func increaseTextSize(_ sender: Any?) { adjustTextSize(by: +1) }
    @objc func decreaseTextSize(_ sender: Any?) { adjustTextSize(by: -1) }

    private func adjustTextSize(by delta: CGFloat) {
        fontSize = min(40, max(10, fontSize + delta))
        Preferences.fontSize = fontSize
        applyFont()
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
        case #selector(selectEditorSize(_:)):
            item.state = (CGFloat(item.tag) == editorSize.rawValue) ? .on : .off
        case #selector(selectFontKind(_:)):
            item.state = (item.tag == fontKind.rawValue) ? .on : .off
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
        case #selector(cycleFocusMode(_:)):
            ToolbarSymbol.update(item, "scope", on: textView.focusMode != .off)
            item.toolTip = "Focus: \(textView.focusMode.title) — click to change (⌘0 ⌘1 ⌘2)"
        default:
            break
        }
        return true
    }
}
