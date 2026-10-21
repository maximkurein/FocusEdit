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
        label.preferredMaxLayoutWidth = 340
        label.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            label.widthAnchor.constraint(equalToConstant: 340),
        ])
        view = container
        preferredContentSize = container.fittingSize
    }

    // MARK: Content

    private var sections: [Section] {
        var list = [
            Section(title: "Writing", rows: [
                ("Tab  →", "Accept the grey suggestion"),
                ("Esc", "Dismiss it  ·  ⌥Esc lists all completions"),
                ("Return", "Continue a list or quote; on an empty item, end it"),
                ("( [ { \" `", "Close automatically; select text first to wrap it"),
            ]),
            Section(title: "Focus", rows: [
                ("◎ toolbar", "Highlight off · sentence · paragraph — click to cycle"),
                ("⌘T", "Keep the active line centred"),
                ("⌘U", "Typewriter sounds"),
                ("⌃⌘F", "Full screen — toolbar and menu hide"),
            ]),
        ]
        if vim {
            list.insert(Section(title: "Vim mode — operator + motion", rows: [
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
        switch kind {
        case .markdown:
            list.append(Section(title: "Markdown", rows: [
                ("# Title", "Heading — see the outline (⌥⌘O)"),
                ("**b**  *i*", "Bold ⌘B · italic ⌘I"),
                ("- item  1. item", "Lists · ⌘] / ⌘[ indent"),
                ("> quote", "Blockquote"),
                ("[text](url)", "Link · ⌘K"),
                ("{++ ++} {-- --}", "CriticMarkup — Edit ▸ CriticMarkup"),
                ("⌥⌘P", "View: Edit → Split (live preview) → Preview; Esc back to editing"),
            ]))
        case .fountain:
            list.append(Section(title: "Fountain", rows: [
                ("INT. / EXT.", "Scene heading — type IN, press Tab"),
                ("MARY", "Character — names you used are suggested"),
                ("(quietly)", "Parenthetical"),
                ("CUT TO:", "Transition"),
                ("# Act  = note", "Section · synopsis"),
            ]))
        case .plain:
            break
        }
        list.append(Section(title: "Files", rows: [
            ("⌥⌘L", "Library — link a folder of documents"),
            ("⌘F  ⌥⌘F", "Find · find and replace"),
        ]))
        return list
    }

    private func render(_ sections: [Section]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let keyColumn: CGFloat = 118

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
