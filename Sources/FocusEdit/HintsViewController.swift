import AppKit

/// Compact cheat sheet shown in a popover (⌘? or the toolbar "?" button):
/// writing aids, focus shortcuts and syntax for the current document type.
final class HintsViewController: NSViewController {

    private struct Section {
        let title: String
        let rows: [(key: String, text: String)]
    }

    private let kind: DocumentKind
    private let vim: Bool

    init(kind: DocumentKind, vim: Bool = false) {
        self.kind = kind
        self.vim = vim
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let label = NSTextField(labelWithAttributedString: render(sections))
        label.isSelectable = false
        label.preferredMaxLayoutWidth = 360
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            label.widthAnchor.constraint(equalToConstant: 360),
        ])
        view = container
        preferredContentSize = container.fittingSize
    }

    // MARK: Content

    /// The cheat sheet for this Mac app (⌘, not Ctrl). Windows has its own list.
    static func catalog(kind: DocumentKind, vim: Bool) -> [(title: String, rows: [(key: String, text: String)])] {
        var list: [(title: String, rows: [(key: String, text: String)])] = [
            (title: "Commands", rows: [
                ("⇧⌘P", "Command palette: type what you want to do"),
                ("⌘?", "This sheet — also the toolbar ?"),
                ("a number", "In the palette: set a word goal, or go to a line"),
                ("Word goal", "Palette: progress bar under the toolbar, writing time"),
                ("Select + ⌘V URL", "Makes a Markdown link"),
                ("Markup", "Palette or Modus: hide the marks (#, **, [ ]) away from the cursor"),
            ]),
            (title: "Writing", rows: [
                ("Tab  →", "Accept the grey suggestion"),
                ("Esc", "Dismiss it  ·  ⌥Esc lists all completions"),
                ("Return", "Continue a list or quote; on an empty item, end it"),
                ("( [ { \" `", "Close automatically; select text first to wrap it"),
            ]),
            (title: "Focus", rows: [
                ("◎ toolbar", "Highlight off · sentence · paragraph — click to cycle"),
                ("⌘T", "Typewriter: keep the caret line centred (starts off)"),
                ("⌘U", "Typewriter sounds"),
                ("⌘+  ⌘−  ⌘0", "Text size, also ⌘-scroll; the preview follows"),
                ("⌃⌘F", "Full screen — toolbar and menu hide"),
            ]),
        ]
        if vim {
            list.insert((title: "Vim mode — operator + motion", rows: [
                ("Esc  i a o", "Normal mode · insert before / after / new line"),
                ("h j k l", "Left, down, up, right"),
                ("w b e  0 $", "Word forward / back / end · line start / end"),
                ("gg G  { }", "First / last line · paragraph back / forward"),
                ("d c y", "Delete, change, copy — then a motion: dw, c$, y}"),
                ("dd yy p", "Delete / copy a line · put it below"),
                ("ciw di\" da(", "Text objects: word, inside quotes, (…) group"),
                ("u  Ctrl-r  .", "Undo · redo · repeat the last change"),
                ("v V  /  :w", "Visual · Visual Line · search · save"),
            ]), at: 0)
        }
        if kind.supportsHTML {
            list.append((title: "View", rows: [
                ("⌥⌘P", "Edit → Split (live preview) → Preview — or the toolbar; Esc leaves Preview"),
                ("⌥⌘O", "Outline of the headings"),
                ("Preview theme", "Palette: same as the editor, or its own"),
            ] + (kind == .markdown
                ? [("Click a code block", "In the preview, copies the command")]
                : [])))
        }
        switch kind {
        case .markdown:
            list.append((title: "Markdown", rows: [
                ("# Title", "Heading — see the outline"),
                ("**b**  *i*", "Bold ⌘B · italic ⌘I"),
                ("- item  1. item", "Lists · ⌘] / ⌘[ indent · - [ ] task"),
                ("> quote", "Blockquote"),
                ("[text](url)", "Link · ⌘K"),
                ("{++ ++} {-- --}", "CriticMarkup — Edit ▸ CriticMarkup"),
            ]))
        case .fountain:
            list.append((title: "Fountain", rows: [
                ("INT. / EXT.", "Scene heading — type IN, press Tab"),
                ("MARY", "Character — names you used are suggested"),
                ("(quietly)", "Parenthetical"),
                ("CUT TO:", "Transition"),
                ("# Act  = note", "Section · synopsis"),
            ]))
        case .plain:
            break
        }
        list.append((title: "Files", rows: [
            ("⇧⌘N  ⌘N", "New file… · empty document"),
            ("⌘O  ⌘S  ⇧⌘S", "Open · save · save as"),
            ("⌘W", "Close the file; the window stays with a start screen"),
            ("⌘P", "Print, or save as PDF from the print dialog"),
            ("⌥⌘L", "Library — link a folder of documents"),
            ("⌘F  ⌥⌘F", "Find · find and replace"),
            ("drag a file", "Drop .md, .txt, .rtf or .fountain on the window"),
        ]))
        return list
    }

    private var sections: [Section] {
        Self.catalog(kind: kind, vim: vim).map { Section(title: $0.title, rows: $0.rows) }
    }

    private func render(_ sections: [Section]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let keyColumn: CGFloat = 128

        let rowStyle = NSMutableParagraphStyle()
        rowStyle.tabStops = [NSTextTab(textAlignment: .left, location: keyColumn)]
        rowStyle.headIndent = keyColumn
        rowStyle.paragraphSpacing = 4

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.paragraphSpacing = 6

        for (i, section) in sections.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: section.title.uppercased() + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.6,
                .paragraphStyle: titleStyle,
            ]))
            for row in section.rows {
                out.append(NSAttributedString(string: row.key, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: rowStyle,
                ]))
                out.append(NSAttributedString(string: "\t" + row.text + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: rowStyle,
                ]))
            }
        }
        if out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return out
    }
}
