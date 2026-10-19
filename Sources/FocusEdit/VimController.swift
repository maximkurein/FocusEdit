import AppKit

/// Connects VimEngine to the FocusTextView: turns key events into Vim keys,
/// draws the block cursor, records Insert-mode typing for ".", runs :w/:q,
/// and drives the coach bar under the editor.
final class VimController {

    let engine: VimEngine
    private weak var textView: FocusTextView?
    private let coach: VimCoachView
    /// Save / close / help, carried out by the editor (it knows the document).
    var perform: ((VimAction) -> Void)?

    init(textView: FocusTextView, coach: VimCoachView) {
        self.textView = textView
        self.coach = coach
        engine = VimEngine(buffer: TextViewVimBuffer(textView))
        engine.onModeChange = { [weak self] mode in self?.modeChanged(mode) }
        engine.onFeedback = { [weak self] _, _ in self?.refreshCoach() }
        engine.onAction = { [weak self] action in self?.perform?(action) }
        engine.reset()
        modeChanged(engine.mode)
    }

    func detach() {
        textView?.blockCursor = false
    }

    /// Returns true when Vim consumed the key (the text view must not handle it).
    func handle(_ event: NSEvent) -> Bool {
        guard let key = token(for: event) else { return false }
        if engine.mode == .insert {
            guard key == "<Esc>" else { return false } // typing goes to the text view
            textView?.clearGhost()
        }
        return engine.handle(key)
    }

    /// Insert-mode typing reported by the text view delegate (for ".").
    func noteTyping(_ replacement: String, affected: NSRange) {
        let deleted = replacement.isEmpty ? affected.length : 0
        engine.noteInserted(replacement, deletedBackward: deleted)
    }

    func refreshCoach() {
        coach.update(mode: engine.mode, pending: engine.pendingKeys, feedback: engine.feedback,
                     tip: engine.tip, commandPrefix: engine.commandPrefix, commandLine: engine.commandLine)
    }

    private func modeChanged(_ mode: VimMode) {
        textView?.blockCursor = mode != .insert && mode != .commandLine
        refreshCoach()
    }

    // MARK: Keys

    private func token(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { return nil } // ⌘ shortcuts stay with the menus
        switch event.keyCode {
        case 53: return "<Esc>"
        case 36, 76: return "<CR>"
        case 51: return "<BS>"
        case 123: return "<Left>"
        case 124: return "<Right>"
        case 125: return "<Down>"
        case 126: return "<Up>"
        default: break
        }
        if flags.contains(.control) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "r", "к": return "<C-r>"
            case "[", "х": return "<Esc>"
            default: return nil
            }
        }
        guard let chars = event.characters, chars.count == 1 else { return nil }
        // Russian layout: commands still work by physical key (like NeoVim's langmap),
        // but characters Vim is waiting for (f/t/r targets, search text) stay as typed.
        if engine.mode != .insert, engine.mode != .commandLine, !engine.wantsLiteralCharacter,
           let latin = Self.langmap[chars] {
            return latin
        }
        return chars
    }

    /// ЙЦУКЕН → QWERTY by physical key position.
    static let langmap: [String: String] = {
        let ru = "йцукенгшщзхъфывапролджэячсмитьбю" + "ЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ" + "ёЁ"
        let en = "qwertyuiop[]asdfghjkl;'zxcvbnm,." + "QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>" + "`~"
        var map: [String: String] = [:]
        for (r, e) in zip(ru, en) { map[String(r)] = String(e) }
        return map
    }()
}

/// FocusTextView as a VimBuffer: edits go through shouldChangeText/didChangeText
/// so undo, highlighting, statistics and the dirty flag keep working.
final class TextViewVimBuffer: VimBuffer {
    private unowned let tv: FocusTextView

    init(_ textView: FocusTextView) { tv = textView }

    var text: NSString { tv.string as NSString }

    var selection: NSRange {
        get { tv.selectedRange() }
        set {
            let len = (tv.string as NSString).length
            let loc = min(max(0, newValue.location), len)
            let safe = NSRange(location: loc, length: min(newValue.length, len - loc))
            tv.setSelectedRange(safe)
            tv.scrollRangeToVisible(safe)
        }
    }

    func replace(_ range: NSRange, with string: String) {
        guard tv.shouldChangeText(in: range, replacementString: string) else { return }
        tv.textStorage?.replaceCharacters(in: range, with: string)
        tv.didChangeText()
    }

    func undo() { tv.undoManager?.undo() }
    func redo() { tv.undoManager?.redo() }

    func beginChange() {
        tv.breakUndoCoalescing()
        tv.undoManager?.beginUndoGrouping()
    }

    func endChange() {
        tv.undoManager?.endUndoGrouping()
        tv.breakUndoCoalescing()
    }
}

// MARK: - Coach bar

/// The bar under the editor in Vim mode: mode, the keys being typed, what the
/// last command did, and a tip.
final class VimCoachView: NSView {

    private let badge = NSTextField(labelWithString: "NORMAL")
    private let keys = NSTextField(labelWithString: "")
    private let message = NSTextField(labelWithString: "")
    private let tip = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        badge.font = .systemFont(ofSize: 10.5, weight: .bold)
        badge.alignment = .center
        badge.textColor = .white
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.drawsBackground = true

        keys.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        message.font = .systemFont(ofSize: 12)
        message.lineBreakMode = .byTruncatingTail
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .secondaryLabelColor
        tip.lineBreakMode = .byTruncatingTail
        for f in [message, tip] { f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }

        let row = NSStackView(views: [badge, keys, message])
        row.spacing = 8
        row.alignment = .centerY
        let column = NSStackView(views: [row, tip])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        column.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 8, right: 14)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 62),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    func apply(background: NSColor, foreground: NSColor) {
        layer?.backgroundColor = background.cgColor
        keys.textColor = foreground
        message.textColor = foreground
    }

    func update(mode: VimMode, pending: String, feedback: VimFeedback?, tip tipText: String?,
                commandPrefix: String, commandLine: String) {
        badge.stringValue = " \(mode.rawValue) "
        badge.backgroundColor = Self.color(for: mode)
        if mode == .commandLine {
            keys.stringValue = commandPrefix + commandLine + "▏"
            message.stringValue = commandPrefix == ":" ? "Return runs it · Esc cancels"
                                                       : "Type the text to find, then Return · Esc cancels"
            message.textColor = .secondaryLabelColor
            tip.stringValue = ""
            return
        }
        keys.stringValue = pending.isEmpty ? (feedback?.keys ?? "") : pending + "…"
        if !pending.isEmpty {
            message.stringValue = "waiting for the rest of the command"
            message.textColor = .secondaryLabelColor
        } else {
            message.stringValue = feedback?.text ?? ""
            message.textColor = feedback?.isError == true ? .systemRed : .labelColor
        }
        tip.stringValue = tipText.map { "Tip: \($0)" } ?? ""
        tip.isHidden = tip.stringValue.isEmpty
    }

    private static func color(for mode: VimMode) -> NSColor {
        switch mode {
        case .normal: return .systemBlue
        case .insert: return .systemGreen
        case .visual, .visualLine: return .systemOrange
        case .commandLine: return .systemPurple
        }
    }
}
