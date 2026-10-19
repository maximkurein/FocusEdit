import AppKit
import UniformTypeIdentifiers

/// Make FocusEdit the default app for plain text (.txt) and RTF (.rtf).
/// Only the copy in /Applications may claim them: binding .txt to a build in
/// .build/ would break as soon as that folder is rebuilt or deleted.
enum DefaultEditor {

    static let contentTypes: [UTType] = [.plainText, .rtf]

    static var isInstalledCopy: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    /// Ask Launch Services to use this app; `done` gets one error line per failed type.
    static func claim(done: @escaping ([String]) -> Void) {
        var errors: [String] = []
        func next(_ remaining: ArraySlice<UTType>) {
            guard let type = remaining.first else { return done(errors) }
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type) { error in
                DispatchQueue.main.async {
                    if let error {
                        errors.append(".\(type.preferredFilenameExtension ?? type.identifier): \(error.localizedDescription)")
                    }
                    next(remaining.dropFirst())
                }
            }
        }
        next(contentTypes[...])
    }

    /// The app currently opening each type, for the confirmation message.
    static func currentHandlers() -> [String] {
        contentTypes.map { type in
            let app = NSWorkspace.shared.urlForApplication(toOpen: type)?.deletingPathExtension().lastPathComponent ?? "none"
            return ".\(type.preferredFilenameExtension ?? type.identifier) → \(app)"
        }
    }

    /// Menu action: confirm, claim, report.
    static func runInteractively() {
        guard isInstalledCopy else {
            alert("Install FocusEdit first",
                  "Only the copy in Applications can become the default editor. Run ./install.sh, then use this command in that copy.")
            return
        }
        claim { errors in
            if errors.isEmpty {
                alert("FocusEdit is now the default editor",
                      "Double-clicking .txt and .rtf files opens them in FocusEdit.\n\n" + currentHandlers().joined(separator: "\n"))
            } else {
                alert("Could not change every default", errors.joined(separator: "\n"))
            }
        }
    }

    /// `FocusEdit --make-default`: claim the types without UI, print the result, exit.
    static func runFromCommandLine() -> Int32 {
        guard isInstalledCopy else {
            print("make-default: run the copy in /Applications (\(Bundle.main.bundleURL.path) is not)")
            return 1
        }
        var result: [String]?
        claim { result = $0 }
        while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        for line in currentHandlers() { print("make-default: \(line)") }
        for error in result ?? [] { print("make-default: failed \(error)") }
        return (result ?? []).isEmpty ? 0 : 1
    }

    private static func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
