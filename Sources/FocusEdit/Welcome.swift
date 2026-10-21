import AppKit

/// The welcome document: shown once on the first start, and again from
/// Help ▸ Welcome Tour or the palette. It teaches by being edited.
/// Mirrors `windows/src/welcome.ts`, with the Mac keys.
enum Welcome {
    private static let key = "welcome.shown.v1"

    static var wasShown: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markShown() { UserDefaults.standard.set(true, forKey: key) }

    /// A new, untitled window with the tour in it (Save asks for a name, Welcome.md).
    static func open() {
        guard let doc = try? NSDocumentController.shared
            .openUntitledDocumentAndDisplay(true) as? FocusDocument else { return }
        doc.applyTemplate(text, fileExtension: "md")
        doc.displayName = "Welcome"
        doc.windowControllers.forEach { $0.synchronizeWindowTitleWithDocumentName() }
        doc.updateChangeCount(.changeCleared)
    }

    static let text = """
    # Welcome to FocusEdit

    A quiet place to write. Everything you are not working on fades away, and your
    file stays plain text.

    ## Try this

    - Move the caret between paragraphs: the **focus** fades smoothly. The target button in the toolbar switches Off · Sentence · Paragraph.
    - Start a word and see the grey suggestion: press Tab to take it.
    - Select a word and paste a web address: you get a link.
    - Type `- ` and a list item, press Return: the list continues.
    - Press ⇧⌘P and type "theme": every command is in the palette.

    ## Look around

    | Keys | What it does |
    |---|---|
    | ⇧⌘P | Command palette: find anything by typing |
    | ⌥⌘P | View: Edit → Split → Preview |
    | ⌥⌘O | Outline of the headings |
    | ⌥⌘L | Library: a folder of your documents |
    | ⌘T | Keep the line you are writing in the middle |
    | ⇧⌘N | New File…: format, template, name |
    | ⌘? | Hints and shortcuts |

    > Set a word goal from the palette ("Word goal") for a thin progress bar and a timer
    > that counts only the time you actually write.

    ## Learn Vim while you write

    The Vim button in the toolbar turns on Vim mode with a coach under the text that
    explains every command. `:novim` turns it off again.

    ---

    Save this document with ⌘S, or start a new one with ⌘N. Ready? Press ⌘A and start typing over all of this.

    """
}
