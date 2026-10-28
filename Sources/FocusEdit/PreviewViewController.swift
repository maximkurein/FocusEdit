import AppKit
import WebKit

/// Live HTML preview beside the text or alone (View ▸ Preview, ⌥⌘P cycles Edit → Split → Preview).
/// The page is loaded once and only its body is replaced while typing, so the
/// scroll position stays where it is.
final class PreviewViewController: NSViewController, WKNavigationDelegate {

    /// Forwards `copyCode` so the web view does not retain this controller.
    private final class CopyBridge: NSObject, WKScriptMessageHandler {
        weak var owner: PreviewViewController?
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            owner?.copyCode(message.body)
        }
    }

    private let copyBridge = CopyBridge()
    private var webView: WKWebView?

    private var loadedKey: String?
    private var loadedColors = PageColors.plain(dark: false)
    /// The editor's text size; the page follows it without reloading.
    var fontSize: Double = 16 {
        didSet {
            if fontSize != oldValue, ready { applyFontSize() }
        }
    }

    /// Split: the page fills its pane, with the same side margins as the editor.
    /// Preview alone keeps the centred reading measure.
    var fillsPane = false {
        didSet { if fillsPane != oldValue { applyMeasure() } }
    }

    private func applyFontSize() {
        webView?.evaluateJavaScript("document.body.style.fontSize = '\(fontSize)px';", completionHandler: nil)
    }

    private func applyMeasure() {
        guard webView != nil else { return }
        let js = fillsPane
            ? "document.body.style.maxWidth='none'; document.body.style.margin='28px 36px 72px'; document.body.style.padding='0';"
            : "document.body.style.maxWidth='45em'; document.body.style.margin='40px auto'; document.body.style.padding='0 24px';"
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }
    private var ready = false
    private var latest = ""

    /// Called when the reader scrolls the page: 0 is the top, 1 the bottom.
    var onScroll: ((Double) -> Void)?
    private var lastRatio = 0.0
    /// Where the reader is (0 top, 1 bottom), as last read or set.
    var currentRatio: Double { lastRatio }
    /// A scroll asked for while the page was loading, applied when it is ready.
    private var pendingRatio: Double?
    /// The page that was just moved by code ignores its own scrolling for a moment.
    private var quietUntil = Date.distantPast
    private var pollTimer: Timer?

    /// Built on first use, including before `loadView`, so Split can set `fillsPane`
    /// without crashing. Never created from `deinit`.
    @discardableResult
    private func makeWebView() -> WKWebView {
        if let web = webView { return web }
        copyBridge.owner = self
        let config = WKWebViewConfiguration()
        // Markdown is escaped, so a document cannot run a script. JavaScript is on so a
        // click in a code block can copy it; the listener is the app's (installCopy).
        config.userContentController.add(copyBridge, name: "copyCode")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        webView = web
        return web
    }

    override func loadView() {
        view = makeWebView()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollScroll()
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: Scrolling together with the editor

    private static let readScroll = """
        (function () { var m = document.documentElement.scrollHeight - window.innerHeight;
                       return m > 0 ? window.scrollY / m : 0; })();
        """

    /// The page has no scripts of its own, so scrolling is read by asking it.
    private func pollScroll() {
        guard ready, Date() >= quietUntil, !view.isHiddenOrHasHiddenAncestor else { return }
        webView?.evaluateJavaScript(Self.readScroll) { [weak self] value, _ in
            guard let self, Date() >= self.quietUntil, let ratio = value as? Double,
                  abs(ratio - self.lastRatio) > 0.002 else { return }
            self.lastRatio = ratio
            self.onScroll?(ratio)
        }
    }

    /// Put the page at the same relative place as the editor.
    func scroll(toRatio ratio: Double) {
        lastRatio = ratio
        guard ready else { pendingRatio = ratio; return }
        quietUntil = Date().addingTimeInterval(0.25)
        webView?.evaluateJavaScript("""
            (function () { var m = document.documentElement.scrollHeight - window.innerHeight;
                           window.scrollTo(0, Math.max(0, m) * \(ratio)); })();
            """, completionHandler: nil)
    }

    func update(markdown: String, colors: PageColors) {
        latest = markdown
        let key = "\(colors.schemeDark)\(colors.background)\(colors.foreground)\(colors.muted)\(colors.accent)"
        if loadedKey != key {
            loadedKey = key
            loadedColors = colors
            ready = false
            makeWebView().loadHTMLString(
                MarkdownToHTML.document(markdown, dark: colors.schemeDark, fontSize: fontSize, fitted: fillsPane, colors: colors),
                baseURL: nil)
        } else if ready {
            inject(markdown)
        }
    }

    private func inject(_ markdown: String) {
        let html = MarkdownToHTML.render(markdown)
        guard let data = try? JSONSerialization.data(withJSONObject: [html]),
              let json = String(data: data, encoding: .utf8) else { return }
        webView?.evaluateJavaScript("document.body.innerHTML = \(json)[0];") { [weak self] _, error in
            // Could not update in place: load the whole page again.
            guard error != nil, let self else { return }
            self.ready = false
            self.loadedKey = nil
            self.makeWebView().loadHTMLString(
                MarkdownToHTML.document(markdown, dark: self.loadedColors.schemeDark, fontSize: self.fontSize,
                                        fitted: self.fillsPane, colors: self.loadedColors),
                baseURL: nil)
        }
    }

    // MARK: WKNavigationDelegate

    /// Click a fenced code block to copy it. Installed once per page; replacing the
    /// body while typing leaves the listener on `document`.
    private static let copyScript = ##"""
        (function () {
          if (window.__feCopy) return;
          window.__feCopy = true;
          var s = document.createElement('style');
          s.textContent = 'pre{cursor:pointer;position:relative}pre.copied::after{content:"Copied";position:absolute;top:8px;right:10px;font:12px/1.2 -apple-system,system-ui,sans-serif;padding:4px 8px;border-radius:6px;background:rgba(127,127,127,.28)}';
          document.documentElement.appendChild(s);
          document.addEventListener('mouseover', function (e) {
            var t = e.target;
            var pre = t && t.closest && t.closest('pre');
            if (pre && !pre.title) pre.title = 'Click to copy';
          });
          document.addEventListener('click', function (e) {
            var t = e.target;
            if (!t || !t.closest) return;
            if (t.closest('a')) return;
            var pre = t.closest('pre');
            if (!pre) return;
            var sel = window.getSelection();
            if (sel && String(sel).length) return;
            var text = (pre.innerText || '').replace(/\s+$/g, '');
            if (!text) return;
            try { window.webkit.messageHandlers.copyCode.postMessage(text); } catch (err) {}
            pre.classList.add('copied');
            setTimeout(function () { pre.classList.remove('copied'); }, 800);
          });
        })();
        """##

    private func installCopy() {
        webView?.evaluateJavaScript(Self.copyScript, completionHandler: nil)
    }

    fileprivate func copyCode(_ body: Any) {
        guard let text = MarkdownToHTML.copyableFence(body as? String ?? "") else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        applyFontSize() // zoomed while the page was loading
        applyMeasure()
        installCopy()
        inject(latest) // anything typed while the page was loading
        if let ratio = pendingRatio {
            pendingRatio = nil
            scroll(toRatio: ratio)
        }
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
