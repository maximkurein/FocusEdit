import AppKit

/// The start screen over an empty, untitled, untouched document: New File…,
/// Open…, and up to five recent files. The first typed letter removes it.
/// Mirrors `updateStart()` in `windows/src/main.ts`.
final class StartView: NSView {

    var onNewFile: (() -> Void)?
    var onOpen: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?

    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: 360),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Rebuild with the current recent files and the theme's colours.
    func reload(recent: [URL], foreground: NSColor, dimmed: NSColor, background: NSColor) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        layer?.backgroundColor = background.blended(withFraction: 0.06, of: foreground)?.cgColor
        layer?.borderColor = dimmed.withAlphaComponent(0.35).cgColor
        layer?.borderWidth = 1

        let title = NSTextField(labelWithString: "Start")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = foreground
        let hint = NSTextField(labelWithString: "Make a file, open one, or just start typing.")
        hint.textColor = dimmed
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(hint)
        stack.setCustomSpacing(14, after: hint)

        stack.addArrangedSubview(row("New File…", detail: "⇧⌘N", primary: true, color: foreground, dim: dimmed) { [weak self] in
            self?.onNewFile?()
        })
        stack.addArrangedSubview(row("Open…", detail: "⌘O", color: foreground, dim: dimmed) { [weak self] in
            self?.onOpen?()
        })
        let files = Array(recent.prefix(5))
        guard !files.isEmpty else { return }
        let header = NSTextField(labelWithString: "Recent")
        header.font = .systemFont(ofSize: 11, weight: .semibold)
        header.textColor = dimmed
        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(header)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for url in files {
            var folder = url.deletingLastPathComponent().path
            if folder.hasPrefix(home) { folder = "~" + folder.dropFirst(home.count) }
            stack.addArrangedSubview(row(url.lastPathComponent, detail: folder, color: foreground, dim: dimmed) { [weak self] in
                self?.onOpenRecent?(url)
            })
        }
    }

    /// A full-width, borderless button: the name on the left, a dim key or folder on the right.
    private func row(_ title: String, detail: String, primary: Bool = false,
                     color: NSColor, dim: NSColor, action: @escaping () -> Void) -> NSView {
        let button = ActionButton(action: action)
        button.isBordered = false
        button.title = ""
        button.setButtonType(.momentaryChange)
        button.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 14, weight: primary ? .semibold : .regular)
        name.textColor = primary ? .controlAccentColor : color
        name.lineBreakMode = .byTruncatingTail
        let right = NSTextField(labelWithString: detail)
        right.font = .systemFont(ofSize: 11)
        right.textColor = dim
        right.lineBreakMode = .byTruncatingHead
        right.alignment = .right
        for v in [name, right] {
            v.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(v)
        }
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 312),
            button.heightAnchor.constraint(equalToConstant: 26),
            name.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            name.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 12),
            right.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            right.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        button.toolTip = primary || detail.hasPrefix("⌘") ? nil : detail
        return button
    }
}

/// A button that runs a closure and never takes the keyboard from the text.
private final class ActionButton: NSButton {
    private let run: () -> Void
    init(action: @escaping () -> Void) {
        run = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(fire)
        refusesFirstResponder = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func fire() { run() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
