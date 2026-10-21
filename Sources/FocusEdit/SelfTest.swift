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
        markdown()
        palette()
        newFile()
        focusUnit()
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
        check("i inserts before the cursor", vimRun("ab", cursor: 1, "i +x <Esc>"), "axb|1")
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
        for k in [":", "n", "o", "v", "i", "m", "<CR>"] { vim.handle(k) }
        check(":novim leaves Vim mode", "\(String(describing: action))", "Optional(FocusEdit.VimAction.exitVim)")

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

    // MARK: Focus unit (Paragraph focus)

    // MARK: Markdown preview (cases from windows/tests/markdown-html.test.ts)

    private static func markdown() {
        print("Markdown:")
        func html(_ md: String) -> String {
            MarkdownToHTML.render(md).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func has(_ name: String, _ md: String, _ part: String, _ yes: Bool = true) {
            check(name, html(md).contains(part) ? "yes" : "no", yes ? "yes" : "no")
        }
        check("heading and paragraph", html("# Title\n\nbody text"), "<h1>Title</h1>\n<p>body text</p>")
        check("setext heading", html("Setext\n======"), "<h1>Setext</h1>")
        check("setext h2 over a rule", html("Two\n---"), "<h2>Two</h2>")
        check("inline marks", html("**b** *i* ~~s~~ `c<d>`"),
              "<p><strong>b</strong> <em>i</em> <del>s</del> <code>c&lt;d&gt;</code></p>")
        has("raw HTML is text", "<script>alert(1)</script>", "<script>", false)
        has("inline HTML is text", "a <b>x</b> b", "&lt;b&gt;x&lt;/b&gt;")
        check("web link", html("[x](https://example.com/a?b=1&c=2)"),
              "<p><a href=\"https://example.com/a?b=1&amp;c=2\">x</a></p>")
        check("javascript link is text", html("[x](javascript:alert(1))"), "<p>x</p>")
        check("file link is text", html("[x](file:///C:/secret.txt)"), "<p>x</p>")
        has("quote can't end the attribute", "[x](\" onmouseover=\"alert(1))", "onmouseover=\"", false)
        has("reference link", "[see][r]\n\n[r]: https://ref.example.com", "<a href=\"https://ref.example.com\">see</a>")
        has("shortcut reference", "[r]\n\n[R]: https://ref.example.com", "<a href=\"https://ref.example.com\">r</a>")
        check("bare URL", html("go to https://auto.example.com now."),
              "<p>go to <a href=\"https://auto.example.com\">https://auto.example.com</a> now.</p>")
        check("link text that is a URL", html("[https://a.b](https://a.b)"),
              "<p><a href=\"https://a.b\">https://a.b</a></p>")
        has("bullet list", "- a\n- b", "<ul>")
        check("tight list", html("- a\n- b"), "<ul>\n<li>a</li>\n<li>b</li>\n</ul>")
        has("loose list", "- a\n\n- b", "<li><p>a</p></li>")
        has("numbered start", "3. x\n4. y", "<ol start=\"3\">")
        check("nested list", html("- a\n  - b\n- c"),
              "<ul>\n<li>a\n<ul>\n<li>b</li>\n</ul></li>\n<li>c</li>\n</ul>")
        has("task done", "- [x] done\n- [ ] todo", "<input type=\"checkbox\" disabled checked> done")
        has("task open", "- [x] done\n- [ ] todo", "<input type=\"checkbox\" disabled> todo")
        has("quote", "> quoted", "<blockquote>")
        check("lazy quote line", html("> a\nb"), "<blockquote>\n<p>a\nb</p>\n</blockquote>")
        check("rule", html("---"), "<hr>")
        check("fenced code with language", html("```ts\nconst a = 1 < 2;\n```"),
              "<pre><code class=\"language-ts\">const a = 1 &lt; 2;</code></pre>")
        check("tilde fence keeps backticks", html("~~~\n```\n~~~"), "<pre><code>```</code></pre>")
        check("indented code", html("    indented"), "<pre><code>indented</code></pre>")
        let table = html("| a | b |\n|:--|--:|\n| 1 | 2 |")
        check("table header", table.contains("<th style=\"text-align:left\">a</th><th style=\"text-align:right\">b</th>") ? "yes" : "no", "yes")
        check("table cell", table.contains("<td style=\"text-align:left\">1</td>") ? "yes" : "no", "yes")
        has("hard break", "one  \ntwo", "<br>")
        check("escaped marks", html("\\*not em\\*"), "<p>*not em*</p>")
        check("image", html("![alt text](pic.png)"), "<p><img alt=\"alt text\" src=\"pic.png\"></p>")
        check("unsafe image is its alt text", html("![alt](javascript:x)"), "<p>alt</p>")
        check("empty document", html(""), "")
        check("view cycle", "\(ViewMode.edit.next) \(ViewMode.split.next) \(ViewMode.preview.next)", "split preview edit")
        let five = "a\nb\nc\nd\ne"
        check("caret line → ratio", String(ViewMode.ratio(forCaret: 4, in: five)), "0.5")
        check("ratio → line start", String(ViewMode.lineStart(forRatio: 0.5, in: five)), "4")
        check("ratio 1 → last line", String(ViewMode.lineStart(forRatio: 1, in: five)), "8")
        check("one-line text", String(ViewMode.ratio(forCaret: 3, in: "abc")), "0.0")
        check("underscores inside words", html("snake_case_name"), "<p>snake_case_name</p>")
        check("emphasis inside strong", html("**a *b* c**"), "<p><strong>a <em>b</em> c</strong></p>")
        check("marks inside code stay", html("`**x**`"), "<p><code>**x**</code></p>")
        check("list after a paragraph", html("text\n- a"), "<p>text</p>\n<ul>\n<li>a</li>\n</ul>")
        check("number in a sentence is not a list", html("year\n2024. was"), "<p>year\n2024. was</p>")
        check("list ends at another marker", html("- a\n+ b"), "<ul>\n<li>a</li>\n</ul>\n<ul>\n<li>b</li>\n</ul>")
        check("code in a list item", html("1. a\n\n   ```\n   x\n   ```"),
              "<ol>\n<li><p>a</p>\n<pre><code>x</code></pre></li>\n</ol>")
        check("mail link", html("[m](mailto:a@b.c)"), "<p><a href=\"mailto:a@b.c\">m</a></p>")
        let big = String(repeating: "## Part\n\nSome **bold** and *italic* text with a [link](https://a.b) and `code`.\n- one\n- two\n\n", count: 2000)
        let started = Date()
        _ = MarkdownToHTML.render(big)
        let seconds = Date().timeIntervalSince(started)
        print("  (\(big.utf8.count / 1024) KB rendered in \(String(format: "%.2f", seconds)) s)")
        check("large document renders quickly", seconds < 1.5 ? "yes" : "no", "yes")
    }

    // MARK: Command palette (cases from windows/tests/palette-session-links.test.ts)

    private static func palette() {
        print("Palette:")
        func cmd(_ title: String, _ keywords: String = "") -> PaletteCommand {
            PaletteCommand(title: title, keywords: keywords) {}
        }
        let all = [cmd("Save"), cmd("Save As…"), cmd("Theme: Dark", "night"), cmd("Theme: Light", "day"),
                   cmd("Theme: Sepia"), cmd("View: Preview"), cmd("Export as HTML…")]
        func titles(_ q: String) -> String { PaletteSearch.filter(all, q).map(\.title).joined(separator: " | ") }
        let everything = all.map(\.title).joined(separator: " | ")
        check("empty query lists all in order", titles(""), everything)
        check("blank query lists all", titles("   "), everything)
        check("letters anywhere, any case", titles("sepia"), "Theme: Sepia")
        check("upper case query", titles("HTML"), "Export as HTML…")
        check("every word must match", titles("theme dark"), "Theme: Dark")
        check("an unknown word matches nothing", titles("theme zebra"), "")
        check("finds by keyword", titles("night"), "Theme: Dark")
        check("start of a title first", PaletteSearch.filter(all, "sa").first?.title, "Save")
        check("save, then save as", titles("save"), "Save | Save As…")
        check("letters in order", titles("thdk"), "Theme: Dark")
        check("no match is nil", PaletteSearch.matchScore("zzz", "Save").map(String.init), nil)
        check("shortcut text", PaletteSearch.format("p", [.command, .shift]), "⇧⌘P")
        check("upper-case key means shift", PaletteSearch.format("N", [.command]), "⇧⌘N")
        check("option key", PaletteSearch.format("p", [.command, .option]), "⌥⌘P")

        let editor = EditorViewController()
        editor.loadContent("one\ntwo\nthree", fileExtension: "md")
        editor.goToLine(2)
        check("go to line 2", String(editor.textView.selectedRange().location), "4")
        editor.goToLine(99)
        check("go to a line past the end", String(editor.textView.selectedRange().location), "8")
    }

    private static func focusUnit() {
        print("Focus unit:")
        let prose = "First line\nsecond line\n\nNext paragraph\nwith two lines" as NSString
        func unit(_ text: NSString, at location: Int) -> String {
            text.substring(with: FocusUnit.range(in: text, around: location))
        }
        check("paragraph covers its lines", unit(prose, at: 3), "First line\nsecond line\n")
        check("second line is the same paragraph", unit(prose, at: 15), "First line\nsecond line\n")
        check("next paragraph", unit(prose, at: 30), "Next paragraph\nwith two lines")
        let heading = "# Title\nText under it\nmore" as NSString
        check("heading is its own block", unit(heading, at: 2), "# Title\n")
        check("text under a heading", unit(heading, at: 12), "Text under it\nmore")
        let list = "- one\n- two\n  still two\n- three" as NSString
        check("first list item", unit(list, at: 1), "- one\n")
        check("list item with continuation", unit(list, at: 8), "- two\n  still two\n")
        check("last list item", unit(list, at: 26), "- three")
        check("empty text", "\(FocusUnit.range(in: "" as NSString, around: 0))", "{0, 0}")
    }

    // MARK: New File…

    private static func newFile() {
        print("New File:")
        check("file name gets the extension", NewFile.fileName("notes", format: .md), "notes.md")
        check("typed extension is not doubled", NewFile.fileName("notes.txt", format: .md), "notes.md")
        check("forbidden characters go", NewFile.cleanName("a<b>c:d/e"), "a b c d e")
        check("empty name becomes Untitled", NewFile.cleanName("  . "), "Untitled")
        check("Russian name is kept", NewFile.cleanName(" Заметка про дом. "), "Заметка про дом")
        check("default name has the date", NewFile.defaultName(.note, date: "2026-10-21"), "Note 2026-10-21")
        check("blank is empty", NewFile.startingText(.blank, format: .md, title: "x", date: "d"), "")
        check("note is Markdown", NewFile.startingText(.note, format: .md, title: "Trip", date: "2026-10-21"),
              "# Trip\n\n2026-10-21\n")
        let plain = NewFile.startingText(.meeting, format: .txt, title: "Weekly", date: "2026-10-21")
        check("plain text has no Markdown marks", "\(plain.contains("#") || plain.contains("**"))", "false")
        check("plain text is headed in capitals", "\(plain.hasPrefix("WEEKLY"))", "true")
        let taken: Set<String> = ["a.md", "a (2).md"]
        let free = NewFile.freeURL(folder: URL(fileURLWithPath: "/tmp"), name: "a.md") {
            taken.contains($0.lastPathComponent)
        }
        check("a taken name is counted up", free.lastPathComponent, "a (3).md")
        do {
            let text = NewFile.startingText(.meeting, format: .rtf, title: "Weekly", date: "2026-10-21")
            let data = try NewFile.data(format: .rtf, text: text)
            check("rtf file is RTF", String(decoding: data.prefix(5), as: UTF8.self), "{\\rtf")
            let back = try RTFMarkdown.markdown(fromRTF: data).markdown
            check("rtf template reads back", "\(back.contains("# Weekly") && back.contains("## Agenda"))", "true")
        } catch {
            failures += 1
            print("  FAIL  New File RTF threw: \(error)")
        }
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
