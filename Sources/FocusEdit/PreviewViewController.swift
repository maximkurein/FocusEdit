import AppKit
import WebKit

/// Live HTML preview shown beside the text (View ▸ Show Preview, ⇧⌘P).
/// The page is loaded once and only its body is replaced while typing, so the
/// scroll position stays where it is.
final class PreviewViewController: NSViewController, WKNavigationDelegate {

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        // The page never needs scripts of its own (the app updates it with
        // evaluateJavaScript, which this does not affect), so a document can't run any.
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = WKWebView(frame: .zero, configuration: config)
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
        webView.evaluateJavaScript("document.body.innerHTML = \(json)[0];") { [weak self] _, error in
            // Could not update in place: load the whole page again.
            guard error != nil, let self, let dark = self.loadedDark else { return }
            self.ready = false
            self.webView.loadHTMLString(MarkdownToHTML.document(markdown, dark: dark), baseURL: nil)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        inject(latest) // anything typed while the page was loading
    }

    /// Only the app's own page load (about:blank) is allowed; every other navigation is
    /// cancelled, and a clicked web link opens in the browser instead.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        if url.scheme?.lowercased() == "about" {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }
}
