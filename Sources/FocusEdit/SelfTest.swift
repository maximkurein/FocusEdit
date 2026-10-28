import AppKit
import PDFKit

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
        session()
        outline()
        live()
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
        // Highlighted spans of one role, as text: "a|b" for two spans.
        func spans(_ text: String, _ role: SyntaxRole) -> String {
            SyntaxEngine(highlighter: MarkdownHighlighter()).tokens(for: text as NSString)
                .filter { $0.role == role }
                .map { (text as NSString).substring(with: $0.range) }
                .joined(separator: "|")
        }
        check("snake_case is not italic", spans("app_keys.json and xui_config.json", .emphasis), "")
        check("_word_ is italic", spans("an _italic_ word", .emphasis), "_italic_")
        check("*word* is italic", spans("an *italic* word", .emphasis), "*italic*")
        check("no italic inside code", spans("`app_*keys*.json` and *real*", .emphasis), "*real*")
        check("no bold inside code", spans("`**x**` **y**", .strong), "**y**")
        check("fenced block is code", spans("a\n```bash\nchmod 600 a_b.json c_d.json\n```\nb", .code),
              "```bash|chmod 600 a_b.json c_d.json|```")
        check("nothing italic in a fence", spans("```\n*not* _this_\n```\n*yes*", .emphasis), "*yes*")
        check("tilde fence closes only on tilde", spans("~~~\n```\n*x*\n~~~\n*y*", .emphasis), "*y*")

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
        check("preview follows the text size",
              MarkdownToHTML.document("x", dark: false, fontSize: 22).contains("font: 22.0px/1.6") ? "yes" : "no", "yes")
        check("preview page keeps a reading measure",
              MarkdownToHTML.document("x", dark: false).contains("max-width: 45em") ? "yes" : "no", "yes")
        check("split preview fills its pane",
              MarkdownToHTML.document("x", dark: false, fitted: true).contains("max-width: none") ? "yes" : "no", "yes")
        check("sepia preview uses sepia paper",
              MarkdownToHTML.document("x", dark: false, colors: Theme.sepia.pageColors).contains(Theme.sepia.pageColors.background) ? "yes" : "no", "yes")
        check("sepia paper is not white", Theme.sepia.pageColors.background == "#ffffff" ? "yes" : "no", "no")
        check("powershell paper is the console blue", Theme.powerShell.pageColors.background, "#012456")
        check("powershell text is light gray", Theme.powerShell.pageColors.foreground, "#cccccc")
        check("zoom in by 2", "\(EditorViewController.zoomedFontSize(16, by: 2))", "18.0")
        check("zoom stops at 40", "\(EditorViewController.zoomedFontSize(39, by: 2))", "40.0")
        check("zoom stops at 10", "\(EditorViewController.zoomedFontSize(11, by: -2))", "10.0")
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
        check("split opens at a reading width", "\(Int(ReadingLayout.contentWidth(sidebars: 0, screenWidth: 1800, current: 1600)))", "1120")
        check("split stays on a small screen", "\(Int(ReadingLayout.contentWidth(sidebars: 0, screenWidth: 1000, current: 1180)))", "984")
        check("a wide window is narrowed", "\(Int(ReadingLayout.contentWidth(sidebars: 200, screenWidth: 2200, current: 1800)))", "1320")
        check("even split", "\(Int(ReadingLayout.editorWidth(available: 1440, share: 0.5)))", "720")
        check("a saved wider editor", "\(Int(ReadingLayout.editorWidth(available: 1400, share: 0.62)))", "868")
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

        check("System theme is first", ThemeStore.allThemes().first?.name, "System")
        check("System follows dark", Theme.system(dark: true).isDark ? "dark" : "light", "dark")
        check("System follows light", Theme.system(dark: false).background == Theme.light.background ? "light" : "?", "light")

        // Print and PDF ignore the theme and the focus fading.
        editor.apply(theme: .dark)
        editor.loadContent(String(repeating: "# Dark theme\n\nSome **text** to print.\n\n", count: 120), fileExtension: "md")
        let info = NSPrintInfo()
        let page = editor.printableView(for: info)
        check("print page is white", page.backgroundColor == .white ? "white" : "not white", "white")
        let ink = page.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        check("print text is black", ink == .black ? "black" : "not black", "black")
        let pdfURL = FileManager.default.temporaryDirectory.appendingPathComponent("focusedit-selftest-\(ProcessInfo.processInfo.processIdentifier).pdf")
        editor.writePDF(to: pdfURL)
        let pages = CGPDFDocument(pdfURL as CFURL)?.numberOfPages ?? 0
        check("PDF has several pages", pages > 1 ? "yes" : "no (\(pages))", "yes")
        let pdfText = PDFDocument(url: pdfURL)?.page(at: 0)?.string ?? ""
        check("PDF has the text", pdfText.contains("Some **text** to print.") ? "yes" : "no", "yes")
        try? FileManager.default.removeItem(at: pdfURL)
    }

    // MARK: Writing session (cases from windows/tests/palette-session-links.test.ts)

    private static func session() {
        print("Session:")
        check("no words", String(Session.countWords("")), "0")
        check("words across spaces and lines", String(Session.countWords("  one  two\nthree\t")), "3")
        check("Russian words", String(Session.countWords("слова по-русски")), "2")

        var s = Session()
        s.reset(words: 100, now: 0)
        s.note(words: 130, now: 1000)
        check("written since the start", String(s.written), "30")
        s.note(words: 60, now: 2000)
        check("never below zero", String(s.written), "0")

        s = Session()
        s.reset(words: 0, now: 0)
        s.note(words: 50, now: 1)
        check("progress", String(s.progress(goal: 200)), "0.25")
        check("no goal, no progress", String(s.progress(goal: 0)), "0.0")
        s.note(words: 500, now: 2)
        check("progress stops at 1", String(s.progress(goal: 200)), "1.0")

        s = Session()
        s.reset(words: 0, now: 0)
        s.tick(now: 1000)
        check("nothing typed, no time", String(s.activeMs), "0")
        s.note(words: 1, now: 1500)
        s.tick(now: 2000)
        s.tick(now: 3000)
        check("seconds spent writing", String(s.activeMs), "2000")
        s.tick(now: 3000 + Session.idleMs + 5000)
        check("idle time not counted", String(s.activeMs), "2000")

        s = Session()
        s.reset(words: 0, now: 0)
        s.note(words: 1, now: 100)
        s.tick(now: 1000)
        s.tick(now: 1000 + 60_000)
        check("a long gap (sleep) not counted", String(s.activeMs), "1000")

        check("0:00", Session.formatDuration(ms: 0), "0:00")
        check("1:15", Session.formatDuration(ms: 75_000), "1:15")
        check("1:02:05", Session.formatDuration(ms: 3_725_000), "1:02:05")

        // Pasting a link over selected text (cases from the same Windows tests).
        print("Link paste:")
        check("selection + address", LinkPaste.link(selected: "my site", clipboard: "https://example.com/a?b=1"),
              "[my site](https://example.com/a?b=1)")
        check("address is trimmed", LinkPaste.link(selected: "x", clipboard: "  http://example.com \n"),
              "[x](http://example.com)")
        check("trailing space stays outside", LinkPaste.link(selected: "click here ", clipboard: "https://a.b"),
              "[click here](https://a.b) ")
        check("leading space stays outside", LinkPaste.link(selected: " word", clipboard: "https://a.b"),
              " [word](https://a.b)")
        check("not an address", LinkPaste.link(selected: "word", clipboard: "just some text"), nil)
        check("address and more", LinkPaste.link(selected: "word", clipboard: "https://a.b and more"), nil)
        check("not a web address", LinkPaste.link(selected: "word", clipboard: "ftp://a.b"), nil)
        check("nothing selected", LinkPaste.link(selected: "", clipboard: "https://a.b"), nil)
        check("two lines selected", LinkPaste.link(selected: "two\nlines", clipboard: "https://a.b"), nil)
        check("brackets and parentheses escaped", LinkPaste.link(selected: "a [b]", clipboard: "https://a.b/x_(y)"),
              "[a \\[b\\]](https://a.b/x_%28y%29)")

        let board = NSPasteboard(name: NSPasteboard.Name("FocusEdit.selftest.\(ProcessInfo.processInfo.processIdentifier)"))
        board.clearContents()
        board.setString("https://a.b", forType: .string)
        let tv = makeView("see this now")
        tv.linkPasteEnabled = true
        tv.setSelectedRange(NSRange(location: 4, length: 5))
        check("paste makes the link", tv.pasteLink(from: board) ? tv.string : nil, "see [this](https://a.b) now")
        check("caret after the link and its space", String(tv.selectedRange().location), "24")
        tv.linkPasteEnabled = false
        tv.setSelectedRange(NSRange(location: 0, length: 3))
        check("off in Fountain", tv.pasteLink(from: board) ? "pasted" : "normal paste", "normal paste")
        board.releaseGlobally()
    }

    // MARK: Outline (cases from windows/tests/outline.test.ts)

    private static func outline() {
        print("Outline:")
        func titles(_ text: String, _ kind: DocumentKind = .markdown) -> String {
            OutlineExtractor.items(from: text as NSString, kind: kind)
                .map { "\($0.level):\($0.line):\($0.title)" }.joined(separator: " | ")
        }
        check("ATX headings", titles("# One\n\ntext\n\n## Two ##\n### Three"), "1:1:One | 2:5:Two | 3:6:Three")
        check("space and text needed", titles("#nospace\n#\n# \n####### seven"), "")
        check("setext headings", titles("Title\n=====\n\nSub\n---\n"), "1:1:Title | 2:4:Sub")
        check("list item and rule are not headings", titles("- item\n---\n\n***\n"), "")
        check("# inside code fences", titles("# Real\n```\n# not a heading\n```\n~~~\n# nor this\n~~~\n## After"),
              "1:1:Real | 2:8:After")
        check("a ~~~ line does not close ```", titles("```\n~~~\n# no\n```\n# yes"), "1:5:yes")
        check("YAML front matter", titles("---\ntitle: x\n---\n# Heading"), "1:4:Heading")
        check("Fountain scenes and sections",
              titles("# Act One\n\nINT. HOUSE - DAY\n\nMARY\nHi.\n\next. street - night", .fountain),
              "1:1:Act One | 2:3:INT. HOUSE - DAY | 2:8:ext. street - night")
        check("Fountain forced scene", titles(".SNIPER SCOPE POV", .fountain), "2:1:SNIPER SCOPE POV")
        check("Windows line endings", titles("# A\r\n\r\n## B\r\n"), "1:1:A | 2:3:B")
        check("plain text has Markdown headings too", titles("# Notes\ntext", .plain), "1:1:Notes")

        let h = OutlineExtractor.items(from: "# A\n\ntext\n\n## B\n\nmore\n\n## C" as NSString, kind: .markdown)
        func active(_ cursor: Int) -> String { OutlineExtractor.active(h, cursor: cursor).map(String.init) ?? "none" }
        check("current heading on its line", active(0), "0")
        check("current heading below it", active(6), "0")
        check("next heading", active(11), "1")
        check("past the end", active(999), "2")
        check("above the first heading",
              OutlineExtractor.active(OutlineExtractor.items(from: "text\n# A", kind: .markdown), cursor: 1)
                .map(String.init) ?? "none", "none")
    }

    // MARK: Live Markdown (cases from windows/tests/live.test.ts)

    private static func live() {
        print("Live markup:")
        /// What is hidden, written as the hidden text itself, sorted.
        func hidden(_ doc: String, _ cursor: Int, _ length: Int = 0) -> String {
            let ns = doc as NSString
            let set = LiveMarkdown.hidden(LiveMarkdown().elements(in: ns),
                                          selection: [NSRange(location: cursor, length: length)])
            return set.rangeView.map { ns.substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
                .sorted().joined(separator: " | ")
        }
        func headings(_ doc: String) -> String {
            LiveMarkdown().elements(in: doc as NSString).compactMap {
                if case .heading(let level) = $0.kind { return "h\(level)@\($0.range.location)" }
                return nil
            }.joined(separator: " ")
        }
        check("heading # and its space away from the cursor", hidden("# Title\n\ntext", 13), "# ")
        check("shown with the cursor on the line", hidden("# Title\n\ntext", 3), "")
        check("shown with the cursor at the line start", hidden("# Title\n\ntext", 0), "")
        let doc = "# Title\n\nSome **bold**, *it* and `code` here.\n"
        let away = (doc as NSString).length
        check("bold, italic, code marks hidden", hidden(doc, away), "#  | * | * | ** | ** | ` | `")
        let inBold = (doc as NSString).range(of: "bold").location + 1
        check("the touched element shows its marks", hidden(doc, inBold), "#  | * | * | ` | `")
        let edge = NSMaxRange((doc as NSString).range(of: "**bold**"))
        check("touching the edge shows them", hidden(doc, edge).contains("**") ? "hidden" : "shown", "shown")
        let from = (doc as NSString).range(of: "bold").location
        check("a selection reaching it shows them", hidden(doc, from, 2).contains("**") ? "hidden" : "shown", "shown")
        let md = "see [the docs](https://example.com/a) now\n\nend"
        check("link brackets and address hidden", hidden(md, (md as NSString).length), "[ | ](https://example.com/a)")
        check("link shown when touched", hidden(md, (md as NSString).range(of: "docs").location), "")
        let img = "![a cat](cat.png)\n\nend"
        check("image marks hidden", hidden(img, (img as NSString).length), "![ | ](cat.png)")
        let caption = LiveMarkdown().elements(in: img as NSString).compactMap { e -> String? in
            if case .image(let r) = e.kind { return (img as NSString).substring(with: r) }
            return nil
        }.first
        check("image caption styled", caption, "a cat")
        check("autolink brackets hidden", hidden("<https://a.b>\n\nend", 17), "< | >")
        check("heading sizes wherever the cursor is", headings("# One\n\n### Three\n\nend"), "h1@0 h3@7")
        check("setext heading size", headings("Title\n===\n\nSub\n---\n"), "h1@0 h2@11")
        check("lists, quotes, code blocks left alone", hidden("- item\n\n> quote\n\n```\ncode\n```\n\nend", 30), "")
        check("marks inside code stay", hidden("`**x**`\n\nend", 10), "` | `")
        check("strikethrough", hidden("~~gone~~\n\nend", 12), "~~ | ~~")
        check("closing hashes too", hidden("## Two ##\n\nend", 14), "## | ## ")
        check("no heading without a space", hidden("#tag\n\nend", 8), "")
        check("snake_case is not emphasis", hidden("a snake_case_name\n\nend", 20), "")
        check("--- after a fence is not a heading", headings("```\nx\n```\n---"), "")

        // In the text view: hidden marks are .null glyphs and follow edits.
        let tv = makeView("top\n\nSome **bold** here\n\nend")
        tv.syntaxEngine = SyntaxEngine(highlighter: MarkdownHighlighter())
        tv.liveMarkdownEnabled = true
        tv.refreshFocusEffects()
        func glyphs() -> String {
            guard let lm = tv.layoutManager else { return "" }
            lm.ensureGlyphs(forCharacterRange: NSRange(location: 0, length: (tv.string as NSString).length))
            let ns = tv.string as NSString
            return (0..<ns.length).map { i -> String in
                let g = lm.glyphIndexForCharacter(at: i)
                return lm.propertyForGlyph(at: g) == .null ? "·" : ns.substring(with: NSRange(location: i, length: 1))
            }.joined()
        }
        check("marks drawn as nothing", glyphs(), "top\n\nSome ··bold·· here\n\nend")
        // An edit in another paragraph: their glyphs are kept and the set moves with them.
        tv.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        check("glyphs and hidden set move together", glyphs(), "xtop\n\nSome ··bold·· here\n\nend")
        tv.recomputeSyntax()   // as EditorViewController.textDidChange does
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.refreshFocusEffects()
        check("same after the update", glyphs(), "xtop\n\nSome ··bold·· here\n\nend")
        // An edit in their own paragraph: redone at the update.
        tv.insertText("A ", replacementRange: NSRange(location: 6, length: 0))
        tv.recomputeSyntax()
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.refreshFocusEffects()
        check("an edit next to them keeps them hidden", glyphs(), "xtop\n\nA Some ··bold·· here\n\nend")
        tv.setSelectedRange(NSRange(location: 17, length: 0))
        tv.refreshFocusEffects()
        check("the cursor in the word shows them", glyphs(), "xtop\n\nA Some **bold** here\n\nend")
        tv.liveMarkdownEnabled = false
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.refreshFocusEffects()
        check("turned off: all shown", glyphs(), "xtop\n\nA Some **bold** here\n\nend")
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
        check("plain text can be previewed", DocumentKind.plain.supportsHTML ? "yes" : "no", "yes")
        check("markdown can be previewed", DocumentKind.markdown.supportsHTML ? "yes" : "no", "yes")
        check("fountain is not previewed", DocumentKind.fountain.supportsHTML ? "yes" : "no", "no")
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
