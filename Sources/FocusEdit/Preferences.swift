import AppKit

/// Font family choice for the editor (display-only; files stay plain text).
enum FontKind: Int, CaseIterable {
    case system, monospace, serif

    var title: String {
        switch self {
        case .system:    return "System"
        case .monospace: return "Monospace"
        case .serif:     return "Serif"
        }
    }

    func font(ofSize size: CGFloat) -> NSFont {
        switch self {
        case .system:    return .systemFont(ofSize: size)
        case .monospace: return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .serif:     return NSFont(name: "Georgia", size: size) ?? .systemFont(ofSize: size)
        }
    }
}

/// Thin typed wrapper over UserDefaults so the chosen theme, size, sound,
/// highlighting mode and font survive relaunches.
enum Preferences {
    private static let d = UserDefaults.standard

    enum Key {
        static let theme = "theme.name"
        static let editorSize = "editor.size"
        static let sounds = "sounds.enabled"
        static let focusMode = "focus.mode"
        static let fontKind = "font.kind"
        static let fontSize = "font.size"
        static let libraryPath = "library.path"
        static let showLibrary = "show.library"
        static let showOutline = "show.outline"
        static let showStatistics = "show.statistics"
        static let autoPairing = "edit.autoPairing"
        static let autocomplete = "edit.autocomplete"
        static let vimMode = "edit.vimMode"
        static let wordGoal = "session.wordGoal"
        static let liveMarkdown = "edit.liveMarkdown"
    }

    /// Hide Markdown marks away from the cursor (on unless turned off).
    static var liveMarkdown: Bool {
        get { d.object(forKey: Key.liveMarkdown) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.liveMarkdown) }
    }

    /// Words to write in a session; 0 = no goal.
    static var wordGoal: Int {
        get { max(0, d.integer(forKey: Key.wordGoal)) }
        set { d.set(max(0, newValue), forKey: Key.wordGoal) }
    }

    static var vimMode: Bool {
        get { d.bool(forKey: Key.vimMode) }
        set { d.set(newValue, forKey: Key.vimMode) }
    }

    static var autoPairing: Bool {
        get { d.object(forKey: Key.autoPairing) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.autoPairing) }
    }
    static var autocomplete: Bool {
        get { d.object(forKey: Key.autocomplete) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.autocomplete) }
    }

    static var libraryPath: String? {
        get { d.string(forKey: Key.libraryPath) }
        set { d.set(newValue, forKey: Key.libraryPath) }
    }
    static var showLibrary: Bool {
        get { d.bool(forKey: Key.showLibrary) }
        set { d.set(newValue, forKey: Key.showLibrary) }
    }
    static var showOutline: Bool {
        get { d.bool(forKey: Key.showOutline) }
        set { d.set(newValue, forKey: Key.showOutline) }
    }
    static var showStatistics: Bool {
        get { d.object(forKey: Key.showStatistics) as? Bool ?? true }
        set { d.set(newValue, forKey: Key.showStatistics) }
    }

    static var themeName: String {
        get { d.string(forKey: Key.theme) ?? Theme.light.name }
        set { d.set(newValue, forKey: Key.theme) }
    }

    static var editorSize: EditorSize {
        get {
            let raw = d.object(forKey: Key.editorSize) as? Double
            return raw.flatMap { EditorSize(rawValue: CGFloat($0)) } ?? .medium
        }
        set { d.set(Double(newValue.rawValue), forKey: Key.editorSize) }
    }

    static var soundsEnabled: Bool {
        get { d.bool(forKey: Key.sounds) }
        set { d.set(newValue, forKey: Key.sounds) }
    }

    static var focusMode: FocusTextView.FocusMode {
        get { FocusTextView.FocusMode(rawValue: d.object(forKey: Key.focusMode) as? Int ?? FocusTextView.FocusMode.paragraph.rawValue) ?? .paragraph }
        set { d.set(newValue.rawValue, forKey: Key.focusMode) }
    }

    static var fontKind: FontKind {
        get { FontKind(rawValue: d.integer(forKey: Key.fontKind)) ?? .monospace }
        set { d.set(newValue.rawValue, forKey: Key.fontKind) }
    }

    static var fontSize: CGFloat {
        get {
            let v = d.object(forKey: Key.fontSize) as? Double ?? 16
            return CGFloat(min(max(v, 10), 40))
        }
        set { d.set(Double(newValue), forKey: Key.fontSize) }
    }

    /// Resolve the stored theme name to one of the presets.
    static func resolvedTheme() -> Theme {
        ThemeStore.allThemes().first { $0.name == themeName } ?? .light
    }
}
