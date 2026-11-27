import Foundation
import WebKit

/// Mermaid diagrams in the preview: ```mermaid blocks are drawn as pictures.
///
/// The scripts are files beside the app, not part of a document: `mermaid.min.js`
/// (Mermaid 12.3.0, MIT, `Resources/mermaid-LICENSE.txt`) and `diagrams.js`, which
/// turns each block into a figure that fits the page, zooms and opens full size.
/// `package.sh` copies them from `Resources/` into the bundle; a `swift build` run
/// reads them from the repository. Without them the blocks stay code, as before.
enum Diagrams {

    static let mermaidFile = "mermaid.min.js"
    static let scriptFile = "diagrams.js"

    /// Where the scripts are: the app's Resources, or `Resources/` of the repository
    /// for `.build/debug/FocusEdit` (a few folders above the binary).
    static func resourceURL(_ name: String) -> URL? {
        let fm = FileManager.default
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name), fm.fileExists(atPath: url.path) {
            return url
        }
        var dir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            guard let current = dir else { break }
            let url = current.appendingPathComponent("Resources").appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
            dir = current.deletingLastPathComponent()
        }
        return nil
    }

    private static func load(_ name: String) -> String? {
        guard let url = resourceURL(name) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Read once; every preview page gets the same scripts.
    static let mermaidSource: String? = load(mermaidFile)
    static let scriptSource: String? = load(scriptFile)

    static var isAvailable: Bool { mermaidSource != nil && scriptSource != nil }

    /// Added to each preview web view; they run on every page it loads.
    static func install(in controller: WKUserContentController) {
        guard let mermaid = mermaidSource, let script = scriptSource else { return }
        controller.addUserScript(WKUserScript(source: mermaid, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    }

    /// The page's colours for the drawings; run once after each page load.
    static func configureScript(_ colors: PageColors) -> String {
        let object: [String: Any] = [
            "dark": colors.schemeDark,
            "background": colors.background,
            "foreground": colors.foreground,
            "muted": colors.muted,
            "accent": colors.accent,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return "window.__feDiagrams && window.__feDiagrams.configure(\(json));"
    }

    /// Draw the blocks in the body; run after every body replacement.
    /// A failure here must not make the preview reload the page (see `inject`).
    static let refreshScript = "try { window.__feDiagrams && window.__feDiagrams.refresh(); } catch (e) {}"

    /// Closes the full size view, if one is open.
    static let closeScript = "try { window.__feDiagrams && window.__feDiagrams.close(); } catch (e) {}"
}
