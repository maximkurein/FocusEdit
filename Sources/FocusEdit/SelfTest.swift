import AppKit

/// `FocusEdit --selftest`: headless checks for the syntax engine, completion
/// engine and the text view's writing aids. Exit code 1 if any check fails.
enum SelfTest {

    private static var failures = 0

    static func run() -> Int32 {
        syntax()
        completion()
        editing()
        rtf()
        vim()
        print(failures == 0 ? "\nAll self-tests passed." : "\n\(failures) self-test(s) FAILED.")
        return failures == 0 ? 0 : 1
    }

    private static func check(_ name: String, _ actual: String?, _ expected: String?) {
        if actual == expected {
            print("  PASS  \(name)")
        } else {
            failures += 1
            print("  FAIL  \(name): got \(actual.map { "\"\($0)\"" } ?? "nil"), "
                  + "expected \(expected.map { "\"\($0)\"" } ?? "nil")")
        }
    }

    // MARK: Syntax

    private static func syntax() {
        let md = """
        # Heading one
        Some **bold** and *italic* and `code` here.
        > a blockquote line
        - a list item
        [a link](https://example.com)
        plain paragraph
        """
        let tokens = SyntaxEngine(highlighter: MarkdownHighlighter()).tokens(for: md as NSString)
        print("Markdown tokens: \(tokens.count)")
        for t in tokens {
            print("  \(t.role)  \(NSStringFromRange(t.range))  \"\((md as NSString).substring(with: t.range))\"")
        }
        let fountain = "INT. HOUSE - DAY\nMARY\n(whispering)\nHello there.\nCUT TO:"
        let ft = SyntaxEngine(highlighter: FountainHighlighter()).tokens(for: fountain as NSString)
        print("Fountain tokens: \(ft.count)")
        for t in ft { print("  \(t.role)  \"\((fountain as NSString).substring(with: t.range))\"") }
    }

    // MARK: Completion engine

    private static func completion() {
        print("Completion:")
        let md = CompletionEngine()
        md.kind = .markdown
        md.update(text: "Markdown is plain. Markdown is portable. A marker pen.")
        check("most frequent document word", md.suffix(forPrefix: "Mark", linePrefix: "Mark"), "down")
        check("keeps typed case", md.suffix(forPrefix: "mark", linePrefix: "mark"), "down")
        check("no suggestion for 1 letter", md.suffix(forPrefix: "M", linePrefix: "M"), nil)

        let fn = CompletionEngine()
        fn.kind = .fountain
        fn.update(text: "INT. HOUSE - DAY\n\nMARGARET\nHello.\n\nMARGARET (V.O.)\nAgain.\n")
        check("fountain scene heading", fn.suffix(forPrefix: "IN", linePrefix: "IN"), "T. ")
        check("fountain character cue", fn.suffix(forPrefix: "MAR", linePrefix: "MAR"), "GARET")
    }

    // MARK: Vim mode

    /// In-memory buffer with snapshot undo, for driving VimEngine headlessly.
    private final class TestBuffer: VimBuffer {
        let storage: NSMutableString
        var selection = NSRange(location: 0, length: 0)
        private var undoStack: [(String, NSRange)] = []
        private var redoStack: [(String, NSRange)] = []
        private var depth = 0
        private var snapshotTaken = false
        init(_ s: String) { storage = NSMutableString(string: s) }
        var text: NSString { storage }
        func replace(_ range: NSRange, with string: String) {
            if depth == 0 || !snapshotTaken {
                undoStack.append((storage as String, selection)); redoStack = []; snapshotTaken = true
            }
            storage.replaceCharacters(in: range, with: string)
        }
        func undo() {
            guard let (t, sel) = undoStack.popLast() else { return }
            redoStack.append((storage as String, selection))
            storage.setString(t); selection = sel
        }
        func redo() {
            guard let (t, sel) = redoStack.popLast() else { return }
            undoStack.append((storage as String, selection))
            storage.setString(t); selection = sel
        }
        func beginChange() { if depth == 0 { snapshotTaken = false }; depth += 1 }
        func endChange() { depth -= 1 }
    }

    /// Run `keys` (space-separated tokens; typing inside Insert mode with "+text")
    /// on `text` with the cursor at `cursor`; returns "text|cursor".
    @discardableResult
    private static func vimRun(_ text: String, cursor: Int = 0, _ keys: String,
                               engineOut: ((VimEngine) -> Void)? = nil) -> String {
        let buffer = TestBuffer(text)
        buffer.selection = NSRange(location: cursor, length: 0)
        let vim = VimEngine(buffer: buffer)
        for token in keys.split(separator: " ").map(String.init) {
            if token.hasPrefix("+") {
                // Typing in Insert mode: what the text view would insert itself.
                let typed = String(token.dropFirst()).replacingOccurrences(of: "_", with: " ")
                buffer.replace(buffer.selection, with: typed)
                buffer.selection = NSRange(location: buffer.selection.location + (typed as NSString).length, length: 0)
                vim.noteInserted(typed, deletedBackward: 0)
            } else if token.count > 1, token.range(of: #"^<[A-Za-z-]+>$"#, options: .regularExpression) == nil {
                for ch in token { vim.handle(String(ch)) }  // "dw" → d, w
            } else {
                vim.handle(token)
            }
        }
        engineOut?(vim)
        return "\(buffer.text)|\(buffer.selection.location)"
    }

    private static func vim() {
        print("Vim:")
        check("w moves to the next word", vimRun("hello world", "w"), "hello world|6")
        check("b and e", vimRun("one two three", cursor: 8, "b e"), "one two three|6")
        check("3w with a count", vimRun("a b c d e", "3w"), "a b c d e|6")
        check("$ and 0", vimRun("abc\ndef", "$"), "abc\ndef|2")
        check("dw deletes a word", vimRun("hello world", "dw"), "world|0")
        check("dw on the last word keeps the newline", vimRun("one two\nthree", cursor: 4, "dw"), "one \nthree|3")
        check("d2w deletes two words", vimRun("a b c d", "d2w"), "c d|0")
        check("cw + typing", vimRun("hello world", "cw +bye <Esc>"), "bye world|2")
        check("ciw from inside the word", vimRun("hello world", cursor: 8, "ciw +there <Esc>"), "hello there|10")
        check("dd deletes the line", vimRun("a\nb\nc", cursor: 2, "dd"), "a\nc|2")
        check("2dd deletes two lines", vimRun("a\nb\nc", "2dd"), "c|0")
        check("dd on the last line", vimRun("a\nb", cursor: 2, "dd"), "a|0")
        check("yyp duplicates a line", vimRun("a\nb", "yy p"), "a\na\nb|2")
        check("ddp swaps lines", vimRun("a\nb\nc", "dd p"), "b\na\nc|2")
        check("x and . repeat", vimRun("abc", "x ."), "c|0")
        check("3x", vimRun("abcdef", "3x"), "def|0")
        check("dt, deletes up to the comma", vimRun("foo, bar", "dt,"), ", bar|0")
        check("f then ;", vimRun("a,b,c", "f, ;"), "a,b,c|3")
        check("J joins lines", vimRun("a\n  b", "J"), "a b|1")
        check("u undoes, Ctrl-r redoes", vimRun("hello world", "dw u"), "hello world|0")
        check("Ctrl-r", vimRun("hello world", "dw u <C-r>"), "world|0")
        check("di\" inside quotes", vimRun("say \"hi there\" now", cursor: 6, "di\""), "say \"\" now|5")
        check("da( deletes the group", vimRun("f(a, b) x", cursor: 2, "da("), "f x|1")
        check("ci( changes inside", vimRun("f(a, b)", cursor: 3, "ci( +x <Esc>"), "f(x)|2")
        check(">> indents", vimRun("a\nb", ">>"), "\ta\nb|1")
        check("<< unindents", vimRun("\ta", "<<"), "a|0")
        check("~ toggles case", vimRun("abc", "~"), "Abc|1")
        check("r replaces a character", vimRun("abc", "rX"), "Xbc|0")
        check("A appends at the line end", vimRun("ab\ncd", "A +! <Esc>"), "ab!\ncd|2")
        check("o opens a line + . repeats it", vimRun("a", "o +b <Esc> ."), "a\nb\nb|4")
        check("gg and G", vimRun("a\nb\nc", cursor: 2, "G"), "a\nb\nc|4")
        check("5G goes to a line", vimRun("a\nb\nc\nd\ne", "4G"), "a\nb\nc\nd\ne|6")
        check("} jumps to the blank line", vimRun("a\nb\n\nc", "}"), "a\nb\n\nc|4")
        check("{ jumps back", vimRun("a\n\nb\nc", cursor: 5, "{"), "a\n\nb\nc|2")
        check("v l d deletes the selection", vimRun("abc\ndef", "v l d"), "c\ndef|0")
        check("V d deletes whole lines", vimRun("a\nb\nc", cursor: 2, "V j d"), "a|0")
        check("yiw then P", vimRun("ab cd", cursor: 3, "yiw 0 P"), "cdab cd|1")
        check("/ search", vimRun("hello world wide", "/ w o r <CR>"), "hello world wide|6")
        check("n repeats the search", vimRun("x a x a x", "/ x <CR> n"), "x a x a x|8")

        var action: VimAction?
        vimRun("text", ": w <CR>") { vim in _ = vim }
        let buffer = TestBuffer("text")
        let vim = VimEngine(buffer: buffer)
        vim.onAction = { action = $0 }
        for k in [":", "w", "q", "<CR>"] { vim.handle(k) }
        check(":wq saves and closes", "\(String(describing: action))", "Optional(FocusEdit.VimAction.saveAndClose)")

        vimRun("a b c d", "d2w") { vim in
            check("explains d2w", vim.feedback?.text, "Delete to the start of the next word ×2.")
        }
        vimRun("abcdefgh", "l l l l") { vim in
            check("suggests a count after 4× l", vim.tip, "Pressed l 4 times? 4l does it in one go.")
        }
        vimRun("abc", "q") { vim in
            check("unknown key is an error", vim.feedback?.isError == true ? "error" : "ok", "error")
        }
    }

    // MARK: RTF ↔ Markdown

    private static func rtf() {
        print("RTF:")
        let markdown = """
            # Title
            ## Section
            Some **bold**, *italic*, ***both***, ~~gone~~, a [link](https://example.com) and `code`.
            - one
            - two
                - nested
            1. first
            2. second
            > a quote
            plain line
            """
        do {
            let data = try RTFMarkdown.rtf(fromMarkdown: markdown)
            check("writes RTF", String(decoding: data.prefix(5), as: UTF8.self), "{\\rtf")
            let back = try RTFMarkdown.markdown(fromRTF: data)
            let expected = markdown.components(separatedBy: "\n")
            let actual = back.markdown.components(separatedBy: "\n")
            for (i, line) in expected.enumerated() {
                check("round trip: \(line)", i < actual.count ? actual[i] : nil, line)
            }
            check("round trip loses nothing", back.lostFormatting.joined(separator: ", "), "")

            // Colours and other fonts can't survive as Markdown: the import says so.
            let coloured = NSAttributedString(string: "red words", attributes: [
                .foregroundColor: NSColor.systemRed, .font: NSFont(name: "Helvetica", size: 12)!,
            ])
            let rtfData = try coloured.data(from: NSRange(location: 0, length: coloured.length),
                                            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let imported = try RTFMarkdown.markdown(fromRTF: rtfData)
            check("coloured text is kept", imported.markdown, "red words")
            check("colour loss is reported", imported.lostFormatting.joined(separator: ", "), "colours")
        } catch {
            failures += 1
            print("  FAIL  RTF conversion threw: \(error)")
        }
        check("rtf opens as Markdown", "\(DocumentKind(fileExtension: "RTF"))", "markdown")
    }

    // MARK: Text view writing aids

    private static func makeView(_ text: String, caret: Int? = nil) -> FocusTextView {
        let tv = FocusTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        tv.isRichText = false
        tv.string = text
        tv.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        return tv
    }

    private static func editing() {
        print("Editing:")
        var tv = makeView("- item")
        tv.listContinuationEnabled = true
        tv.insertNewline(nil)
        check("continue bullet list", tv.string, "- item\n- ")
        tv.insertNewline(nil)
        check("Return on empty item ends list", tv.string, "- item\n")

        tv = makeView("9. nine")
        tv.listContinuationEnabled = true
        tv.insertNewline(nil)
        check("continue numbered list", tv.string, "9. nine\n10. ")

        tv = makeView("- [x] done")
        tv.listContinuationEnabled = true
        tv.insertNewline(nil)
        check("continue task list unchecked", tv.string, "- [x] done\n- [ ] ")

        tv = makeView("> quote")
        tv.listContinuationEnabled = true
        tv.insertNewline(nil)
        check("continue blockquote", tv.string, "> quote\n> ")

        tv = makeView("")
        tv.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))
        check("auto-close bracket", tv.string, "()")
        check("caret between brackets", NSStringFromRange(tv.selectedRange()), "{1, 0}")
        tv.insertText(")", replacementRange: NSRange(location: NSNotFound, length: 0))
        check("type over closer", tv.string + "|" + NSStringFromRange(tv.selectedRange()), "()|{2, 0}")

        tv = makeView("()", caret: 1)
        tv.deleteBackward(nil)
        check("backspace removes empty pair", tv.string, "")

        tv = makeView("word")
        tv.setSelectedRange(NSRange(location: 0, length: 4))
        tv.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))
        check("wrap selection in quotes", tv.string, "\"word\"")

        tv = makeView("12")
        tv.insertText("\"", replacementRange: NSRange(location: NSNotFound, length: 0))
        check("quote after a word is not paired", tv.string, "12\"")

        tv = makeView("Mark")
        tv.completionProvider = { prefix, _ in prefix == "Mark" ? "down" : nil }
        tv.updateGhost(afterTyping: true)
        check("ghost suggestion shown", tv.ghostSuffix, "down")
        tv.insertTab(nil)
        check("Tab accepts suggestion", tv.string, "Markdown")

        // Save As from Untitled (.txt) to .md switches the document type in place.
        let editor = EditorViewController()
        editor.loadContent("# Title\n- item", fileExtension: "txt")
        check("untitled is plain text", "\(editor.documentKind)", "plain")
        editor.updateKind(fileExtension: "md")
        check("save as .md turns on Markdown", "\(editor.documentKind)", "markdown")
        check("list continuation follows the type",
              "\(editor.textView.listContinuationEnabled)", "true")
        check("text kept after type switch", editor.plainText, "# Title\n- item")

        // Regression: a document opening with a heading must not turn bold.
        tv = makeView("# Heading\nbody text")
        tv.editorFont = .systemFont(ofSize: 16)
        tv.syntaxEngine = SyntaxEngine(highlighter: MarkdownHighlighter())
        tv.recomputeSyntax()
        tv.recomputeSyntax()
        let bodyFont = tv.textStorage?.attribute(.font, at: 12, effectiveRange: nil) as? NSFont
        let bold = bodyFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? true
        check("body stays regular after a heading", bold ? "bold" : "regular", "regular")

        tv = makeView("Mark")
        tv.completionProvider = { _, _ in "down" }
        tv.updateGhost(afterTyping: true)
        tv.cancelOperation(nil)
        check("Esc dismisses suggestion", tv.ghostSuffix, "")
        tv.insertTab(nil)
        check("Tab without suggestion inserts tab", tv.string, "Mark\t")
    }
}
