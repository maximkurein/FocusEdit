import AppKit
import WebKit

/// A separate live HTML-preview window for the current Markdown document.
final class PreviewWindowController: NSWindowController {

    private let webView = WKWebView()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Preview"
        self.init(window: window)
        window.contentView = webView
        window.center()
    }

    func update(markdown: String, dark: Bool) {
        let html = MarkdownToHTML.document(markdown, dark: dark)
        webView.loadHTMLString(html, baseURL: nil)
    }
}
