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
    var typewriterScrollingEnabled = true
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

    // MARK: Writing aids
    var placeholder = "Start writing…"
    var autoPairingEnabled = true
    var listContinuationEnabled = false
    var autocompleteEnabled = true
    /// Returns the text to append after the typed `prefix` (grey inline suggestion).
    var completionProvider: ((_ prefix: String, _ linePrefix: String) -> String?)?
    private(set) var ghostSuffix = ""
    private var ghostLocation = NSNotFound

    // MARK: Public entry points

    func recomputeSyntax() {
        tokens = syntaxEngine?.tokens(for: string as NSString) ?? []
        applyTokenFonts()
    }

    /// Re-run focus + syntax color rendering and keep the caret pinned.
    func refreshFocusEffects() {
        renderFocus()
        centerCaretLineIfNeeded()
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

    func verticalPadding(forViewportHeight height: CGFloat) -> CGFloat {
        max(0, height * max(typewriterAnchor, 1 - typewriterAnchor))
    }

    private func centerCaretLineIfNeeded() {
        guard typewriterScrollingEnabled,
              let layoutManager = layoutManager,
              let textContainer = textContainer,
              let clipView = enclosingScrollView?.contentView
        else { return }

        layoutManager.ensureLayout(for: textContainer)

        let caret = selectedRange().location
        let lineRect = lineFragmentRect(forCharacterAt: caret)
        let lineMidYInView = lineRect.midY + textContainerOrigin.y

        let viewportHeight = clipView.bounds.height
        guard viewportHeight > 0 else { return }

        var targetY = lineMidYInView - viewportHeight * typewriterAnchor
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
        let paragraph = ns.paragraphRange(for: sel)
        guard mode == .sentence else { return paragraph }

        var result = paragraph
        ns.enumerateSubstrings(in: paragraph, options: [.bySentences, .localized]) {
            _, subRange, _, stop in
            let end = subRange.location + subRange.length
            if NSLocationInRange(sel.location, subRange) || sel.location == end {
                result = subRange
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
