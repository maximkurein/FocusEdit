import AppKit

/// Plain-text document for .txt / .md / .fountain. Content is always read and
/// written as UTF-8 plain text; display styling lives only in the text view.
final class FocusDocument: NSDocument {

    private var content: String = ""
    private weak var editor: EditorViewController?

    // Classic Save / Save As… / Revert semantics (no autosave-in-place).
    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        let split = MainSplitViewController()
        self.editor = split.editor

        let controller = DocumentWindowController(split: split)
        addWindowController(controller)

        split.editor.attach(document: self)
        split.loadDocument(content, fileExtension: fileURL?.pathExtension ?? "txt")
        controller.window?.makeFirstResponder(split.editor.textView)
        if Snapshot.isActive {
            controller.window?.alphaValue = 0
            controller.window?.orderFront(nil)
        } else {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: Reading / writing (plain text only)

    override func data(ofType typeName: String) throws -> Data {
        if let editor { content = editor.textView.string }
        return Data(content.utf8)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        content = String(decoding: data, as: UTF8.self)
        editor?.loadContent(content, fileExtension: fileURL?.pathExtension ?? "txt")
    }

    // MARK: Edit tracking (drives the window's "edited" dot)

    /// Called by the editor whenever the text changes.
    func noteTextEdited() {
        updateChangeCount(.changeDone)
    }

    /// Fill a freshly-created untitled document from a template.
    func applyTemplate(_ text: String, fileExtension ext: String) {
        content = text
        editor?.loadContent(text, fileExtension: ext)
        updateChangeCount(.changeDone)
    }
}
