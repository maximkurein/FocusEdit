import AppKit
import UniformTypeIdentifiers
import WebKit

/// Excalidraw boards: free drawing with a hand-drawn look, in `.excalidraw` files.
///
/// The board is Excalidraw 0.18.1 (MIT) built into `Resources/excalidraw/` (`board.js`,
/// `board.css`, `fonts/`; how to rebuild it is in that folder's README). It runs in a
/// web view, offline: the page and its fonts are served from the app through the
/// `fe-board:` scheme (`BoardScheme`), because a `file:` page may not fetch its fonts.
/// The page's API is `window.__feBoard` (load, save, fromMermaid, svg, png, setTheme)
/// and it reports unsaved changes with the `boardChanged` message.
///
/// A Mermaid diagram becomes an editable drawing with Edit ▸ Diagram ▸ Open in
/// Excalidraw (or the picture's right-click menu): a new board with its blocks and
/// arrows as shapes (@excalidraw/mermaid-to-excalidraw).
enum Board {

    static let folder = "excalidraw"
    /// Info.plist type name of `.excalidraw` files.
    static let typeName = "Excalidraw Board"

    /// `Resources/excalidraw` of the app, or of the repository for `swift build` runs.
    static var folderURL: URL? {
        guard let url = Diagrams.resourceURL(folder) else { return nil }
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) ? url : nil
    }

    static var isAvailable: Bool { folderURL != nil }

    /// A new, untitled board, optionally drawn from a Mermaid diagram.
    @discardableResult
    static func open(mermaid: String? = nil) -> BoardDocument? {
        guard isAvailable else {
            NSSound.beep()
            return nil
        }
        let doc = BoardDocument()
        doc.fileType = typeName
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        if let mermaid { doc.addMermaid(mermaid) }
        return doc
    }
}

/// Serves `fe-board://app/<path>` from `Resources/excalidraw`.
final class BoardScheme: NSObject, WKURLSchemeHandler {
    static let scheme = "fe-board"
    static let start = URL(string: "fe-board://app/index.html")!

    private static let types: [String: String] = [
        "html": "text/html", "js": "text/javascript", "css": "text/css", "woff2": "font/woff2",
        "json": "application/json", "svg": "image/svg+xml", "png": "image/png", "txt": "text/plain",
    ]

    /// The file for a request, only inside the board folder.
    static func file(for url: URL?, in root: URL) -> URL? {
        guard let url, url.scheme == scheme else { return nil }
        let path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        guard !path.isEmpty, !path.split(separator: "/").contains("..") else { return nil }
        let file = root.appendingPathComponent(path).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path + "/") else { return nil }
        return file
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let root = Board.folderURL, let file = Self.file(for: task.request.url, in: root),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let type = Self.types[file.pathExtension.lowercased()] ?? "application/octet-stream"
        let response = HTTPURLResponse(url: task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type, "Content-Length": "\(data.count)",
                                                      "Access-Control-Allow-Origin": "*"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// A `.excalidraw` file (Excalidraw's JSON).
@objc(BoardDocument)
final class BoardDocument: NSDocument {

    /// The JSON read from disk, until the page has it; then what the page last saved.
    private var json = ""
    fileprivate weak var board: BoardWindowController?
    /// Mermaid to add once the page is ready.
    private var pendingMermaid: [String] = []

    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        let controller = BoardWindowController(document: self)
        board = controller
        addWindowController(controller)
    }

    override func read(from data: Data, ofType typeName: String) throws {
        json = String(decoding: data, as: UTF8.self)
        board?.load(json)
    }

    override func data(ofType typeName: String) throws -> Data {
        Data(json.utf8)
    }

    /// The page holds the drawing: fetch it before NSDocument writes the file.
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        guard let board else {
            super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
            return
        }
        board.sceneJSON { [weak self] text in
            guard let self else { return }
            if let text { self.json = text }
            super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
        }
    }

    /// What the page starts with.
    var initialJSON: String { json }

    func addMermaid(_ source: String) {
        if let board, board.isReady { board.addMermaid(source) } else { pendingMermaid.append(source) }
    }

    fileprivate func takePendingMermaid() -> [String] {
        defer { pendingMermaid = [] }
        return pendingMermaid
    }

    fileprivate func boardChanged(_ dirty: Bool) {
        if dirty, !isDocumentEdited { updateChangeCount(.changeDone) }
        if !dirty, isDocumentEdited { updateChangeCount(.changeCleared) }
    }
}

/// The board's window: the Excalidraw page filling it.
final class BoardWindowController: NSWindowController, WKNavigationDelegate, WKScriptMessageHandler,
    NSMenuItemValidation {

    private let web: WKWebView
    private(set) var isReady = false
    private var appearanceObserver: NSKeyValueObservation?

    /// The message handler must not retain this controller.
    private final class Bridge: NSObject, WKScriptMessageHandler {
        weak var owner: BoardWindowController?
        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            owner?.userContentController(c, didReceive: message)
        }
    }
    private let bridge = Bridge()

    init(document: BoardDocument) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BoardScheme(), forURLScheme: BoardScheme.scheme)
        config.userContentController.add(bridge, name: "boardChanged")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1100, height: 760), configuration: config)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = web
        window.minSize = NSSize(width: 520, height: 400)
        window.tabbingMode = .preferred
        super.init(window: window)
        bridge.owner = self
        shouldCascadeWindows = true
        web.navigationDelegate = self
        window.center()
        web.load(URLRequest(url: BoardScheme.start))
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyTheme() }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var boardDocument: BoardDocument? { document as? BoardDocument }

    // MARK: Page

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        applyTheme()
        load(boardDocument?.initialJSON ?? "")
        isReady = true
        for source in boardDocument?.takePendingMermaid() ?? [] { addMermaid(source) }
        window?.makeFirstResponder(web)
    }

    /// Links in a drawing open in the browser; the page itself never navigates away.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.scheme == BoardScheme.scheme || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" {
            return decisionHandler(.allow)
        }
        if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme ?? "") {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "boardChanged" { boardDocument?.boardChanged((message.body as? Bool) ?? false) }
    }

    /// `__feBoard.function(argument)`, awaited; `done` gets its result (nil on failure).
    private func call(_ function: String, _ argument: Any? = nil, then done: ((Any?) -> Void)? = nil) {
        let body = argument == nil
            ? "return await window.__feBoard.\(function)();"
            : "return await window.__feBoard.\(function)(value);"
        web.callAsyncJavaScript(body, arguments: argument.map { ["value": $0] } ?? [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): done?(value)
            case .failure: done?(nil)
            }
        }
    }

    func load(_ json: String) {
        call("load", json)
    }

    func addMermaid(_ source: String) {
        call("fromMermaid", source) { [weak self] value in
            guard let r = value as? [String: Any], (r["ok"] as? Bool) != true else { return }
            let alert = NSAlert()
            alert.messageText = "This diagram could not be turned into a drawing"
            alert.informativeText = (r["error"] as? String) ?? ""
            if let window = self?.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
        }
    }

    func sceneJSON(_ done: @escaping (String?) -> Void) {
        call("save") { done($0 as? String) }
    }

    private func applyTheme() {
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        call("setTheme", dark)
    }

    // MARK: Export (File menu while a board is in front)

    @objc func exportBoardAsPNG(_ sender: Any?) {
        call("png") { [weak self] value in
            guard let base64 = value as? String, let data = Data(base64Encoded: base64) else { NSSound.beep(); return }
            self?.saveExport(data, type: .png)
        }
    }

    @objc func exportBoardAsSVG(_ sender: Any?) {
        call("svg") { [weak self] value in
            guard let svg = value as? String else { NSSound.beep(); return }
            self?.saveExport(Data(svg.utf8), type: .svg)
        }
    }

    @objc func copyBoardAsPNG(_ sender: Any?) {
        call("png") { value in
            guard let base64 = value as? String, let data = Data(base64Encoded: base64) else { NSSound.beep(); return }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setData(data, forType: .png)
            if let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
        }
    }

    private func saveExport(_ data: Data, type: UTType) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        let base = (document as? NSDocument)?.displayName ?? "Board"
        panel.nameFieldStringValue = (base as NSString).deletingPathExtension + "." + (type.preferredFilenameExtension ?? "")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) } catch { NSAlert(error: error).runModal() }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool { isReady }
}
