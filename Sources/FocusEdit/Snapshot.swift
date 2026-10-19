import AppKit

/// `FocusEdit <file> --snapshot out.png`: opens the document, types a short
/// demo (list continuation + grey completion), renders the window including
/// the toolbar to PNG and quits. Checks the UI without a screen-recording
/// permission. The demo typing is discarded, never saved.
enum Snapshot {

    /// In snapshot mode the window is invisible and the app never activates,
    /// so it can't steal keyboard focus (or keystrokes) from the user.
    static let isActive = CommandLine.arguments.contains("--snapshot")

    static func schedule(to path: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { typeDemo() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            render(to: path)
            NSDocumentController.shared.documents.forEach { $0.updateChangeCount(.changeCleared) }
            NSApp.terminate(nil)
        }
    }

    private static var window: NSWindow? {
        NSApp.windows.first { $0.contentViewController is MainSplitViewController }
    }

    private static func typeDemo() {
        guard let split = window?.contentViewController as? MainSplitViewController else { return }
        // Optional `--theme Dark`: applied for the shot only, not saved.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--theme"), i + 1 < args.count,
           let theme = ThemeStore.allThemes().first(where: { $0.name.lowercased() == args[i + 1].lowercased() }) {
            split.editor.apply(theme: theme)
        }
        let tv = split.editor.textView
        window?.makeFirstResponder(tv)
        // `--vim`: show the coach after a couple of Normal-mode commands instead of typing.
        if args.contains("--vim") {
            split.editor.showVimForSnapshot(keys: ["g", "g", "j", "j", "j", "2", "w", "c", "i", "w"])
            return
        }
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        let typing = NSRange(location: NSNotFound, length: 0)
        for ch in "\n- First idea" { tv.insertText(String(ch), replacementRange: typing) }
        tv.insertNewline(nil)
        for ch in "Mark" { tv.insertText(String(ch), replacementRange: typing) }
    }

    /// On macOS 26 the scroll view composites its document layer separately,
    /// so caching the window frame alone leaves the editor blank. Draw the
    /// frame (toolbar, sidebars), then the text view's visible area on top,
    /// clipped to the content area below the toolbar.
    private static func render(to path: String) {
        guard let window, let frameView = window.contentView?.superview,
              let frameRep = capture(frameView, frameView.bounds) else {
            print("snapshot: no document window")
            return
        }
        var content = frameView.convert(window.contentLayoutRect, from: nil)
        if frameView.isFlipped { content.origin.y = frameView.bounds.height - content.maxY }

        if let split = window.contentViewController as? MainSplitViewController {
            let tv = split.editor.textView
            if let textRep = capture(tv, tv.visibleRect) {
                var target = tv.convert(tv.visibleRect, to: frameView)
                if frameView.isFlipped { target.origin.y = frameView.bounds.height - target.maxY }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: frameRep)
                NSBezierPath(rect: content).addClip()
                tv.backgroundColor.setFill()            // covers the scroller gutter too
                NSBezierPath(rect: content).fill()
                textRep.draw(in: target)
                // The Vim coach bar sits in the content area too.
                let coach = split.editor.vimCoach
                if !coach.isHidden, let coachRep = capture(coach, coach.bounds) {
                    var rect = coach.convert(coach.bounds, to: frameView)
                    if frameView.isFlipped { rect.origin.y = frameView.bounds.height - rect.maxY }
                    coachRep.draw(in: rect)
                }
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        // `--content`: keep only the area below the toolbar. The toolbar glass
        // can't be captured off-screen in dark appearance.
        var outRep = frameRep
        if CommandLine.arguments.contains("--content") {
            let scale = CGFloat(frameRep.pixelsWide) / frameRep.size.width
            let crop = CGRect(x: content.minX * scale,
                              y: (frameRep.size.height - content.maxY) * scale,
                              width: content.width * scale, height: content.height * scale)
            if let cg = frameRep.cgImage?.cropping(to: crop) { outRep = NSBitmapImageRep(cgImage: cg) }
        }

        guard let png = outRep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: URL(fileURLWithPath: path))
            print("snapshot: wrote \(path) (\(outRep.pixelsWide)×\(outRep.pixelsHigh))")
        } catch {
            print("snapshot: \(error.localizedDescription)")
        }
    }

    private static func capture(_ view: NSView, _ rect: NSRect) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: rep)
        return rep
    }
}
