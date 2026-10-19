import AppKit

/// `FocusEdit --selftest`: headless checks for the syntax engine, completion
/// engine and the text view's writing aids. Exit code 1 if any check fails.
enum SelfTest {

    private static var failures = 0

    static func run() -> Int32 {
        syntax()
        completion()
        editing()
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
