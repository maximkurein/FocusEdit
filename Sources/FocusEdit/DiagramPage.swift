import AppKit
import WebKit

/// A page drawn off screen with its Mermaid diagrams turned into plain SVG pictures:
/// for Export as HTML, Copy as HTML and printing the preview (a .mmd file prints its
/// picture). Black on white, like the other exports.
///
/// The page loads the document, draws every diagram, waits until the last one is
/// ready (at most `timeout`), then calls `__feDiagrams.freeze()`. The web view stays
/// with the page so it can be printed.
final class DiagramPage: NSObject, WKNavigationDelegate {

    /// Pages being drawn or printed; each removes itself when it is done.
    private static var alive: Set<DiagramPage> = []

    let markdown: String
    let web: WKWebView
    private let done: (DiagramPage, String?) -> Void
    private var started = Date()
    private let timeout: TimeInterval = 15

    /// Is there anything to draw? Otherwise the export can stay as it was.
    static func hasDiagrams(_ markdown: String) -> Bool {
        Diagrams.isAvailable && MarkdownToHTML.render(markdown).contains("class=\"language-mermaid\"")
    }

    /// Draws `markdown` and hands back the body with pictures (nil if it failed).
    static func render(_ markdown: String, width: CGFloat = 820,
                       then done: @escaping (DiagramPage, String?) -> Void) {
        let page = DiagramPage(markdown: markdown, width: width, done: done)
        alive.insert(page)
        page.load()
    }

    /// The whole exported document, with the diagrams drawn when there are any.
    static func exportDocument(_ markdown: String, then done: @escaping (String) -> Void) {
        guard hasDiagrams(markdown) else {
            done(MarkdownToHTML.document(markdown, dark: false))
            return
        }
        render(markdown) { page, body in
            done(MarkdownToHTML.document(markdown, dark: false, body: body))
            page.finish()
        }
    }

    private init(markdown: String, width: CGFloat, done: @escaping (DiagramPage, String?) -> Void) {
        self.markdown = markdown
        self.done = done
        let config = WKWebViewConfiguration()
        Diagrams.install(in: config.userContentController)
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 1100), configuration: config)
        super.init()
        web.navigationDelegate = self
    }

    private func load() {
        started = Date()
        web.loadHTMLString(MarkdownToHTML.document(markdown, dark: false), baseURL: nil)
    }

    /// Let the page go (after the export or the print job is done with its web view).
    func finish() {
        web.navigationDelegate = nil
        Self.alive.remove(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let script = Diagrams.configureScript(PageColors.plain(dark: false)) + Diagrams.refreshScript
        webView.evaluateJavaScript(script) { [weak self] _, _ in self?.waitForDrawings() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        done(self, nil)
    }

    /// Only the page itself loads; nothing in it navigates anywhere.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme?.lowercased() == "about" ? .allow : .cancel)
    }

    private func waitForDrawings() {
        web.evaluateJavaScript("window.__feDiagrams ? window.__feDiagrams.pending() : -1") { [weak self] value, _ in
            guard let self else { return }
            let pending = (value as? NSNumber)?.intValue ?? -1
            if pending > 0, Date().timeIntervalSince(self.started) < self.timeout {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitForDrawings() }
                return
            }
            self.web.evaluateJavaScript("window.__feDiagrams ? window.__feDiagrams.freeze() : null") { value, _ in
                self.done(self, value as? String)
            }
        }
    }
}

/// Prints (or saves as PDF) the preview page instead of the source text: a .mmd file's
/// picture, or File ▸ Export Preview as PDF… for a document with diagrams.
enum PagePrint {

    /// Keeps the page until the print sheet is closed.
    private final class Job: NSObject {
        let page: DiagramPage
        init(page: DiagramPage) { self.page = page }
        static var running: Set<Job> = []

        @objc func printDone(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            page.finish()
            Job.running.remove(self)
        }
    }

    /// `pdf` nil shows the print panel; otherwise the pages are saved to that file.
    static func run(markdown: String, window: NSWindow?, pdf: URL? = nil) {
        DiagramPage.render(markdown) { page, _ in
            let info = NSPrintInfo.shared.copy() as! NSPrintInfo
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = true
            info.isVerticallyCentered = false
            if let pdf {
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = pdf
            }
            let op = page.web.printOperation(with: info)
            op.showsPrintPanel = pdf == nil
            op.showsProgressPanel = false
            // An off-screen web view prints blank pages unless its print view has a size.
            op.view?.frame = page.web.bounds
            let job = Job(page: page)
            Job.running.insert(job)
            if let window {
                op.runModal(for: window, delegate: job,
                            didRun: #selector(Job.printDone(_:success:contextInfo:)), contextInfo: nil)
            } else {
                op.run()
                job.printDone(op, success: true, contextInfo: nil)
            }
        }
    }
}
