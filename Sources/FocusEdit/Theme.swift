import AppKit

/// Color scheme for the editor. Governs the window/editor background, the active
/// text color, the dimmed (non-focused) color and the caret color.
struct Theme {
    let name: String
    let isDark: Bool
    let background: NSColor
    let foreground: NSColor   // active text
    let dimmed: NSColor       // non-focused paragraphs
    let cursor: NSColor

    init(name: String, isDark: Bool, background: NSColor,
         foreground: NSColor, dimmed: NSColor, cursor: NSColor) {
        self.name = name
        self.isDark = isDark
        self.background = background
        self.foreground = foreground
        self.dimmed = dimmed
        self.cursor = cursor
    }

    static let light = Theme(
        name: "Light",
        isDark: false,
        background: NSColor(srgbRed: 1.00, green: 1.00, blue: 0.99, alpha: 1),
        foreground: NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
        dimmed:     NSColor(srgbRed: 0.72, green: 0.72, blue: 0.74, alpha: 1),
        cursor:     NSColor(srgbRed: 0.20, green: 0.48, blue: 0.95, alpha: 1)
    )

    static let dark = Theme(
        name: "Dark",
        isDark: true,
        background: NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1),
        foreground: NSColor(srgbRed: 0.88, green: 0.88, blue: 0.90, alpha: 1),
        dimmed:     NSColor(srgbRed: 0.42, green: 0.42, blue: 0.45, alpha: 1),
        cursor:     NSColor(srgbRed: 0.45, green: 0.70, blue: 1.00, alpha: 1)
    )

    static let sepia = Theme(
        name: "Sepia",
        isDark: false,
        background: NSColor(srgbRed: 0.98, green: 0.95, blue: 0.87, alpha: 1),
        foreground: NSColor(srgbRed: 0.30, green: 0.22, blue: 0.12, alpha: 1),
        dimmed:     NSColor(srgbRed: 0.66, green: 0.58, blue: 0.46, alpha: 1),
        cursor:     NSColor(srgbRed: 0.60, green: 0.40, blue: 0.16, alpha: 1)
    )

    /// PowerShell 7's console: navy paper (#012456) and light gray text.
    static let powerShell = Theme(
        name: "PowerShell",
        isDark: true,
        background: NSColor(srgbRed: 1.0 / 255, green: 36.0 / 255, blue: 86.0 / 255, alpha: 1),
        foreground: NSColor(srgbRed: 204.0 / 255, green: 204.0 / 255, blue: 204.0 / 255, alpha: 1),
        dimmed:     NSColor(srgbRed: 138.0 / 255, green: 164.0 / 255, blue: 199.0 / 255, alpha: 1),
        cursor:     NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    )

    static let all: [Theme] = [.light, .dark, .sepia, .powerShell]

    /// "System": Light or Dark, following the macOS appearance (and changing with it).
    static let systemName = "System"

    static func system(dark: Bool = systemIsDark) -> Theme {
        let base = dark ? Theme.dark : Theme.light
        return Theme(name: systemName, isDark: dark, background: base.background,
                     foreground: base.foreground, dimmed: base.dimmed, cursor: base.cursor)
    }

    static var systemIsDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// The live preview uses the same paper and ink as this theme, not only light or dark.
    var pageColors: PageColors {
        PageColors(schemeDark: isDark, background: Self.hex(background), foreground: Self.hex(foreground),
                   muted: Self.hex(dimmed), accent: Self.hex(cursor))
    }

    private static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        let part = { (v: CGFloat) in Int((Double(v) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", part(s.redComponent), part(s.greenComponent), part(s.blueComponent))
    }

    // MARK: Serialization (for custom themes)

    func toDict() -> [String: Any] {
        [ "name": name, "isDark": isDark,
          "bg": Self.rgba(background), "fg": Self.rgba(foreground),
          "dim": Self.rgba(dimmed), "cursor": Self.rgba(cursor) ]
    }

    init?(dict: [String: Any]) {
        guard let name = dict["name"] as? String,
              let bg = (dict["bg"] as? [Double]).flatMap(Theme.color),
              let fg = (dict["fg"] as? [Double]).flatMap(Theme.color),
              let dim = (dict["dim"] as? [Double]).flatMap(Theme.color),
              let cur = (dict["cursor"] as? [Double]).flatMap(Theme.color) else { return nil }
        self.init(name: name, isDark: dict["isDark"] as? Bool ?? false,
                  background: bg, foreground: fg, dimmed: dim, cursor: cur)
    }

    private static func rgba(_ c: NSColor) -> [Double] {
        let s = c.usingColorSpace(.sRGB) ?? c
        return [Double(s.redComponent), Double(s.greenComponent),
                Double(s.blueComponent), Double(s.alphaComponent)]
    }
    private static func color(_ a: [Double]) -> NSColor? {
        guard a.count == 4 else { return nil }
        return NSColor(srgbRed: a[0], green: a[1], blue: a[2], alpha: a[3])
    }
}

/// Built-in presets plus user-created custom themes (persisted in UserDefaults).
enum ThemeStore {
    private static let key = "themes.custom"
    private static let d = UserDefaults.standard

    static var custom: [Theme] {
        (d.array(forKey: key) as? [[String: Any]])?.compactMap(Theme.init(dict:)) ?? []
    }

    static func allThemes() -> [Theme] { [Theme.system()] + Theme.all + custom.filter { $0.name != Theme.systemName } }

    static func addOrUpdate(_ theme: Theme) {
        var dicts = (d.array(forKey: key) as? [[String: Any]]) ?? []
        dicts.removeAll { ($0["name"] as? String) == theme.name }
        dicts.append(theme.toDict())
        d.set(dicts, forKey: key)
    }
}

/// The theme button and the View ▸ Theme menu: the editor's theme, then the preview's.
enum ThemeMenu {
    static func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        func heading(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        heading("Editor")
        for (i, theme) in ThemeStore.allThemes().enumerated() {
            let item = NSMenuItem(title: theme.name, action: Selector(("selectTheme:")), keyEquivalent: "")
            item.tag = i
            menu.addItem(item)
        }
        menu.addItem(.separator())
        heading("Preview")
        let same = NSMenuItem(title: "Same as editor", action: Selector(("selectPreviewTheme:")), keyEquivalent: "")
        same.tag = -1
        menu.addItem(same)
        for (i, theme) in ThemeStore.allThemes().enumerated() {
            let item = NSMenuItem(title: theme.name, action: Selector(("selectPreviewTheme:")), keyEquivalent: "")
            item.tag = i
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Edit Themes…", action: #selector(AppDelegate.editThemes(_:)), keyEquivalent: ""))
    }
}

/// Width of the centered writing column.
enum EditorSize: CGFloat, CaseIterable {
    case small  = 550
    case medium = 650
    case large  = 800

    var title: String {
        switch self {
        case .small:  return "Small"
        case .medium: return "Medium"
        case .large:  return "Large"
        }
    }
    var columnWidth: CGFloat { rawValue }
}
