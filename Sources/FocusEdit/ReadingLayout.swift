import AppKit

/// How wide the window should be, and how the editor and the preview share it,
/// so Split opens ready to read and edit. Pure numbers: the window applies them.
enum ReadingLayout {
    /// One pane, including its margins. Two of these side by side is the first Split:
    /// a reading line, not half of a large screen.
    static let comfortablePane: CGFloat = 560

    /// Width of the window the first time Split opens. A wider window is narrowed to this;
    /// a small screen keeps it on screen.
    static func contentWidth(sidebars: CGFloat, screenWidth: CGFloat, current _: CGFloat) -> CGFloat {
        let wanted = sidebars + comfortablePane * 2
        let room = max(800, screenWidth - 16)
        return min(room, wanted)
    }

    /// Editor's width inside the area left for the editor and the preview.
    /// `share` is the editor's part (0.5 splits them evenly). A saved share is kept;
    /// only an extreme one is pulled back so neither pane collapses.
    static func editorWidth(available: CGFloat, share: CGFloat) -> CGFloat {
        guard available > 1 else { return 0 }
        let share = min(0.8, max(0.2, share))
        let editor = (available * share).rounded()
        let floor = min(320, available / 2)
        if available >= 640 {
            return min(max(editor, 320), available - 320)
        }
        return min(max(editor, floor), available - floor)
    }
}

/// The last look of one file: view, how the panes were split, and the window size.
struct DocumentAppearance: Equatable {
    var mode: String
    var editorShare: Double
    var contentWidth: Double
    var contentHeight: Double
    /// Split has been opened for this file, so the next time uses the saved sizes
    /// instead of the automatic ones.
    var seenSplit: Bool

    init(mode: String, editorShare: Double, contentWidth: Double, contentHeight: Double, seenSplit: Bool) {
        self.mode = mode
        self.editorShare = editorShare
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
        self.seenSplit = seenSplit
    }

    fileprivate var dictionary: [String: Any] {
        ["mode": mode, "share": editorShare, "width": contentWidth, "height": contentHeight,
         "seenSplit": seenSplit]
    }

    fileprivate init?(_ raw: [String: Any]) {
        guard let mode = raw["mode"] as? String,
              let share = raw["share"] as? Double,
              let width = raw["width"] as? Double,
              let height = raw["height"] as? Double else { return nil }
        self.mode = mode
        editorShare = share
        contentWidth = width
        contentHeight = height
        seenSplit = raw["seenSplit"] as? Bool ?? false
    }
}

/// Remembers each file's appearance in UserDefaults, most recent last, capped so the
/// list cannot grow without limit.
enum DocumentAppearanceStore {
    private static let key = "document.appearance.v2"
    private static let limit = 80

    static func usable(width: CGFloat, height: CGFloat) -> Bool {
        width >= 800 && height >= 480 && width <= 6000 && height <= 4000
    }

    static func load(_ path: String, defaults: UserDefaults = .standard) -> DocumentAppearance? {
        guard let list = defaults.array(forKey: key) as? [[String: Any]] else { return nil }
        guard let raw = list.last(where: { $0["path"] as? String == path }) else { return nil }
        return DocumentAppearance(raw)
    }

    static func save(_ appearance: DocumentAppearance, for path: String, defaults: UserDefaults = .standard) {
        var list = (defaults.array(forKey: key) as? [[String: Any]]) ?? []
        list.removeAll { $0["path"] as? String == path }
        var entry = appearance.dictionary
        entry["path"] = path
        list.append(entry)
        if list.count > limit { list.removeFirst(list.count - limit) }
        defaults.set(list, forKey: key)
    }
}
