import AppKit
import WebKit

/// Live HTML preview shown beside the text (View ▸ Show Preview, ⇧⌘P).
/// The page is loaded once and only its body is replaced while typing, so the
/// scroll position stays where it is.
final class PreviewViewController: NSViewController, WKNavigationDelegate {

    private lazy var webView: WKWebView = {
        let web = WKWebView()
        web.navigationDelegate = self
        return web
    }()

    private var loadedDark: Bool?
    private var ready = false
    private var latest = ""

    override func loadView() {
        view = webView
    }

    func update(markdown: String, dark: Bool) {
        latest = markdown
        if loadedDark != dark {
            // First show, or the theme changed: load the themed page.
            loadedDark = dark
            ready = false
            webView.loadHTMLString(MarkdownToHTML.document(markdown, dark: dark), baseURL: nil)
        } else if ready {
            inject(markdown)
        }
    }

    private func inject(_ markdown: String) {
        let html = MarkdownToHTML.render(markdown)
        guard let data = try? JSONSerialization.data(withJSONObject: [html]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("document.body.innerHTML = \(json)[0];", completionHandler: nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        inject(latest) // anything typed while the page was loading
    }

    /// Links open in the browser; the preview itself never navigates away.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.navigationType == .linkActivated else {
            decisionHandler(.allow)
            return
        }
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
