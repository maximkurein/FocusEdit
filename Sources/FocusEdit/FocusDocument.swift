import AppKit

/// Document for .txt / .md / .fountain (UTF-8 plain text) and .rtf (edited as
/// Markdown, converted on read and write); display styling lives only in the text view.
final class FocusDocument: NSDocument {

    private var content: String = ""

    /// Save As / rename can change the extension (e.g. Untitled → notes.md):
    /// switch the editor to the new document type right away.
    override var fileURL: URL? {
        didSet {
            if let ext = fileURL?.pathExtension { editor?.updateKind(fileExtension: ext) }
            editor?.updateStart()
            editor?.onFileURLChanged?()
        }
    }
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
        warnAboutLostFormatting(in: controller.window)
        replacePristineDocuments(with: controller.window)
        split.restoreAppearanceIfNeeded()    }

    var isPristine: Bool { editor?.isPristine ?? false }

    /// As on Windows, a file opened while the only thing on screen is an empty untitled
    /// document takes its place: same window frame, and the empty one goes away.
    private func replacePristineDocuments(with window: NSWindow?) {
        guard fileURL != nil, let window, !Snapshot.isActive else { return }
        for case let other as FocusDocument in NSDocumentController.shared.documents
        where other !== self && other.isPristine {
            if let frame = other.windowControllers.first?.window?.frame { window.setFrame(frame, display: true) }
            other.close()
        }
    }

    // MARK: Reading / writing

    /// Info.plist type name for .rtf. RTF is edited as Markdown (RTFMarkdown).
    static let rtfType = "Rich Text"

    /// Formatting an opened RTF file had that the Markdown round trip drops.
    private var lostFormatting: [String] = []

    override func data(ofType typeName: String) throws -> Data {
        if let editor { content = editor.textView.string }
        if typeName == Self.rtfType { return try RTFMarkdown.rtf(fromMarkdown: content) }
        return Data(content.utf8)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        if typeName == Self.rtfType || fileURL?.pathExtension.lowercased() == "rtf" {
            let imported = try RTFMarkdown.markdown(fromRTF: data)
            content = imported.markdown
            lostFormatting = imported.lostFormatting
        } else {
            content = String(decoding: data, as: UTF8.self)
            lostFormatting = []
        }
        editor?.loadContent(content, fileExtension: fileURL?.pathExtension ?? "txt")
    }

    /// Warn once, after the window is up, that saving will drop some formatting.
    private func warnAboutLostFormatting(in window: NSWindow?) {
        guard !lostFormatting.isEmpty, let window, !Snapshot.isActive else { return }
        let alert = NSAlert()
        alert.messageText = "Some formatting in this RTF file can’t be kept"
        alert.informativeText = """
            FocusEdit keeps bold, italic, headings, lists and links. This file also has \
            \(lostFormatting.joined(separator: ", ")), which saving it will remove. \
            To keep the original, use File ▸ Save As… with a new name.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: Edit tracking (drives the window's "edited" dot)

    /// Called by the editor whenever the text changes.
    func noteTextEdited() {
        updateChangeCount(.changeDone)
    }

    /// Fill a freshly-created untitled document from a template.
    func applyTemplate(_ text: String, fileExtension ext: String) {
        content = text
        // Type names from Info.plist: Save suggests .md / .fountain, not .txt.
        switch DocumentKind(fileExtension: ext) {
        case .markdown: fileType = "Markdown"
        case .fountain: fileType = "Fountain Script"
        case .plain:    break
        }
        editor?.loadContent(text, fileExtension: ext)
        updateChangeCount(.changeDone)
    }
}
