import AppKit

/// File ▸ New File…: a three-step dialog (format, what to start from, name and folder) that makes
/// a .txt, .md or .rtf file on disk and opens it. The rules here match windows/src/newfile.ts.

enum NewFileFormat: CaseIterable {
    case txt, md, rtf

    var fileExtension: String {
        switch self {
        case .txt: "txt"
        case .md:  "md"
        case .rtf: "rtf"
        }
    }

    var title: String {
        switch self {
        case .txt: "Plain text  .txt"
        case .md:  "Markdown  .md"
        case .rtf: "Rich text  .rtf"
        }
    }

    var details: String {
        switch self {
        case .txt: "Just words, no formatting. Opens in any program."
        case .md:  "Headings, lists and links written with simple marks. Has a live preview."
        case .rtf: "Bold, italic and headings that TextEdit, Pages and Word show formatted."
        }
    }
}

enum NewFileTemplate: CaseIterable {
    case blank, note, todo, meeting

    var title: String {
        switch self {
        case .blank:   "Blank"
        case .note:    "Note"
        case .todo:    "To-do list"
        case .meeting: "Meeting notes"
        }
    }

    var details: String {
        switch self {
        case .blank:   "An empty file."
        case .note:    "A title, today’s date and room to write."
        case .todo:    "A short checklist to tick off."
        case .meeting: "Date, people, agenda, decisions and next steps."
        }
    }
}

enum NewFile {

    /// Today as 2026-10-21, in local time.
    static func isoDate(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The name offered in step 3 for a template.
    static func defaultName(_ template: NewFileTemplate, date: String) -> String {
        switch template {
        case .blank:   "Untitled"
        case .note:    "Note \(date)"
        case .todo:    "To-do \(date)"
        case .meeting: "Meeting \(date)"
        }
    }

    private static let forbidden = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
    private static let knownExtensions = ["txt", "md", "markdown", "rtf"]

    /// A name typed by the user, cleaned up for a file name (without the extension).
    static func cleanName(_ input: String) -> String {
        var name = input.components(separatedBy: forbidden).joined(separator: " ")
        name = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let ns = name as NSString
        if knownExtensions.contains(ns.pathExtension.lowercased()) { name = ns.deletingPathExtension }
        while let last = name.last, last == "." || last == " " { name.removeLast() }
        if name.count > 100 { name = String(name.prefix(100)).trimmingCharacters(in: .whitespaces) }
        return name.isEmpty ? "Untitled" : name
    }

    /// The file name for what was typed and the chosen format: "notes" + md → "notes.md".
    static func fileName(_ input: String, format: NewFileFormat) -> String {
        cleanName(input) + "." + format.fileExtension
    }

    /// `name` in `folder` if free, else "name (2).ext", "name (3).ext"…
    static func freeURL(
        folder: URL, name: String, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let first = folder.appendingPathComponent(name)
        if !exists(first) { return first }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for n in 2..<1000 {
            let candidate = folder.appendingPathComponent("\(stem) (\(n))" + (ext.isEmpty ? "" : ".\(ext)"))
            if !exists(candidate) { return candidate }
        }
        return folder.appendingPathComponent("\(stem) (\(Int(Date().timeIntervalSince1970)))." + ext)
    }

    private enum Block {
        case heading(String)
        case text(String)
        case list([String])
        case todo([String])
    }

    private static func blocks(_ template: NewFileTemplate, title: String, date: String) -> [Block] {
        switch template {
        case .blank:
            return []
        case .note:
            return [.heading(title), .text(date), .text("")]
        case .todo:
            return [.heading(title), .todo(["First thing", "Second thing", "Third thing"])]
        case .meeting:
            return [
                .heading(title), .text("Date: \(date)"), .text("People: "),
                .heading("Agenda"), .list(["", ""]),
                .heading("Decisions"), .list([""]),
                .heading("Next steps"), .todo(["", ""]),
            ]
        }
    }

    /// The text a new file starts with, as the editor shows it: Markdown for md and rtf, plain text for txt.
    static func startingText(
        _ template: NewFileTemplate, format: NewFileFormat, title: String, date: String
    ) -> String {
        let plain = format == .txt
        var out: [String] = []
        for block in blocks(template, title: cleanName(title), date: date) {
            switch block {
            case .heading(let text):
                out.append(plain ? text.uppercased() + "\n" : (out.isEmpty ? "# " : "## ") + text + "\n")
            case .text(let text):
                out.append(text)
            case .list(let items):
                out.append(items.map { "- \($0)" }.joined(separator: "\n") + "\n")
            case .todo(let items):
                out.append(items.map { plain ? "[ ] \($0)" : "- [ ] \($0)" }.joined(separator: "\n") + "\n")
            }
        }
        var text = out.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        while text.hasPrefix("\n") { text.removeFirst() }
        while text.hasSuffix("\n") { text.removeLast() }
        return text.isEmpty ? "" : text + "\n"
    }

    /// What goes into the file on disk: the text itself, or RTF made from the Markdown.
    static func data(format: NewFileFormat, text: String) throws -> Data {
        format == .rtf ? try RTFMarkdown.rtf(fromMarkdown: text) : Data(text.utf8)
    }
}

/// The dialog itself. `run()` shows it modally and returns the choices, or nil if cancelled.
final class NewFileWizard: NSObject {

    struct Result {
        let format: NewFileFormat
        let template: NewFileTemplate
        let name: String
        let folder: URL
    }

    private let window: NSWindow
    private let stepLabel = NSTextField(labelWithString: "")
    private let body = NSView()
    private let backButton = NSButton(title: "Back", target: nil, action: nil)
    private let nextButton = NSButton(title: "Next", target: nil, action: nil)
    private var radios: [NSButton] = []
    private let nameField = NSTextField(string: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")

    private var step = 1
    private var format = NewFileFormat.md
    private var template = NewFileTemplate.blank
    private var nameEdited = false
    private var folder: URL
    private let date = NewFile.isoDate()
    private var result: Result?

    private static let stepTitles = ["Format", "Start from", "Name and folder"]

    override init() {
        folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = "New File"
        build()
    }

    func run() -> Result? {
        render()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return result
    }

    // MARK: Layout

    private func build() {
        let title = NSTextField(labelWithString: "New File")
        title.font = .boldSystemFont(ofSize: 15)
        stepLabel.textColor = .secondaryLabelColor

        body.translatesAutoresizingMaskIntoConstraints = false
        body.heightAnchor.constraint(equalToConstant: 220).isActive = true

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        backButton.target = self
        backButton.action = #selector(back(_:))
        nextButton.target = self
        nextButton.action = #selector(next(_:))
        nextButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let buttons = NSStackView(views: [cancel, spacer, backButton, nextButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, stepLabel, body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        window.contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            body.widthAnchor.constraint(equalToConstant: 440),
            buttons.widthAnchor.constraint(equalToConstant: 440),
        ])
    }

    private func render() {
        stepLabel.stringValue = "Step \(step) of 3 · \(Self.stepTitles[step - 1])"
        backButton.isHidden = step == 1
        nextButton.title = step == 3 ? "Create" : "Next"
        body.subviews.forEach { $0.removeFromSuperview() }
        let page: NSView
        switch step {
        case 1:
            let formats = NewFileFormat.allCases
            page = choicePage(formats.map { ($0.title, $0.details) }, selected: formats.firstIndex(of: format) ?? 0)
        case 2:
            let templates = NewFileTemplate.allCases
            page = choicePage(templates.map { ($0.title, $0.details) }, selected: templates.firstIndex(of: template) ?? 0)
        default: page = namePage()
        }
        page.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            page.topAnchor.constraint(equalTo: body.topAnchor),
        ])
        if step == 3 { window.makeFirstResponder(nameField) }
    }

    private func choicePage(_ items: [(String, String)], selected: Int) -> NSView {
        radios = []
        var rows: [NSView] = []
        for (index, item) in items.enumerated() {
            let radio = NSButton(radioButtonWithTitle: item.0, target: self, action: #selector(picked(_:)))
            radio.tag = index
            radio.state = index == selected ? .on : .off
            radio.font = .boldSystemFont(ofSize: 13)
            radios.append(radio)
            let detail = NSTextField(wrappingLabelWithString: item.1)
            detail.textColor = .secondaryLabelColor
            detail.font = .systemFont(ofSize: 12)
            let row = NSStackView(views: [radio, detail])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 2
            detail.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20).isActive = true
            rows.append(row)
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        return stack
    }

    private func namePage() -> NSView {
        if !nameEdited { nameField.stringValue = NewFile.defaultName(template, date: date) }
        nameField.target = self
        nameField.action = #selector(nameChanged(_:))
        nameField.delegate = self
        pathLabel.stringValue = folder.path
        pathLabel.lineBreakMode = .byTruncatingMiddle
        previewLabel.lineBreakMode = .byTruncatingMiddle
        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let change = NSButton(title: "Change…", target: self, action: #selector(changeFolder(_:)))
        let folderRow = NSStackView(views: [NSTextField(labelWithString: "Folder:"), pathLabel, change])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8
        pathLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let rows: [NSView] = [
            NSTextField(labelWithString: "File name"), nameField, folderRow,
            NSTextField(labelWithString: "Will be saved as"), previewLabel,
        ]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        nameField.widthAnchor.constraint(equalToConstant: 440).isActive = true
        folderRow.widthAnchor.constraint(equalToConstant: 440).isActive = true
        updatePreview()
        return stack
    }

    private func updatePreview() {
        let name = NewFile.fileName(nameField.stringValue, format: format)
        previewLabel.stringValue = folder.appendingPathComponent(name).path
    }

    // MARK: Actions

    @objc private func picked(_ sender: NSButton) {
        for radio in radios { radio.state = radio === sender ? .on : .off }
        if step == 1 { format = NewFileFormat.allCases[sender.tag] } else { template = NewFileTemplate.allCases[sender.tag] }
    }

    @objc private func nameChanged(_ sender: Any?) {
        nameEdited = true
        updatePreview()
    }

    @objc private func changeFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
        pathLabel.stringValue = url.path
        updatePreview()
    }

    @objc private func back(_ sender: Any?) {
        step = max(1, step - 1)
        render()
    }

    @objc private func next(_ sender: Any?) {
        if step < 3 {
            step += 1
            render()
        } else {
            result = Result(format: format, template: template, name: nameField.stringValue, folder: folder)
            NSApp.stopModal()
        }
    }

    @objc private func cancel(_ sender: Any?) {
        result = nil
        NSApp.stopModal()
    }
}

extension NewFileWizard: NSTextFieldDelegate {
    /// The preview follows every keystroke.
    func controlTextDidChange(_ obj: Notification) {
        nameEdited = true
        updatePreview()
    }
}
