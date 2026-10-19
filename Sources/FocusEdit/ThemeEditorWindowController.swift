import AppKit

/// A small panel to create/edit a custom theme: name, dark toggle and color
/// wells for background / foreground / dimmed / cursor.
final class ThemeEditorWindowController: NSWindowController {

    private let nameField = NSTextField(string: "My Theme")
    private let darkCheck = NSButton(checkboxWithTitle: "Dark Appearance", target: nil, action: nil)
    private let bgWell = NSColorWell()
    private let fgWell = NSColorWell()
    private let dimWell = NSColorWell()
    private let cursorWell = NSColorWell()

    /// Called after a theme is saved so the app can refresh menu + apply it.
    var onSave: ((Theme) -> Void)?

    convenience init(seed: Theme) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Edit Theme"
        self.init(window: window)

        bgWell.color = seed.background
        fgWell.color = seed.foreground
        dimWell.color = seed.dimmed
        cursorWell.color = seed.cursor
        darkCheck.state = seed.isDark ? .on : .off

        func row(_ label: String, _ control: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let r = NSStackView(views: [l, control])
            r.orientation = .horizontal
            r.spacing = 8
            return r
        }
        for well in [bgWell, fgWell, dimWell, cursorWell] {
            well.widthAnchor.constraint(equalToConstant: 48).isActive = true
            well.heightAnchor.constraint(equalToConstant: 24).isActive = true
        }

        let save = NSButton(title: "Save", target: self, action: #selector(saveTheme))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(closeWindow))
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [
            row("Name:", nameField),
            row("", darkCheck),
            row("Background:", bgWell),
            row("Foreground:", fgWell),
            row("Dimmed:", dimWell),
            row("Cursor:", cursorWell),
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 160).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content
        window.center()
    }

    @objc private func saveTheme() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { NSSound.beep(); return }
        let theme = Theme(name: name, isDark: darkCheck.state == .on,
                          background: bgWell.color, foreground: fgWell.color,
                          dimmed: dimWell.color, cursor: cursorWell.color)
        ThemeStore.addOrUpdate(theme)
        onSave?(theme)
        closeWindow()
    }

    @objc private func closeWindow() {
        close()
    }
}
