import AppKit

/// Generates the app icon programmatically (no image assets to ship). The mark
/// is the editor's own idea: several dimmed text lines with one bright, focused
/// line carrying an amber caret — "focus writing".
enum IconFactory {

    static func writeIconSet(to directory: String) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let specs: [(String, Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in specs {
            guard let data = pngData(px: px) else { continue }
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".png")
            try? data.write(to: url)
        }
    }

    private static func pngData(px: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: px, height: px)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(size: CGFloat(px))
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func draw(size s: CGFloat) {
        let rect = NSRect(x: 0, y: 0, width: s, height: s)

        // Rounded-rect background with a vertical graphite gradient.
        let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2237, yRadius: s * 0.2237)
        bg.addClip()
        NSGradient(starting: NSColor(srgbRed: 0.24, green: 0.26, blue: 0.30, alpha: 1),
                   ending:   NSColor(srgbRed: 0.13, green: 0.14, blue: 0.17, alpha: 1))?
            .draw(in: rect, angle: -90)

        // Text lines.
        let widths: [CGFloat] = [0.92, 0.78, 1.0, 0.60, 0.84]
        let focusIndex = 2
        let blockW = s * 0.50
        let left = (s - blockW) / 2
        let lineH = s * 0.052
        let step = s * 0.108
        let totalH = step * CGFloat(widths.count - 1)

        let dim = NSColor(srgbRed: 0.42, green: 0.46, blue: 0.52, alpha: 1)
        let bright = NSColor(white: 0.94, alpha: 1)
        let amber = NSColor(srgbRed: 0.91, green: 0.66, blue: 0.24, alpha: 1)

        for (i, frac) in widths.enumerated() {
            let yCenter = s / 2 + totalH / 2 - step * CGFloat(i)
            let w = blockW * frac
            let line = NSBezierPath(
                roundedRect: NSRect(x: left, y: yCenter - lineH / 2, width: w, height: lineH),
                xRadius: lineH / 2, yRadius: lineH / 2)
            (i == focusIndex ? bright : dim).setFill()
            line.fill()

            if i == focusIndex {
                let caretH = lineH * 1.9
                let caret = NSBezierPath(
                    roundedRect: NSRect(x: left + w + s * 0.022, y: yCenter - caretH / 2,
                                        width: s * 0.040, height: caretH),
                    xRadius: s * 0.012, yRadius: s * 0.012)
                amber.setFill()
                caret.fill()
            }
        }
    }
}
