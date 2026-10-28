import AppKit
import QuartzCore

/// NSTextView (TextKit 1) with three display-only layers that never touch the
/// saved plain text (the document serialises `string`, not attributes):
///
///  1. Syntax highlighting — colors via `layoutManager.setTemporaryAttributes`
///     (layout-safe); bold/italic/mono as font attributes on the text storage
///     (temporary attributes can't carry layout-affecting fonts, but storage
///     attributes are never written to disk because we save the raw `string`).
///  2. Focus highlighting — dims non-active paragraphs/sentences by blending the
///     resolved color toward the dimmed color, so markup styling survives dimming.
///  3. Typewriter scrolling — pins the caret line at ~`typewriterAnchor` height.
///  4. Live Markdown — the marks of formatting away from the cursor get `.null`
///     glyphs (`LiveMarkdown` finds them), and headings get their size.
///
/// Dropping a .txt/.md/.fountain file opens it as a document instead of pasting.
final class FocusTextView: NSTextView {

    /// Focus-highlighting granularity.
    enum FocusMode: Int {
        case off, sentence, paragraph
        var title: String {
            switch self {
            case .off:       return "Off"
            case .sentence:  return "Sentence"
            case .paragraph: return "Paragraph"
            }
        }
    }

    // MARK: Modus toggles
    /// Off until the toolbar button (⌘T): a new or reopened file starts at the top.
    var typewriterScrollingEnabled = false
    var focusMode: FocusMode = .paragraph
    var typewriterAnchor: CGFloat = 0.5

    // MARK: Colors (set from the theme)
    var activeTextColor: NSColor = .labelColor
    var dimmedTextColor: NSColor = .tertiaryLabelColor
    var accentColor: NSColor = NSColor(srgbRed: 0.20, green: 0.60, blue: 0.85, alpha: 1)

    // MARK: Syntax
    var syntaxEngine: SyntaxEngine?
    private var tokens: [SyntaxToken] = []

    /// Opening dropped document files (set by the controller).
    var openFileURLs: (([URL]) -> Void)?

    // MARK: Vim mode
    /// Set while Vim mode is on; gets every key first.
    var vim: VimController?
    /// Normal/Visual mode draw a block cursor over the character.
    var blockCursor = false {
        didSet { if blockCursor != oldValue { needsDisplay = true; updateInsertionPointStateAndRestartTimer(true) } }
    }

    override func keyDown(with event: NSEvent) {
        if let vim, vim.handle(event) { return }
        super.keyDown(with: event)
    }

    private var blockCursorWidth: CGFloat {
        let caret = selectedRange().location
        if let lm = layoutManager, let tc = textContainer, caret < (textStorage?.length ?? 0),
           (string as NSString).character(at: caret) != 10 {
            let glyph = lm.glyphIndexForCharacter(at: caret)
            let w = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc).width
            if w > 1 { return w }
        }
        return ("m" as NSString).size(withAttributes: [.font: baseFont]).width
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard blockCursor else { return super.drawInsertionPoint(in: rect, color: color, turnedOn: flag) }
        var r = rect
        r.size.width = blockCursorWidth
        super.drawInsertionPoint(in: r, color: color.withAlphaComponent(0.45), turnedOn: flag)
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        var r = rect
        if blockCursor { r.size.width += blockCursorWidth }
        super.setNeedsDisplay(r, avoidAdditionalLayout: flag)
    }

    // MARK: Writing aids
    var placeholder = "Start writing…"
    var autoPairingEnabled = true
    var listContinuationEnabled = false
    /// Selected text + a pasted web address = a Markdown link (not in Fountain).
    var linkPasteEnabled = false
    var autocompleteEnabled = true
    /// Returns the text to append after the typed `prefix` (grey inline suggestion).
    var completionProvider: ((_ prefix: String, _ linePrefix: String) -> String?)?
    private(set) var ghostSuffix = ""
    private var ghostLocation = NSNotFound

    override func paste(_ sender: Any?) {
        if !pasteLink(from: .general) { super.paste(sender) }
    }

    /// Replace the selection with a Markdown link when `pasteboard` holds one web address.
    func pasteLink(from pasteboard: NSPasteboard) -> Bool {
        let sel = selectedRange()
        let ns = string as NSString
        guard linkPasteEnabled, sel.length > 0, NSMaxRange(sel) <= ns.length,
              selectedRanges.count == 1,
              let clip = pasteboard.string(forType: .string),
              let link = LinkPaste.link(selected: ns.substring(with: sel), clipboard: clip),
              shouldChangeText(in: sel, replacementString: link)
        else { return false }
        textStorage?.replaceCharacters(in: sel, with: link)
        didChangeText()
        let end = sel.location + (link as NSString).length
        setSelectedRange(NSRange(location: end, length: 0))
        scrollRangeToVisible(NSRange(location: end, length: 0))
        return true
    }

    // MARK: Public entry points

    func recomputeSyntax() {
        tokens = syntaxEngine?.tokens(for: string as NSString) ?? []
        liveElements = liveMarkdownEnabled ? live.elements(in: string as NSString) : []
        applyTokenFonts()
        updateLiveHiding()
    }

    /// Re-run focus + syntax color rendering. Typewriter scrolling is separate:
    /// a layout pass must not yank the line the reader is looking at.
    func refreshFocusEffects() {
        updateLiveHiding()
        renderFocus()
    }

    // MARK: Live Markdown (hidden marks, heading sizes)

    var liveMarkdownEnabled = false {
        didSet {
            guard liveMarkdownEnabled != oldValue else { return }
            // Glyph generation asks us what to hide; edits shift what is hidden.
            layoutManager?.delegate = self
            textStorage?.delegate = self
            recomputeSyntax()
        }
    }
    private let live = LiveMarkdown()
    private var liveElements: [LiveElement] = []
    /// Characters drawn as nothing (`.null` glyphs) right now.
    private var hiddenMarks = IndexSet()
    /// Edited since the last update: their glyphs are redone then.
    private var staleGlyphs = IndexSet()

    /// Hide the marks of what the selection doesn't touch; redo only the glyphs that change.
    private func updateLiveHiding() {
        let selection = selectedRanges.map(\.rangeValue)
        let new = liveMarkdownEnabled ? LiveMarkdown.hidden(liveElements, selection: selection) : IndexSet()
        guard new != hiddenMarks || !staleGlyphs.isEmpty,
              let lm = layoutManager, let length = textStorage?.length else { return }
        let changed = new.symmetricDifference(hiddenMarks).union(staleGlyphs.intersection(new))
        hiddenMarks = new
        staleGlyphs = IndexSet()
        for r in changed.rangeView {
            guard let range = clamp(NSRange(location: r.lowerBound, length: r.count), to: length) else { continue }
            lm.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            lm.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
        }
    }

    /// Heading sizes: the same wherever the cursor is, so lines don't jump.
    private static let headingScale: [CGFloat] = [1.7, 1.4, 1.2, 1.1, 1, 1]

    private func applyLiveFonts(_ ts: NSTextStorage) {
        ts.removeAttribute(.strikethroughStyle, range: NSRange(location: 0, length: ts.length))
        for e in liveElements {
            switch e.kind {
            case .heading(let level):
                guard let r = clamp(e.range, to: ts.length) else { continue }
                let size = baseFont.pointSize * Self.headingScale[min(max(level, 1), 6) - 1]
                let bold = NSFont(descriptor: baseFont.fontDescriptor.withSymbolicTraits(.bold), size: size)
                ts.addAttribute(.font, value: bold ?? baseFont, range: r)
            case .image(let caption):
                guard let r = clamp(caption, to: ts.length) else { continue }
                ts.addAttribute(.font, value: styledFont(SyntaxRole.Style(bold: false, italic: true, mono: false)), range: r)
            case .strikethrough:
                guard let r = clamp(e.range, to: ts.length) else { continue }
                ts.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            case .inline:
                break
            }
        }
    }

    // MARK: Drag & drop — open files as documents

    func enableFileDropOpening() {
        registerForDraggedTypes([.fileURL])
    }

    private func droppedDocumentURLs(_ sender: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: opts) as? [URL] ?? []
        let exts: Set<String> = ["txt", "md", "markdown", "mdown", "mkd", "fountain", "rtf"]
        return urls.filter { exts.contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedDocumentURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        droppedDocumentURLs(sender).isEmpty ? super.prepareForDragOperation(sender) : true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedDocumentURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        openFileURLs?(urls)
        return true
    }

    // MARK: Typewriter scrolling

    /// A click or a drag must not yank the page, as on Windows. Typing and the
    /// keyboard still keep the caret line centred.
    private var pointerSelecting = false

    override func mouseDown(with event: NSEvent) {
        pointerSelecting = true
        super.mouseDown(with: event)
        pointerSelecting = false
    }

    /// Room above the text. Typewriter mode uses 45% of the editor (Windows uses
    /// 45vh), measured below the toolbar; otherwise a short margin.
    func verticalPadding(forViewportHeight height: CGFloat, coveredTop: CGFloat = 0) -> CGFloat {
        guard typewriterScrollingEnabled else { return 48 }
        return coveredTop + max(0, height) * 0.45
    }

    /// AppKit's own scroll pins the caret to the top. While typing or moving
    /// with the keyboard the caret line stays at `typewriterAnchor`.
    override func scrollRangeToVisible(_ range: NSRange) {
        guard typewriterScrollingEnabled, !pointerSelecting else {
            return super.scrollRangeToVisible(range)
        }
        scrollLine(containing: range.location, toHeight: typewriterAnchor)
    }

    /// Scroll so the line holding `charIndex` sits at `anchor` of the area below the toolbar.
    func scrollLine(containing charIndex: Int, toHeight anchor: CGFloat) {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer,
              let clipView = enclosingScrollView?.contentView
        else { return }

        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let needed = ceil(used.height + textContainerInset.height * 2)
        if bounds.height + 1 < needed {
            setFrameSize(NSSize(width: bounds.width, height: needed))
        }

        let lineRect = lineFragmentRect(forCharacterAt: charIndex)
        let lineMidYInView = lineRect.midY + textContainerOrigin.y

        let viewportHeight = clipView.bounds.height
        guard viewportHeight > 0 else { return }
        let insets = enclosingScrollView?.contentInsets ?? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        let visible = max(1, viewportHeight - insets.top - insets.bottom)
        let centerY = insets.top + visible * anchor

        var targetY = lineMidYInView - centerY
        let maxY = max(0, bounds.height - viewportHeight)
        targetY = min(max(targetY, 0), maxY)

        if abs(clipView.bounds.origin.y - targetY) > 0.5 {
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
            enclosingScrollView?.reflectScrolledClipView(clipView)
        }
    }

    private func lineFragmentRect(forCharacterAt charIndex: Int) -> NSRect {
        guard let layoutManager = layoutManager else { return .zero }
        let glyphCount = layoutManager.numberOfGlyphs
        if glyphCount == 0 { return layoutManager.extraLineFragmentUsedRect }
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: min(charIndex, glyphCount - 1))
        if glyphIndex >= glyphCount {
            let extra = layoutManager.extraLineFragmentRect
            return extra != .zero ? extra
                : layoutManager.lineFragmentRect(forGlyphAt: glyphCount - 1, effectiveRange: nil)
        }
        return layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    }

    // MARK: Syntax fonts (display-only storage attributes; never serialised)

    /// The editor's body font, set by the controller. Kept explicitly because
    /// `NSTextView.font` reports the font of the *first character* — for a
    /// document opening with a heading that is bold, and would spread.
    var editorFont: NSFont?

    private var baseFont: NSFont { editorFont ?? .systemFont(ofSize: NSFont.systemFontSize) }

    private func applyTokenFonts() {
        guard let ts = textStorage, ts.length > 0 else { return }
        let full = NSRange(location: 0, length: ts.length)
        ts.beginEditing()
        ts.addAttribute(.font, value: baseFont, range: full)   // reset to base
        for tok in tokens {
            let style = tok.role.style
            guard style.bold || style.italic || style.mono,
                  let r = clamp(tok.range, to: ts.length) else { continue }
            ts.addAttribute(.font, value: styledFont(style), range: r)
        }
        applyLiveFonts(ts)
        ts.endEditing()
    }

    private func styledFont(_ style: SyntaxRole.Style) -> NSFont {
        var f = style.mono
            ? NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
            : baseFont
        var traits: NSFontDescriptor.SymbolicTraits = []
        if style.bold { traits.insert(.bold) }
        if style.italic { traits.insert(.italic) }
        if !traits.isEmpty {
            let d = f.fontDescriptor.withSymbolicTraits(traits)
            if let nf = NSFont(descriptor: d, size: baseFont.pointSize) { f = nf }
        }
        return f
    }

    // MARK: Focus + syntax color rendering (temporary attributes)

    private var lastActiveRange = NSRange(location: NSNotFound, length: 0)
    private var litRanges: [(range: NSRange, intensity: CGFloat)] = []
    private var fadeFromRange = NSRange(location: 0, length: 0)
    private var fadeToRange = NSRange(location: 0, length: 0)
    private var fadeTimer: Timer?
    private var fadeStart: CFTimeInterval = 0
    private let fadeDuration: CFTimeInterval = 0.18

    private func renderFocus() {
        if focusMode == .off {
            stopFade()
            lastActiveRange = NSRange(location: NSNotFound, length: 0)
            litRanges = []
            paint()
            return
        }

        let newActive = activeRange(for: focusMode)
        let moved = lastActiveRange.location != NSNotFound
            && newActive.location != lastActiveRange.location

        if moved {
            startFade(from: lastActiveRange, to: newActive)
        } else {
            stopFade()
            litRanges = [(newActive, 1)]
            paint()
        }
        lastActiveRange = newActive
    }

    /// Resolve all temporary foreground colors for the current lit ranges.
    private func paint() {
        guard let lm = layoutManager, let len = textStorage?.length, len > 0 else { return }
        let full = NSRange(location: 0, length: len)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)

        if focusMode == .off {
            paintColors(in: full, intensity: 1)
        } else {
            paintColors(in: full, intensity: 0)              // dim baseline
            for lit in litRanges { paintColors(in: lit.range, intensity: lit.intensity) }
        }
    }

    /// Paint one range: base color then token colors, each blended dim→full by `intensity`.
    private func paintColors(in range: NSRange, intensity: CGFloat) {
        guard let lm = layoutManager, let len = textStorage?.length,
              let region = clamp(range, to: len) else { return }
        let base = blend(dimmedTextColor, activeTextColor, intensity)
        lm.addTemporaryAttributes([.foregroundColor: base], forCharacterRange: region)
        for tok in tokens {
            guard let color = tok.role.color(active: activeTextColor,
                                             dim: dimmedTextColor, accent: accentColor),
                  let inter = intersection(tok.range, region) else { continue }
            lm.addTemporaryAttributes([.foregroundColor: blend(dimmedTextColor, color, intensity)],
                                      forCharacterRange: inter)
        }
    }

    // MARK: Active range

    private func activeRange(for mode: FocusMode) -> NSRange {
        let ns = string as NSString
        let sel = selectedRange()
        let paragraph = FocusUnit.range(in: ns, around: sel.location)
        guard mode == .sentence else { return paragraph }

        // A line break ends a sentence for the enumerator; in a hard-wrapped paragraph it does not.
        // A space has the same length, so the ranges stay valid.
        let flat = ns.substring(with: paragraph)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ") as NSString
        var result = paragraph
        flat.enumerateSubstrings(
            in: NSRange(location: 0, length: flat.length), options: [.bySentences, .localized]
        ) { _, subRange, _, stop in
            let absolute = NSRange(location: paragraph.location + subRange.location, length: subRange.length)
            let end = absolute.location + absolute.length
            if NSLocationInRange(sel.location, absolute) || sel.location == end {
                result = absolute
                stop.pointee = true
            }
        }
        return result
    }

    // MARK: Fade animation

    private func startFade(from: NSRange, to: NSRange) {
        fadeFromRange = from
        fadeToRange = to
        fadeStart = CACurrentMediaTime()
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) {
            [weak self] _ in self?.stepFade()
        }
        stepFade()
    }

    private func stepFade() {
        let p = min(1.0, max(0.0, CGFloat((CACurrentMediaTime() - fadeStart) / fadeDuration)))
        litRanges = [(fadeFromRange, 1 - p), (fadeToRange, p)]
        paint()
        if p >= 1.0 {
            stopFade()
            litRanges = [(fadeToRange, 1)]
        }
    }

    private func stopFade() {
        fadeTimer?.invalidate()
        fadeTimer = nil
    }

    // MARK: Inline completion (grey "ghost" suffix after the caret)

    /// Recompute the suggestion. Only shown right after typing a character,
    /// at the end of a line (so the grey text never overlaps real text).
    func updateGhost(afterTyping typed: Bool) {
        let previous = ghostSuffix
        ghostSuffix = ""
        ghostLocation = NSNotFound
        defer { if previous != ghostSuffix { setNeedsDisplay(visibleRect) } }

        guard typed, autocompleteEnabled, let provider = completionProvider,
              !hasMarkedText() else { return }
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let ns = string as NSString
        let caret = sel.location
        if caret < ns.length {
            let next = ns.character(at: caret)
            guard next == 0x0A || next == 0x0D else { return }
        }
        var start = caret
        while start > 0, let scalar = UnicodeScalar(ns.character(at: start - 1)),
              Self.isWordScalar(scalar) {
            start -= 1
        }
        let prefix = ns.substring(with: NSRange(location: start, length: caret - start))
        guard prefix.count >= 2 else { return }
        let lineStart = ns.lineRange(for: NSRange(location: caret, length: 0)).location
        let linePrefix = ns.substring(with: NSRange(location: lineStart, length: caret - lineStart))
        if let suffix = provider(prefix, linePrefix), !suffix.isEmpty {
            ghostSuffix = suffix
            ghostLocation = caret
        }
    }

    func clearGhostIfMoved() {
        guard !ghostSuffix.isEmpty else { return }
        if selectedRange() != NSRange(location: ghostLocation, length: 0) { clearGhost() }
    }

    func clearGhost() {
        guard !ghostSuffix.isEmpty else { return }
        ghostSuffix = ""
        ghostLocation = NSNotFound
        setNeedsDisplay(visibleRect)
    }

    @discardableResult
    func acceptGhost() -> Bool {
        guard !ghostSuffix.isEmpty,
              selectedRange() == NSRange(location: ghostLocation, length: 0) else { return false }
        let suffix = ghostSuffix
        clearGhost()
        insertText(suffix, replacementRange: selectedRange())
        return true
    }

    private static func isWordScalar(_ s: UnicodeScalar) -> Bool {
        CharacterSet.alphanumerics.contains(s) || s == "'" || s == "’" || s == "-"
    }

    override func insertTab(_ sender: Any?) {
        if acceptGhost() { return }
        super.insertTab(sender)
    }

    override func moveRight(_ sender: Any?) {
        if acceptGhost() { return }
        super.moveRight(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        if !ghostSuffix.isEmpty { clearGhost(); return }
        super.cancelOperation(sender)
    }

    override func complete(_ sender: Any?) {
        if !ghostSuffix.isEmpty { clearGhost(); return }
        super.complete(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !placeholder.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: dimmedTextColor]
            let o = textContainerOrigin
            (placeholder as NSString).draw(
                at: NSPoint(x: o.x + (textContainer?.lineFragmentPadding ?? 0), y: o.y),
                withAttributes: attrs)
        }
        drawGhost()
    }

    private func drawGhost() {
        guard !ghostSuffix.isEmpty, ghostLocation != NSNotFound, ghostLocation > 0,
              ghostLocation <= (textStorage?.length ?? 0),
              selectedRange() == NSRange(location: ghostLocation, length: 0),
              let lm = layoutManager, let tc = textContainer else { return }
        let glyph = lm.glyphIndexForCharacter(at: ghostLocation - 1)
        guard glyph < lm.numberOfGlyphs else { return }
        let line = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let glyphRect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        let baseline = lm.location(forGlyphAt: glyph).y
        let font = (textStorage?.attribute(.font, at: ghostLocation - 1, effectiveRange: nil) as? NSFont)
            ?? baseFont
        let o = textContainerOrigin
        let point = NSPoint(x: o.x + glyphRect.maxX, y: o.y + line.minY + baseline - font.ascender)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: dimmedTextColor.withAlphaComponent(0.85),
        ]
        (ghostSuffix as NSString).draw(at: point, withAttributes: attrs)
    }

    // MARK: Automatic pairing

    private static let openers: [String: String] = [
        "(": ")", "[": "]", "{": "}", "\"": "\"", "`": "`", "«": "»", "“": "”",
    ]
    private static let closers: Set<String> = [")", "]", "}", "\"", "`", "»", "”"]

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let typed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        guard autoPairingEnabled, let s = typed, s.count == 1, !hasMarkedText() else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let sel = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        let ns = string as NSString
        let next: String? = sel.location < ns.length
            ? ns.substring(with: NSRange(location: sel.location, length: 1)) : nil
        let prev: String? = sel.location > 0
            ? ns.substring(with: NSRange(location: sel.location - 1, length: 1)) : nil

        // Type over a closer that is already there.
        if sel.length == 0, Self.closers.contains(s), next == s {
            setSelectedRange(NSRange(location: sel.location + 1, length: 0))
            return
        }
        guard let close = Self.openers[s] else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        // Wrap the selection.
        if sel.length > 0 {
            let inner = ns.substring(with: sel)
            super.insertText(s + inner + close, replacementRange: sel)
            setSelectedRange(NSRange(location: sel.location + 1, length: (inner as NSString).length))
            return
        }
        let symmetric = s == close
        let prevIsWord = prev.map { $0.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) } ?? false
        let nextIsFree = next.map {
            $0 == "\n" || $0 == " " || $0 == "\t" || $0 == "," || $0 == "." || Self.closers.contains($0)
        } ?? true
        guard nextIsFree, !(symmetric && prevIsWord) else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        super.insertText(s + close, replacementRange: sel)
        setSelectedRange(NSRange(location: sel.location + 1, length: 0))
    }

    override func deleteBackward(_ sender: Any?) {
        clearGhost()
        let sel = selectedRange()
        let ns = string as NSString
        if autoPairingEnabled, sel.length == 0, sel.location > 0, sel.location < ns.length {
            let prev = ns.substring(with: NSRange(location: sel.location - 1, length: 1))
            let next = ns.substring(with: NSRange(location: sel.location, length: 1))
            if let close = Self.openers[prev], close == next {
                setSelectedRange(NSRange(location: sel.location - 1, length: 2))
            }
        }
        super.deleteBackward(sender)
    }

    // MARK: List continuation (Markdown)

    private static let listMarker = RegexUtil.regex(#"^(\s*)(?:([-*+])|(\d+)([.)]))(\s+)(\[[ xX]\]\s+)?"#)
    private static let quoteMarker = RegexUtil.regex(#"^(\s*>\s?)"#)

    private enum ListContinuation {
        case end(NSRange)     // empty item: remove its marker
        case next(String)     // insert newline + this marker
    }

    override func insertNewline(_ sender: Any?) {
        clearGhost()
        guard listContinuationEnabled, selectedRange().length == 0, !hasMarkedText(),
              let continuation = listContinuation() else {
            super.insertNewline(sender)
            return
        }
        switch continuation {
        case .end(let markerRange):
            insertText("", replacementRange: markerRange)
        case .next(let marker):
            insertText("\n" + marker, replacementRange: selectedRange())
        }
    }

    private func listContinuation() -> ListContinuation? {
        let ns = string as NSString
        let caret = selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        var lineEnd = lineRange.location + lineRange.length
        if lineEnd > lineRange.location, ns.character(at: lineEnd - 1) == 0x0A { lineEnd -= 1 }
        let line = ns.substring(with: NSRange(location: lineRange.location, length: lineEnd - lineRange.location))
        let beforeCaret = ns.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        let b = beforeCaret as NSString

        func isEmptyItem(_ markerLength: Int) -> Bool {
            caret == lineEnd
                && (line as NSString).substring(from: markerLength).trimmingCharacters(in: .whitespaces).isEmpty
        }

        if let m = RegexUtil.matches(Self.listMarker, in: beforeCaret).first {
            if isEmptyItem(m.range.length) {
                return .end(NSRange(location: lineRange.location, length: m.range.length))
            }
            let indent = b.substring(with: m.range(at: 1))
            let spacing = b.substring(with: m.range(at: 5))
            let task = m.range(at: 6).location != NSNotFound ? "[ ] " : ""
            if m.range(at: 2).location != NSNotFound {
                return .next(indent + b.substring(with: m.range(at: 2)) + spacing + task)
            }
            let number = (Int(b.substring(with: m.range(at: 3))) ?? 0) + 1
            return .next(indent + "\(number)" + b.substring(with: m.range(at: 4)) + spacing + task)
        }
        if let m = RegexUtil.matches(Self.quoteMarker, in: beforeCaret).first {
            if isEmptyItem(m.range.length) {
                return .end(NSRange(location: lineRange.location, length: m.range.length))
            }
            return .next(b.substring(with: m.range(at: 1)))
        }
        return nil
    }

    // MARK: Helpers

    private func clamp(_ range: NSRange, to length: Int) -> NSRange? {
        let loc = min(max(0, range.location), length)
        let len = min(range.length, length - loc)
        return len > 0 ? NSRange(location: loc, length: len) : nil
    }

    private func intersection(_ a: NSRange, _ b: NSRange) -> NSRange? {
        let lo = max(a.location, b.location)
        let hi = min(a.location + a.length, b.location + b.length)
        return hi > lo ? NSRange(location: lo, length: hi - lo) : nil
    }

    private func blend(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let ca = a.usingColorSpace(.sRGB) ?? a
        let cb = b.usingColorSpace(.sRGB) ?? b
        let tt = min(max(t, 0), 1)
        return NSColor(srgbRed: ca.redComponent + (cb.redComponent - ca.redComponent) * tt,
                       green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * tt,
                       blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * tt,
                       alpha: ca.alphaComponent + (cb.alphaComponent - ca.alphaComponent) * tt)
    }
}

// MARK: - Live Markdown plumbing

extension FocusTextView: NSLayoutManagerDelegate, NSTextStorageDelegate {

    /// Hidden marks become `.null` glyphs: no width, nothing drawn, no gap in the line.
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>,
                       font aFont: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        let count = glyphRange.length
        guard !hiddenMarks.isEmpty,
              (0..<count).contains(where: { hiddenMarks.contains(charIndexes[$0]) }) else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: count))
        for i in 0..<count where hiddenMarks.contains(charIndexes[i]) { properties[i] = .null }
        properties.withUnsafeBufferPointer {
            layoutManager.setGlyphs(glyphs, properties: $0.baseAddress!, characterIndexes: charIndexes,
                                    font: aFont, forGlyphRange: glyphRange)
        }
        return count
    }

    /// An edit moves the text after it: move the hidden marks with it, so the set
    /// keeps matching the glyphs. The edited range (often the whole paragraph, as
    /// attribute fixes join it) gets new glyphs anyway: drop its marks now and
    /// redo it at the next update.
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), liveMarkdownEnabled || !hiddenMarks.isEmpty else { return }
        let oldEnd = NSMaxRange(editedRange) - delta
        if oldEnd > editedRange.location { hiddenMarks.remove(integersIn: editedRange.location..<oldEnd) }
        hiddenMarks.shift(startingAt: oldEnd, by: delta)
        staleGlyphs.shift(startingAt: oldEnd, by: delta)
        staleGlyphs.insert(integersIn: editedRange.location..<NSMaxRange(editedRange))
    }
}
