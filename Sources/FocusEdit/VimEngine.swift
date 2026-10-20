import Foundation

// A teaching Vim mode: the classic "operator + motion" grammar of Vim/NeoVim
// on top of FocusEdit's text view, with an explanation of every command.
//
// Supported (Normal):  h j k l  w b e W B E  0 ^ $  gg G  { }  f F t T ; ,
//                      / ? n N   counts (3w, d2w, 2dd)
// Operators:           d c y > <  (doubled = whole lines: dd cc yy >> <<)
// Text objects:        iw aw  ip ap  i" a" i' a'  i( a( ib ab  i[ a[  i{ a{ iB aB
// Commands:            x X D C Y s S r ~ J p P u Ctrl-r .  i a I A o O  v V
// Command line:        :w :q :wq :x :q! :help :{line}
//
// Positions are UTF-16 offsets into the buffer (NSString / NSTextView).

/// The text the engine edits — the FocusTextView in the app, a string in tests.
protocol VimBuffer: AnyObject {
    var text: NSString { get }
    var selection: NSRange { get set }
    func replace(_ range: NSRange, with string: String)
    func undo()
    func redo()
    /// Group the edits of one command into one undo step.
    func beginChange()
    func endChange()
}

enum VimMode: String {
    case normal = "NORMAL"
    case insert = "INSERT"
    case visual = "VISUAL"
    case visualLine = "VISUAL LINE"
    case commandLine = "COMMAND"
}

enum VimAction: Equatable {
    case save, close, saveAndClose, discardAndClose, help, exitVim
}

/// What the coach shows after a command.
struct VimFeedback: Equatable {
    var keys: String
    var text: String
    var isError = false
}

final class VimEngine {

    let buffer: VimBuffer

    private(set) var mode: VimMode = .normal {
        didSet { if mode != oldValue { onModeChange?(mode) } }
    }
    var onModeChange: ((VimMode) -> Void)?
    var onAction: ((VimAction) -> Void)?
    var onFeedback: ((VimFeedback?, String?) -> Void)?

    private(set) var feedback: VimFeedback?
    private(set) var tip: String?
    /// Keys of the command still being typed ("d2", "f", "ci").
    private(set) var pendingKeys = ""
    /// Text typed after ":" "/" or "?".
    private(set) var commandLine = ""
    private(set) var commandPrefix = ":"

    init(buffer: VimBuffer) {
        self.buffer = buffer
    }

    /// True while a command waits for a character argument (f/t/r targets):
    /// that character is taken literally, not through the keyboard-layout map.
    var wantsLiteralCharacter: Bool {
        switch awaiting {
        case .find?, .replace?: return true
        default: return false
        }
    }

    // MARK: Command state

    private enum Awaiting { case find(Character), replace, textObject(Character), g }

    private var countDigits = ""
    private var operatorKey: String?
    private var operatorCount = 1
    private var awaiting: Awaiting?
    private var register = ""
    private var registerLinewise = false
    private var lastFind: (kind: Character, char: Character)?
    private var lastSearch: (pattern: String, forward: Bool)?
    private var visualAnchor = 0
    private var visualCursor = 0
    private var wantColumn: Int?

    // Dot repeat: the keys of the last change, plus text typed in Insert mode.
    private var commandKeys: [String] = []
    private var changeKeys: [String]?
    private var insertedText = ""
    private var lastChange: (keys: [String], inserted: String)?
    private var replaying = false

    // Coaching
    private var lastSimpleKey = ""
    private var repeatRun = 0
    private var tipIndex = 0

    // MARK: Entry points

    /// Feed one key: a character ("w", "3", "$") or "<Esc>", "<CR>", "<BS>",
    /// "<C-r>", "<Left>", "<Right>", "<Up>", "<Down>". Returns false when the
    /// text view should handle the key itself (typing in Insert mode).
    @discardableResult
    func handle(_ key: String) -> Bool {
        switch mode {
        case .insert:
            return handleInsert(key)
        case .commandLine:
            handleCommandLine(key)
            return true
        case .normal, .visual, .visualLine:
            handleNormal(key)
            return true
        }
    }

    /// Text typed in Insert mode by the text view itself (recorded for ".").
    func noteInserted(_ string: String, deletedBackward: Int) {
        guard mode == .insert, !replaying else { return }
        if deletedBackward > 0, string.isEmpty {
            insertedText = String(insertedText.dropLast(deletedBackward))
        } else {
            insertedText += string
        }
    }

    /// Switching Vim mode on: start in Normal mode with the cursor on a character.
    func reset() {
        mode = .normal
        clearPending()
        let p = buffer.selection.location
        buffer.selection = NSRange(location: clampNormal(p), length: 0)
        report(VimFeedback(keys: "", text: "Vim mode on. NORMAL: letters are commands — press i to type, Esc to come back."),
               tip: "Exit Vim (right) or :novim turns Vim mode off. VIM_GUIDE.md has the lessons.")
    }

    // MARK: Insert mode

    private func handleInsert(_ key: String) -> Bool {
        if key == "<Esc>" {
            mode = .normal
            let p = buffer.selection.location
            let back = p > lineStart(p) ? p - 1 : p
            buffer.selection = NSRange(location: clampNormal(back), length: 0)
            if let keys = changeKeys, !replaying {
                lastChange = (keys, insertedText)
            }
            changeKeys = nil
            if !replaying {
                report(VimFeedback(keys: "Esc", text: "Back to Normal mode. What you typed can be repeated with ."),
                       tip: nil)
            }
            return true
        }
        guard replaying else { return false }
        // Replaying "." types the recorded text itself.
        let sel = buffer.selection
        if key == "<BS>" {
            if sel.location > 0 { buffer.replace(NSRange(location: sel.location - 1, length: 1), with: "") }
        } else {
            buffer.replace(sel, with: key == "<CR>" ? "\n" : key)
        }
        return true
    }

    // MARK: Command line (: / ?)

    private func handleCommandLine(_ key: String) {
        switch key {
        case "<Esc>":
            mode = .normal
            commandLine = ""
            report(VimFeedback(keys: commandPrefix, text: "Command line cancelled."), tip: nil)
        case "<BS>":
            if commandLine.isEmpty { mode = .normal } else { commandLine.removeLast() }
            onFeedback?(feedback, tip)
        case "<CR>":
            let line = commandLine
            commandLine = ""
            mode = .normal
            if commandPrefix == ":" { runCommand(line) } else { search(line, forward: commandPrefix == "/", count: 1, keys: commandPrefix + line) }
        default:
            if key.count == 1 { commandLine += key }
            onFeedback?(feedback, tip)
        }
    }

    private func runCommand(_ line: String) {
        let cmd = line.trimmingCharacters(in: .whitespaces)
        let keys = ":" + cmd
        switch cmd {
        case "w":
            onAction?(.save)
            report(VimFeedback(keys: keys, text: "write — save the file."), tip: nil)
        case "q":
            onAction?(.close)
            report(VimFeedback(keys: keys, text: "quit — close the window (asks first if there are unsaved changes)."), tip: nil)
        case "wq", "x":
            onAction?(.saveAndClose)
            report(VimFeedback(keys: keys, text: "write and quit — save, then close."), tip: nil)
        case "q!":
            onAction?(.discardAndClose)
            report(VimFeedback(keys: keys, text: "quit! — close and throw away unsaved changes."), tip: nil)
        case "novim", "vimoff", "noh vim":
            onAction?(.exitVim)
            report(VimFeedback(keys: keys, text: "Vim mode off — FocusEdit is a normal editor again."), tip: nil)
        case "h", "help":
            onAction?(.help)
            report(VimFeedback(keys: keys, text: "help — the cheat sheet."), tip: nil)
        default:
            if let n = Int(cmd) {
                let target = firstNonBlank(lineStartOf(line: n))
                buffer.selection = NSRange(location: target, length: 0)
                report(VimFeedback(keys: keys, text: "Go to line \(n)."), tip: "\(n)G does the same from Normal mode.")
            } else {
                report(VimFeedback(keys: keys, text: "Not an editor command: \(cmd). Try :w, :q, :wq, :q!, :help or :novim (leave Vim mode).", isError: true), tip: nil)
            }
        }
    }

    // MARK: Normal and Visual mode

    private func handleNormal(_ key: String) {
        commandKeys.append(key)
        pendingKeys += Self.display(key)

        if key == "<Esc>" {
            let wasVisual = mode != .normal
            if wasVisual {
                mode = .normal
                buffer.selection = NSRange(location: clampNormal(visualCursor), length: 0)
            }
            clearPending()
            report(VimFeedback(keys: "Esc", text: wasVisual ? "Visual mode off." : "Cancelled. You are in Normal mode."), tip: nil)
            return
        }

        if let a = awaiting {
            awaiting = nil
            resolve(a, key)
            return
        }

        // Counts: 3w, d2w, 2dd. A lone 0 is a motion (start of line).
        if key.count == 1, let c = key.first, c.isNumber, !(c == "0" && countDigits.isEmpty) {
            countDigits.append(c)
            onFeedback?(feedback, tip)
            return
        }

        let countGiven = !countDigits.isEmpty
        let n = max(1, Int(countDigits) ?? 1)
        countDigits = ""

        // Operators
        if ["d", "c", "y", ">", "<"].contains(key) {
            if mode == .visual || mode == .visualLine {
                applyVisual(key)
                return
            }
            if operatorKey == key {
                linewiseOperator(key, lines: operatorCount * n)
                return
            }
            operatorKey = key
            operatorCount = n
            onFeedback?(feedback, tip)
            return
        }

        switch key {
        case "g":
            countDigits = countGiven ? String(n) : ""
            awaiting = .g
            onFeedback?(feedback, tip)
            return
        case "f", "F", "t", "T":
            countDigits = countGiven ? String(n) : ""
            awaiting = .find(Character(key))
            onFeedback?(feedback, tip)
            return
        case "i", "a":
            // After an operator or in Visual mode i/a start a text object (iw, a(); in Normal they insert.
            guard operatorKey != nil || mode != .normal else { break }
            awaiting = .textObject(Character(key))
            onFeedback?(feedback, tip)
            return
        default:
            break
        }

        if let m = motion(key, from: cursor, count: n, countGiven: countGiven, forOperator: operatorKey != nil) {
            if let op = operatorKey {
                operate(op, motionKey: key, motion: m, count: operatorCount * n)
            } else {
                move(to: m.target, key: key, count: n, countGiven: countGiven)
            }
            return
        }

        if operatorKey != nil {
            fail("\(pendingKeys) — after an operator comes a motion (w, $, j…) or a text object (iw, ip…).")
            return
        }
        command(key, count: n)
    }

    private func resolve(_ a: Awaiting, _ key: String) {
        let countGiven = !countDigits.isEmpty
        let n = max(1, Int(countDigits) ?? 1)
        countDigits = ""
        switch a {
        case .g:
            switch key {
            case "g":
                let m = Motion(target: firstNonBlank(lineStartOf(line: countGiven ? n : 1)), linewise: true)
                if let op = operatorKey { operate(op, motionKey: "gg", motion: m, count: 1) }
                else { move(to: m.target, key: "gg", count: n, countGiven: countGiven) }
            case "e":
                var q = cursor
                for _ in 0..<n { q = wordEndBackward(q, big: false) }
                let m = Motion(target: q, inclusive: true)
                if let op = operatorKey { operate(op, motionKey: "ge", motion: m, count: n) }
                else { move(to: q, key: "ge", count: n, countGiven: countGiven) }
            default:
                fail("g\(Self.display(key)) — FocusEdit knows gg (first line) and ge (end of previous word).")
            }
        case .find(let kind):
            guard key.count == 1, let ch = key.first else { return fail("\(kind) needs a character to look for.") }
            lastFind = (kind, ch)
            guard let target = findChar(kind, ch, from: cursor, count: n) else {
                return fail("No “\(ch)” \(kind == "f" || kind == "t" ? "after" : "before") the cursor on this line.")
            }
            let m = Motion(target: target, inclusive: kind == "f" || kind == "t")
            if let op = operatorKey { operate(op, motionKey: "\(kind)\(ch)", motion: m, count: n) }
            else { move(to: target, key: "\(kind)\(ch)", count: n, countGiven: countGiven) }
        case .replace:
            guard key.count == 1 else { return fail("r needs the character to put there.") }
            replaceChars(with: key, count: n)
        case .textObject(let kind):
            guard let obj = textObject(kind, key, at: cursor) else {
                return fail("\(kind)\(Self.display(key)) — not a text object here. Try iw, ip, i\", i(…")
            }
            if mode == .visual || mode == .visualLine {
                visualAnchor = obj.range.location
                visualCursor = max(obj.range.location, NSMaxRange(obj.range) - 1)
                if obj.linewise { mode = .visualLine }
                updateVisualSelection()
                report(VimFeedback(keys: pendingKeys, text: "Select \(Self.objectName(kind, key))."), tip: "Now d, c, y or > act on the selection.")
                clearPending()
            } else if let op = operatorKey {
                apply(op, range: obj.range, linewise: obj.linewise,
                      keys: pendingKeys, what: Self.objectName(kind, key))
            }
        }
    }

    // MARK: Motions

    private struct Motion {
        var target: Int
        var linewise = false
        var inclusive = false
    }

    private var cursor: Int {
        mode == .visual || mode == .visualLine ? visualCursor : buffer.selection.location
    }

    private func motion(_ key: String, from p: Int, count n: Int, countGiven: Bool, forOperator: Bool) -> Motion? {
        if !["j", "k", "<Up>", "<Down>"].contains(key) { wantColumn = nil }
        switch key {
        case "h", "<Left>":
            return Motion(target: max(lineStart(p), p - n))
        case "l", "<Right>", " ":
            return Motion(target: min(forOperator ? lineEnd(p) : lastCharPos(p), p + n))
        case "j", "<Down>":
            return verticalMotion(p, n)
        case "k", "<Up>":
            return verticalMotion(p, -n)
        case "0":
            return Motion(target: lineStart(p))
        case "^":
            return Motion(target: firstNonBlank(p))
        case "$":
            var q = p
            for _ in 1..<n { q = min(text.length, lineEnd(q) + 1) }
            return Motion(target: forOperator ? lineEnd(q) : lastCharPos(q))
        case "w", "W":
            var q = p
            for _ in 0..<n { q = nextWordStart(q, big: key == "W") }
            // "dw" on the last word of a line stops at the line end, it doesn't join lines.
            if forOperator, q > lineEnd(p), p < lineEnd(p) { q = lineEnd(p) }
            return Motion(target: forOperator ? q : min(q, max(0, text.length - 1)))
        case "e", "E":
            var q = p
            for _ in 0..<n { q = wordEnd(q, big: key == "E") }
            return Motion(target: q, inclusive: true)
        case "b", "B":
            var q = p
            for _ in 0..<n { q = wordBack(q, big: key == "B") }
            return Motion(target: q)
        case "G":
            let line = countGiven ? n : lineCount
            return Motion(target: firstNonBlank(lineStartOf(line: line)), linewise: true)
        case "}":
            var q = p
            for _ in 0..<n { q = paragraphForward(q) }
            return Motion(target: q)
        case "{":
            var q = p
            for _ in 0..<n { q = paragraphBackward(q) }
            return Motion(target: q)
        case ";", ",":
            guard let f = lastFind else { return nil }
            let reversed: Character = ["f": "F", "F": "f", "t": "T", "T": "t"][f.kind] ?? f.kind
            let kind = key == ";" ? f.kind : reversed
            guard let t = findChar(kind, f.char, from: p, count: n) else { return Motion(target: p) }
            return Motion(target: t, inclusive: kind == "f" || kind == "t")
        case "n", "N":
            guard let s = lastSearch else { return nil }
            let forward = key == "n" ? s.forward : !s.forward
            guard let t = find(s.pattern, from: p, forward: forward, count: n) else { return Motion(target: p) }
            return Motion(target: t)
        default:
            return nil
        }
    }

    private func verticalMotion(_ p: Int, _ delta: Int) -> Motion {
        let column = wantColumn ?? (p - lineStart(p))
        wantColumn = column
        let line = max(1, min(lineCount, lineNumber(p) + delta))
        let start = lineStartOf(line: line)
        return Motion(target: min(start + column, lastCharPos(start)), linewise: true)
    }

    private func move(to target: Int, key: String, count: Int, countGiven: Bool) {
        let dest = mode == .normal ? clampNormal(target) : min(target, max(0, text.length - 1))
        if mode == .normal {
            buffer.selection = NSRange(location: dest, length: 0)
        } else {
            visualCursor = dest
            updateVisualSelection()
        }
        let keys = pendingKeys
        clearPending()
        var tipText: String?
        if !countGiven, ["h", "j", "k", "l", "w", "b", "e", "<Left>", "<Right>", "<Up>", "<Down>"].contains(key) {
            repeatRun = (lastSimpleKey == key) ? repeatRun + 1 : 1
            lastSimpleKey = key
            if repeatRun >= 4 {
                let k = Self.arrowAsKey[key] ?? key
                tipText = "Pressed \(k) \(repeatRun) times? \(repeatRun)\(k) does it in one go."
            }
        } else {
            repeatRun = 0
            lastSimpleKey = ""
        }
        if key.hasPrefix("<"), let k = Self.arrowAsKey[key] {
            tipText = tipText ?? "In Vim the arrows are \(k) — keep your fingers on the home row."
        }
        report(VimFeedback(keys: keys, text: "Move " + Self.motionName(key, count: count)), tip: tipText ?? nextTip())
    }

    // MARK: Operators

    private func operate(_ op: String, motionKey key: String, motion m: Motion, count: Int) {
        let p = cursor
        var lo = min(p, m.target)
        var hi = max(p, m.target)
        if m.inclusive { hi = min(text.length, hi + 1) }
        // "cw" changes to the end of the word (like "ce"), as Vim does.
        if op == "c", key == "w" || key == "W", wordClass(p, big: key == "W") != 0 {
            var q = p
            let c = wordClass(p, big: key == "W")
            while q + 1 < text.length, wordClass(q + 1, big: key == "W") == c { q += 1 }
            for _ in 1..<max(1, count) { q = wordEnd(q, big: key == "W") }
            lo = p
            hi = min(text.length, q + 1)
        }
        apply(op, range: NSRange(location: lo, length: hi - lo), linewise: m.linewise,
              keys: pendingKeys, what: Self.motionName(key, count: count))
    }

    private func linewiseOperator(_ op: String, lines n: Int) {
        let start = lineStart(cursor)
        let lastLine = min(lineCount, lineNumber(cursor) + n - 1)
        let endStart = lineStartOf(line: lastLine)
        let range = NSRange(location: start, length: lineEnd(endStart) - start)
        let what = n == 1 ? "the whole line" : "\(n) whole lines"
        apply(op, range: range, linewise: true, keys: pendingKeys, what: what)
    }

    /// Run operator `op` over `range` (expanded to whole lines when `linewise`).
    private func apply(_ op: String, range: NSRange, linewise: Bool, keys: String, what: String) {
        var r = range
        if linewise {
            let start = lineStart(r.location)
            let lastPos = max(r.location, NSMaxRange(r) - 1)
            var end = lineEnd(lastPos)
            if end < text.length { end += 1 } // include the newline
            r = NSRange(location: start, length: end - start)
        }
        let removed = text.substring(with: r)
        let isChange = op != "y"
        if isChange, !replaying { changeKeys = commandKeys }

        buffer.beginChange()
        switch op {
        case "y":
            setRegister(removed, linewise: linewise)
            buffer.selection = NSRange(location: clampNormal(r.location), length: 0)
        case "d":
            setRegister(removed, linewise: linewise)
            var del = r
            // Deleting the last line also takes the newline before it.
            if linewise, NSMaxRange(del) == text.length, del.location > 0, !removed.hasSuffix("\n") {
                del = NSRange(location: del.location - 1, length: del.length + 1)
            }
            buffer.replace(del, with: "")
            let at = min(del.location, max(0, text.length - 1))
            buffer.selection = NSRange(location: linewise ? firstNonBlank(lineStart(at)) : clampNormal(at), length: 0)
        case "c":
            setRegister(removed, linewise: linewise)
            var del = r
            if linewise, removed.hasSuffix("\n") { del.length -= 1 } // keep the (now empty) line
            buffer.replace(del, with: "")
            buffer.selection = NSRange(location: del.location, length: 0)
        case ">", "<":
            shiftLines(r, right: op == ">")
            buffer.selection = NSRange(location: firstNonBlank(lineStart(r.location)), length: 0)
        default:
            break
        }
        buffer.endChange()

        let wasVisual = mode == .visual || mode == .visualLine
        clearPending()
        if op == "c" {
            enterInsert(recording: true)
        } else {
            mode = .normal
            if isChange, !replaying, !wasVisual, let keys = changeKeys { lastChange = (keys, "") }
            if op != "c" { changeKeys = nil }
        }

        let verb = Self.operatorName[op] ?? op
        let text = wasVisual ? "\(verb.capitalizedFirst) the selection." : "\(verb.capitalizedFirst) \(what)."
        let suffix = op == "c" ? " Now type the new text, then Esc." : ""
        report(VimFeedback(keys: keys, text: text + suffix), tip: op == "c" ? nil : nextTip())
    }

    private func setRegister(_ s: String, linewise: Bool) {
        register = linewise && !s.hasSuffix("\n") ? s + "\n" : s
        registerLinewise = linewise
    }

    private func shiftLines(_ r: NSRange, right: Bool) {
        var starts: [Int] = []
        var p = r.location
        while p < NSMaxRange(r) || (starts.isEmpty && p == r.location) {
            starts.append(lineStart(p))
            let e = lineEnd(p)
            if e >= text.length { break }
            p = e + 1
        }
        for s in starts.reversed() {
            if right {
                if lineEnd(s) > s { buffer.replace(NSRange(location: s, length: 0), with: "\t") }
            } else {
                var len = 0
                if s < text.length, text.character(at: s) == 9 { len = 1 }
                else { while len < 4, s + len < text.length, text.character(at: s + len) == 32 { len += 1 } }
                if len > 0 { buffer.replace(NSRange(location: s, length: len), with: "") }
            }
        }
    }

    // MARK: Visual mode

    private func updateVisualSelection() {
        let lo = min(visualAnchor, visualCursor)
        let hi = max(visualAnchor, visualCursor)
        if mode == .visualLine {
            let start = lineStart(lo)
            var end = lineEnd(hi)
            if end < text.length { end += 1 }
            buffer.selection = NSRange(location: start, length: end - start)
        } else {
            buffer.selection = NSRange(location: lo, length: min(text.length, hi + 1) - lo)
        }
    }

    private func applyVisual(_ op: String) {
        let sel = buffer.selection
        apply(op, range: sel, linewise: mode == .visualLine, keys: pendingKeys, what: "the selection")
    }

    // MARK: Simple commands

    private func command(_ key: String, count n: Int) {
        let p = cursor
        let keys = pendingKeys
        let startsChange = ["x", "X", "D", "C", "s", "S", "p", "P", "J", "~", "o", "O", "i", "a", "I", "A"].contains(key)
        if startsChange, mode == .normal, !replaying { changeKeys = commandKeys }

        switch key {
        case "o" where mode != .normal:
            swap(&visualAnchor, &visualCursor)
            updateVisualSelection()
            clearPending()
            report(VimFeedback(keys: keys, text: "Jump to the other end of the selection."), tip: nil)
        case "i", "a", "I", "A", "o", "O":
            insertCommand(key, at: p)
            report(VimFeedback(keys: keys, text: Self.insertName[key] ?? "Insert."), tip: "Type, then Esc to get back to Normal mode.")
        case "v", "V":
            if mode == (key == "v" ? .visual : .visualLine) {
                mode = .normal
                buffer.selection = NSRange(location: clampNormal(visualCursor), length: 0)
                clearPending()
                return report(VimFeedback(keys: keys, text: "Visual mode off."), tip: nil)
            }
            if mode == .normal { visualAnchor = p; visualCursor = p }
            mode = key == "v" ? .visual : .visualLine
            updateVisualSelection()
            clearPending()
            report(VimFeedback(keys: keys, text: key == "v" ? "Visual mode: move to select characters." : "Visual Line mode: move to select whole lines."),
                   tip: "Then d deletes, y copies, c changes, > indents the selection.")
        case "x":
            if mode != .normal { return applyVisual("d") }
            apply("d", range: NSRange(location: p, length: min(n, lineEnd(p) - p)), linewise: false, keys: keys,
                  what: n == 1 ? "the character under the cursor" : "\(n) characters")
        case "X":
            let lo = max(lineStart(p), p - n)
            apply("d", range: NSRange(location: lo, length: p - lo), linewise: false, keys: keys,
                  what: n == 1 ? "the character before the cursor" : "\(n) characters before the cursor")
        case "D":
            apply("d", range: NSRange(location: p, length: lineEnd(p) - p), linewise: false, keys: keys, what: "to the end of the line")
        case "C":
            apply("c", range: NSRange(location: p, length: lineEnd(p) - p), linewise: false, keys: keys, what: "to the end of the line")
        case "s":
            apply("c", range: NSRange(location: p, length: min(n, lineEnd(p) - p)), linewise: false, keys: keys,
                  what: n == 1 ? "the character under the cursor" : "\(n) characters")
        case "S":
            operatorCount = 1
            linewiseOperator("c", lines: n)
        case "Y":
            linewiseOperator("y", lines: n)
        case "r":
            awaiting = .replace
            countDigits = n > 1 ? String(n) : ""
            onFeedback?(feedback, tip)
            return
        case "~":
            toggleCase(count: n)
        case "J":
            joinLines(count: max(2, n))
        case "p", "P":
            put(after: key == "p", count: n)
        case "u":
            buffer.undo()
            buffer.selection = NSRange(location: clampNormal(buffer.selection.location), length: 0)
            clearPending()
            report(VimFeedback(keys: keys, text: "Undo the last change."), tip: "Ctrl-r redoes it.")
        case "<C-r>":
            buffer.redo()
            buffer.selection = NSRange(location: clampNormal(buffer.selection.location), length: 0)
            clearPending()
            report(VimFeedback(keys: keys, text: "Redo — bring the undone change back."), tip: nil)
        case ".":
            repeatLastChange()
        case ":", "/", "?":
            if mode != .normal {
                mode = .normal
                buffer.selection = NSRange(location: clampNormal(visualCursor), length: 0)
            }
            commandPrefix = key
            commandLine = ""
            mode = .commandLine
            clearPending()
            report(VimFeedback(keys: key, text: key == ":" ? "Command line: w save, q quit, wq both, q! quit without saving."
                               : "Search \(key == "/" ? "forward" : "backward"): type the text, then Return. n repeats."), tip: nil)
        default:
            if key == "<CR>" || key == "<BS>" {
                return command(key == "<CR>" ? "j" : "h", count: n)
            }
            fail("\(Self.display(key)) — not a Vim command FocusEdit knows. :help lists them.")
        }
    }

    private func insertCommand(_ key: String, at p: Int) {
        buffer.beginChange()
        switch key {
        case "i":
            buffer.selection = NSRange(location: p, length: 0)
        case "a":
            buffer.selection = NSRange(location: lineEnd(p) > lineStart(p) ? min(p + 1, lineEnd(p)) : p, length: 0)
        case "I":
            buffer.selection = NSRange(location: firstNonBlank(p), length: 0)
        case "A":
            buffer.selection = NSRange(location: lineEnd(p), length: 0)
        case "o":
            let e = lineEnd(p)
            buffer.replace(NSRange(location: e, length: 0), with: "\n")
            buffer.selection = NSRange(location: e + 1, length: 0)
        case "O":
            let s = lineStart(p)
            buffer.replace(NSRange(location: s, length: 0), with: "\n")
            buffer.selection = NSRange(location: s, length: 0)
        default:
            break
        }
        buffer.endChange()
        clearPending()
        enterInsert(recording: true)
    }

    private func enterInsert(recording: Bool) {
        insertedText = ""
        mode = .insert
    }

    private func replaceChars(with ch: String, count n: Int) {
        let p = cursor
        guard p + n <= lineEnd(p) else { return fail("r\(ch) — not enough characters on the line.") }
        if !replaying { changeKeys = commandKeys }
        let keys = pendingKeys
        buffer.beginChange()
        buffer.replace(NSRange(location: p, length: n), with: String(repeating: ch, count: n))
        buffer.endChange()
        buffer.selection = NSRange(location: p + n - 1, length: 0)
        finishChange()
        report(VimFeedback(keys: keys, text: "Replace \(n == 1 ? "the character" : "\(n) characters") with “\(ch)” — stays in Normal mode."), tip: nextTip())
    }

    private func toggleCase(count n: Int) {
        let keys = pendingKeys
        if mode != .normal {
            let sel = buffer.selection
            buffer.beginChange()
            buffer.replace(sel, with: Self.toggled(text.substring(with: sel)))
            buffer.endChange()
            mode = .normal
            buffer.selection = NSRange(location: clampNormal(sel.location), length: 0)
            clearPending()
            return report(VimFeedback(keys: keys, text: "Switch upper/lower case of the selection."), tip: nil)
        }
        let p = cursor
        let len = min(n, lineEnd(p) - p)
        guard len > 0 else { return clearPending() }
        let r = NSRange(location: p, length: len)
        buffer.beginChange()
        buffer.replace(r, with: Self.toggled(text.substring(with: r)))
        buffer.endChange()
        buffer.selection = NSRange(location: clampNormal(p + len), length: 0)
        finishChange()
        report(VimFeedback(keys: keys, text: "Switch upper/lower case and move on."), tip: nextTip())
    }

    private func joinLines(count n: Int) {
        let keys = pendingKeys
        buffer.beginChange()
        var joinAt = cursor
        for _ in 1..<n {
            let e = lineEnd(joinAt)
            guard e < text.length else { break }
            var k = e + 1
            while k < text.length, [32, 9].contains(text.character(at: k)) { k += 1 }
            let atEnd = k >= text.length || text.character(at: k) == 10
            buffer.replace(NSRange(location: e, length: k - e), with: atEnd ? "" : " ")
            joinAt = e
        }
        buffer.endChange()
        buffer.selection = NSRange(location: clampNormal(joinAt), length: 0)
        finishChange()
        report(VimFeedback(keys: keys, text: "Join the next line onto this one."), tip: nextTip())
    }

    private func put(after: Bool, count n: Int) {
        let keys = pendingKeys
        guard !register.isEmpty else {
            clearPending()
            return fail("Nothing to put yet — copy with y or delete with d first.")
        }
        let p = cursor
        let chunk = String(repeating: register, count: n)
        buffer.beginChange()
        if registerLinewise {
            var at = after ? lineEnd(p) : lineStart(p)
            var insert = chunk
            if after {
                if at < text.length { at += 1 } else { insert = "\n" + String(chunk.dropLast()) }
            }
            buffer.replace(NSRange(location: at, length: 0), with: insert)
            let lineAt = insert.hasPrefix("\n") ? at + 1 : at
            buffer.selection = NSRange(location: firstNonBlank(lineAt), length: 0)
        } else {
            let at = after && lineEnd(p) > lineStart(p) ? min(p + 1, lineEnd(p)) : p
            buffer.replace(NSRange(location: at, length: 0), with: chunk)
            buffer.selection = NSRange(location: clampNormal(at + (chunk as NSString).length - 1), length: 0)
        }
        buffer.endChange()
        finishChange()
        let what = registerLinewise ? (after ? "the copied line(s) below this one" : "the copied line(s) above this one")
                                    : (after ? "the copied text after the cursor" : "the copied text before the cursor")
        report(VimFeedback(keys: keys, text: "Put \(what)."), tip: "dd then p moves a line down; yy then p duplicates it.")
    }

    private func repeatLastChange() {
        guard let change = lastChange else {
            clearPending()
            return fail(". repeats the last change — make one first (x, dw, ciw…).")
        }
        let shown = change.keys.map(Self.display).joined()
        replaying = true
        clearPending()
        for k in change.keys { handle(k) }
        if mode == .insert {
            for ch in change.inserted { handle(ch == "\n" ? "<CR>" : String(ch)) }
            handle("<Esc>")
        }
        replaying = false
        report(VimFeedback(keys: ".", text: "Repeat the last change (\(shown)\(change.inserted.isEmpty ? "" : " + typing “\(change.inserted)”"))."),
               tip: "Combine with motions: n . n . — find the next match, repeat the fix.")
    }

    private func finishChange() {
        if !replaying, let keys = changeKeys { lastChange = (keys, "") }
        changeKeys = nil
        clearPending()
    }

    private func search(_ pattern: String, forward: Bool, count: Int, keys: String) {
        guard !pattern.isEmpty else { return }
        lastSearch = (pattern, forward)
        guard let t = find(pattern, from: buffer.selection.location, forward: forward, count: count) else {
            return report(VimFeedback(keys: keys, text: "Pattern not found: \(pattern)", isError: true), tip: nil)
        }
        buffer.selection = NSRange(location: t, length: 0)
        report(VimFeedback(keys: keys, text: "Jump to “\(pattern)”."), tip: "n finds the next one, N the previous.")
    }

    private func fail(_ message: String) {
        clearPending()
        report(VimFeedback(keys: "", text: message, isError: true), tip: nil)
    }

    private func clearPending() {
        countDigits = ""
        operatorKey = nil
        operatorCount = 1
        awaiting = nil
        pendingKeys = ""
        commandKeys = []
    }

    private func report(_ fb: VimFeedback, tip: String?) {
        if !replaying {
            feedback = fb
            self.tip = tip
        }
        onFeedback?(feedback, self.tip)
    }

    // MARK: Text helpers

    private var text: NSString { buffer.text }
    private var lineCount: Int {
        var n = 1
        for i in 0..<text.length where text.character(at: i) == 10 { n += 1 }
        return n
    }

    private func lineStart(_ p: Int) -> Int {
        text.lineRange(for: NSRange(location: min(max(0, p), text.length), length: 0)).location
    }

    /// Index of the line's "\n" (or the end of the text).
    private func lineEnd(_ p: Int) -> Int {
        let r = text.lineRange(for: NSRange(location: min(max(0, p), text.length), length: 0))
        var e = NSMaxRange(r)
        if e > r.location, text.character(at: e - 1) == 10 { e -= 1 }
        return e
    }

    private func lastCharPos(_ p: Int) -> Int {
        let s = lineStart(p), e = lineEnd(p)
        return e > s ? e - 1 : s
    }

    private func clampNormal(_ p: Int) -> Int {
        min(max(0, p), lastCharPos(min(max(0, p), text.length)))
    }

    private func firstNonBlank(_ p: Int) -> Int {
        var i = lineStart(p)
        let e = lineEnd(p)
        while i < e, [32, 9].contains(text.character(at: i)) { i += 1 }
        return min(i, lastCharPos(p))
    }

    private func lineNumber(_ p: Int) -> Int {
        var n = 1
        for i in 0..<min(max(0, p), text.length) where text.character(at: i) == 10 { n += 1 }
        return n
    }

    private func lineStartOf(line: Int) -> Int {
        var current = 1
        if line <= 1 { return 0 }
        for i in 0..<text.length where text.character(at: i) == 10 {
            current += 1
            if current == line { return i + 1 }
        }
        return lineStart(text.length)
    }

    /// 0 = blank, 1 = word characters (letters, digits, _), 2 = punctuation.
    /// For WORD motions (W B E) everything that isn't blank is one class.
    private func wordClass(_ i: Int, big: Bool) -> Int {
        guard i >= 0, i < text.length else { return 0 }
        let c = text.character(at: i)
        if c == 10 || c == 32 || c == 9 || c == 13 { return 0 }
        if big { return 1 }
        guard let u = UnicodeScalar(c) else { return 1 } // surrogate halves: treat as letters
        return CharacterSet.alphanumerics.contains(u) || c == 95 ? 1 : 2
    }

    private func isEmptyLine(at i: Int) -> Bool {
        i < text.length && text.character(at: i) == 10 && (i == 0 || text.character(at: i - 1) == 10)
    }

    private func nextWordStart(_ p: Int, big: Bool) -> Int {
        var i = p
        let c0 = wordClass(i, big: big)
        if c0 != 0 { while i < text.length, wordClass(i, big: big) == c0 { i += 1 } }
        while i < text.length, wordClass(i, big: big) == 0 {
            if i > p, isEmptyLine(at: i) { return i } // an empty line is a word of its own
            i += 1
        }
        return min(i, text.length)
    }

    private func wordEnd(_ p: Int, big: Bool) -> Int {
        var i = p + 1
        while i < text.length, wordClass(i, big: big) == 0 { i += 1 }
        guard i < text.length else { return max(0, text.length - 1) }
        let c = wordClass(i, big: big)
        while i + 1 < text.length, wordClass(i + 1, big: big) == c { i += 1 }
        return i
    }

    private func wordEndBackward(_ p: Int, big: Bool) -> Int {
        var i = p
        let c0 = wordClass(i, big: big)
        while i > 0, wordClass(i, big: big) == c0, c0 != 0 { i -= 1 }
        while i > 0, wordClass(i, big: big) == 0 { i -= 1 }
        return max(0, i)
    }

    private func wordBack(_ p: Int, big: Bool) -> Int {
        var i = p - 1
        while i > 0, wordClass(i, big: big) == 0 { i -= 1 }
        guard i > 0 else { return 0 }
        let c = wordClass(i, big: big)
        while i > 0, wordClass(i - 1, big: big) == c { i -= 1 }
        return i
    }

    private func nextLineStart(_ lineStartPos: Int) -> Int? {
        let e = lineEnd(lineStartPos)
        return e < text.length ? e + 1 : nil
    }

    private func isBlankLine(_ lineStartPos: Int) -> Bool { lineEnd(lineStartPos) == lineStartPos }

    /// "}": skip blank lines, then the paragraph, and land on the next blank line.
    private func paragraphForward(_ p: Int) -> Int {
        var line = lineStart(p)
        while isBlankLine(line), let next = nextLineStart(line) { line = next }
        while !isBlankLine(line) {
            guard let next = nextLineStart(line) else { return lastCharPos(line) }
            line = next
        }
        return line
    }

    /// "{": the same, backwards.
    private func paragraphBackward(_ p: Int) -> Int {
        var line = lineStart(p)
        while isBlankLine(line), line > 0 { line = lineStart(line - 1) }
        while !isBlankLine(line) {
            guard line > 0 else { return 0 }
            line = lineStart(line - 1)
        }
        return line
    }

    private func findChar(_ kind: Character, _ ch: Character, from p: Int, count n: Int) -> Int? {
        let target = (String(ch) as NSString).character(at: 0)
        var found = 0
        if kind == "f" || kind == "t" {
            var i = p + 1 + (kind == "t" ? 1 : 0)
            while i < lineEnd(p) {
                if text.character(at: i) == target {
                    found += 1
                    if found == n { return kind == "f" ? i : i - 1 }
                }
                i += 1
            }
        } else {
            var i = p - 1 - (kind == "T" ? 1 : 0)
            while i >= lineStart(p) {
                if text.character(at: i) == target {
                    found += 1
                    if found == n { return kind == "F" ? i : i + 1 }
                }
                i -= 1
            }
        }
        return nil
    }

    /// Literal search with smart case (case-insensitive unless the pattern has capitals), wrapping around.
    private func find(_ pattern: String, from p: Int, forward: Bool, count n: Int) -> Int? {
        var options: NSString.CompareOptions = pattern == pattern.lowercased() ? [.caseInsensitive] : []
        if !forward { options.insert(.backwards) }
        var pos = p
        for _ in 0..<n {
            let len = text.length
            let first = forward ? NSRange(location: min(pos + 1, len), length: len - min(pos + 1, len))
                                : NSRange(location: 0, length: pos)
            var r = text.range(of: pattern, options: options, range: first)
            if r.location == NSNotFound { r = text.range(of: pattern, options: options) } // wrap
            guard r.location != NSNotFound else { return nil }
            pos = r.location
        }
        return pos
    }

    // MARK: Text objects

    private func textObject(_ kind: Character, _ key: String, at p: Int) -> (range: NSRange, linewise: Bool)? {
        guard text.length > 0, p < text.length else { return nil }
        let inner = kind == "i"
        switch key {
        case "w", "W":
            let big = key == "W"
            let c = wordClass(p, big: big)
            var lo = p, hi = p
            while lo > lineStart(p), wordClass(lo - 1, big: big) == c { lo -= 1 }
            while hi + 1 < lineEnd(p), wordClass(hi + 1, big: big) == c { hi += 1 }
            hi += 1
            if !inner {
                var h = hi
                while h < lineEnd(p), [32, 9].contains(text.character(at: h)) { h += 1 }
                if h > hi { hi = h } else { while lo > lineStart(p), [32, 9].contains(text.character(at: lo - 1)) { lo -= 1 } }
            }
            return (NSRange(location: lo, length: hi - lo), false)
        case "p":
            let blank = lineEnd(p) == lineStart(p)
            var first = lineStart(p), last = lineStart(p)
            while first > 0 {
                let prev = lineStart(first - 1)
                if (lineEnd(prev) == prev) != blank { break }
                first = prev
            }
            while lineEnd(last) < text.length {
                let next = lineEnd(last) + 1
                if (lineEnd(next) == next) != blank { break }
                last = next
            }
            if !inner {
                while lineEnd(last) < text.length {
                    let next = lineEnd(last) + 1
                    guard lineEnd(next) == next else { break }
                    last = next
                }
            }
            return (NSRange(location: first, length: lineEnd(last) - first), true)
        case "\"", "'", "`":
            let q = (key as NSString).character(at: 0)
            let s = lineStart(p), e = lineEnd(p)
            var open: Int?
            var i = p
            while i >= s { if text.character(at: i) == q { open = i; break }; i -= 1 }
            guard let o = open else { return nil }
            var close: Int?
            i = (o == p) ? p + 1 : p
            while i < e { if text.character(at: i) == q, i != o { close = i; break }; i += 1 }
            guard let c = close else { return nil }
            return inner ? (NSRange(location: o + 1, length: c - o - 1), false)
                         : (NSRange(location: o, length: c - o + 1), false)
        case "(", ")", "b", "[", "]", "{", "}", "B":
            let pairs: [String: (unichar, unichar)] = ["(": (40, 41), ")": (40, 41), "b": (40, 41),
                                                        "[": (91, 93), "]": (91, 93),
                                                        "{": (123, 125), "}": (123, 125), "B": (123, 125)]
            guard let (openCh, closeCh) = pairs[key] else { return nil }
            var depth = 0
            var o = p
            if p < text.length, text.character(at: p) == closeCh { depth = -1 }
            while o >= 0 {
                let c = text.character(at: min(o, text.length - 1))
                if c == closeCh, o != p { depth += 1 }
                if c == openCh { if depth == 0 { break }; depth -= 1 }
                o -= 1
            }
            guard o >= 0 else { return nil }
            depth = 0
            var c = o + 1
            while c < text.length {
                let ch = text.character(at: c)
                if ch == openCh { depth += 1 }
                if ch == closeCh { if depth == 0 { break }; depth -= 1 }
                c += 1
            }
            guard c < text.length else { return nil }
            return inner ? (NSRange(location: o + 1, length: c - o - 1), false)
                         : (NSRange(location: o, length: c - o + 1), false)
        default:
            return nil
        }
    }

    // MARK: Explanations

    private static let operatorName: [String: String] = [
        "d": "delete", "c": "change (delete, then type)", "y": "copy (yank)", ">": "indent", "<": "unindent",
    ]

    private static let insertName: [String: String] = [
        "i": "Insert before the cursor.", "a": "Append after the cursor.",
        "I": "Insert at the start of the line.", "A": "Append at the end of the line.",
        "o": "Open a new line below and insert.", "O": "Open a new line above and insert.",
    ]

    private static let arrowAsKey = ["<Left>": "h", "<Right>": "l", "<Up>": "k", "<Down>": "j"]

    static func motionName(_ key: String, count n: Int) -> String {
        let times = n > 1 ? " ×\(n)" : ""
        let base: String
        switch key {
        case "h", "<Left>": base = "one character left"
        case "l", "<Right>", " ": base = "one character right"
        case "j", "<Down>": base = "one line down"
        case "k", "<Up>": base = "one line up"
        case "w": base = "to the start of the next word"
        case "W": base = "to the start of the next WORD (anything between spaces)"
        case "e": base = "to the end of the word"
        case "E": base = "to the end of the WORD"
        case "b": base = "back to the start of the word"
        case "B": base = "back to the start of the WORD"
        case "ge": base = "back to the end of the previous word"
        case "0": base = "to the very start of the line"
        case "^": base = "to the first non-blank character of the line"
        case "$": base = "to the end of the line"
        case "gg": return n > 1 ? "to line \(n)" : "to the first line"
        case "G": return n > 1 ? "to line \(n)" : "to the last line"
        case "}": base = "to the next blank line (end of paragraph)"
        case "{": base = "to the previous blank line (start of paragraph)"
        case ";": base = "to the next match of the last f/t"
        case ",": base = "to the previous match of the last f/t"
        case "n": base = "to the next search match"
        case "N": base = "to the previous search match"
        default:
            if key.count == 2, let k = key.first, let c = key.last {
                switch k {
                case "f": base = "to the next “\(c)” on the line"
                case "F": base = "back to the previous “\(c)”"
                case "t": base = "up to (just before) the next “\(c)”"
                case "T": base = "back to just after the previous “\(c)”"
                default: base = key
                }
            } else {
                base = key
            }
        }
        return base + times
    }

    static func objectName(_ kind: Character, _ key: String) -> String {
        let inside = kind == "i"
        switch key {
        case "w": return inside ? "the word under the cursor" : "the word and the space after it"
        case "W": return inside ? "the WORD under the cursor" : "the WORD and the space after it"
        case "p": return inside ? "the paragraph" : "the paragraph and the blank lines after it"
        case "\"": return inside ? "the text inside the double quotes" : "the double-quoted text, quotes included"
        case "'": return inside ? "the text inside the single quotes" : "the single-quoted text, quotes included"
        case "(", ")", "b": return inside ? "the text inside the parentheses" : "the parentheses and what's inside"
        case "[", "]": return inside ? "the text inside the brackets" : "the brackets and what's inside"
        case "{", "}", "B": return inside ? "the text inside the braces" : "the braces and what's inside"
        default: return "\(kind)\(key)"
        }
    }

    static func display(_ key: String) -> String {
        switch key {
        case "<Esc>": return "Esc"
        case "<CR>": return "⏎"
        case "<BS>": return "⌫"
        case "<C-r>": return "Ctrl-r"
        case "<Left>": return "←"
        case "<Right>": return "→"
        case "<Up>": return "↑"
        case "<Down>": return "↓"
        case " ": return "␣"
        default: return key
        }
    }

    private static func toggled(_ s: String) -> String {
        String(s.map { ch -> String in
            let str = String(ch)
            return str == str.uppercased() ? str.lowercased() : str.uppercased()
        }.joined())
    }

    private static let tips = [
        "ciw changes the word under the cursor — from anywhere inside it.",
        "dd deletes a line, p puts it below: dd p swaps two lines.",
        ". repeats your last change. Fix one place, then move and press .",
        "f then a letter jumps to it on this line; ; jumps to the next one.",
        "A appends at the end of the line, I inserts at its start.",
        "Counts work everywhere: 3j, d2w, 5x.",
        "di\" deletes inside quotes, da( deletes a whole (…) group.",
        "u undoes, Ctrl-r redoes.",
        "* Grammar: operator + motion. d$ = delete to line end, y} = copy to paragraph end.",
        "o opens a new line below, O above — no need to go to the line end first.",
        "V then j j selects whole lines; > indents them.",
        ":w saves, :wq saves and closes, :q! closes without saving.",
    ]

    private func nextTip() -> String {
        tipIndex = (tipIndex + 1) % Self.tips.count
        return Self.tips[tipIndex]
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
