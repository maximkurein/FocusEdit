import AppKit

/// Word completion for the editor. Suggests words already used in the document
/// (most frequent first), then falls back to the system spelling dictionary.
/// Fountain documents also get scene-heading prefixes and known character cues.
final class CompletionEngine {

    var kind: DocumentKind = .plain {
        didSet { dirty = true }
    }

    private var text = ""
    private var dirty = true
    private var counts: [String: Int] = [:]     // lowercased word → uses
    private var forms: [String: String] = [:]   // lowercased word → spelling as written
    private var characters: [String] = []       // Fountain character cues, in order of use

    private static let sceneHeadings = ["INT. ", "EXT. ", "INT./EXT. ", "EST. "]

    func update(text: String) {
        self.text = text
        dirty = true
    }

    /// The characters to append after `prefix` for the best suggestion, or nil.
    func suffix(forPrefix prefix: String, linePrefix: String) -> String? {
        guard let best = best(forPrefix: prefix, linePrefix: linePrefix),
              best.count > prefix.count else { return nil }
        return String(best.dropFirst(prefix.count))
    }

    /// Full candidates for the completion list (⌥Esc).
    func completions(forPrefix prefix: String, linePrefix: String, limit: Int = 8) -> [String] {
        reindexIfNeeded()
        var out: [String] = []
        func add(_ s: String) { if !out.contains(s) { out.append(s) } }
        fountainCandidates(prefix: prefix, linePrefix: linePrefix).forEach(add)
        documentCandidates(prefix: prefix).forEach(add)
        if out.count < limit { dictionaryCandidates(prefix: prefix).forEach(add) }
        return Array(out.prefix(limit))
    }

    // MARK: Ranking

    private func best(forPrefix prefix: String, linePrefix: String) -> String? {
        reindexIfNeeded()
        if let f = fountainCandidates(prefix: prefix, linePrefix: linePrefix).first { return f }
        guard prefix.count >= 2 else { return nil }
        if let d = documentCandidates(prefix: prefix).first { return d }
        guard prefix.count >= 3 else { return nil }
        return dictionaryCandidates(prefix: prefix).first
    }

    private func documentCandidates(prefix: String) -> [String] {
        let p = prefix.lowercased()
        return counts.keys
            .filter { $0.count > p.count + 1 && $0.hasPrefix(p) }
            .sorted { (counts[$0] ?? 0, -$0.count) > (counts[$1] ?? 0, -$1.count) }
            .map { adapt(forms[$0] ?? $0, to: prefix) }
    }

    private func dictionaryCandidates(prefix: String) -> [String] {
        let checker = NSSpellChecker.shared
        let cyrillic = prefix.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let language: String? = (cyrillic && checker.availableLanguages.contains("ru")) ? "ru" : nil
        let range = NSRange(location: 0, length: (prefix as NSString).length)
        let words = checker.completions(forPartialWordRange: range, in: prefix,
                                        language: language, inSpellDocumentWithTag: 0) ?? []
        return words.filter { $0.count > prefix.count + 1 }.map { adapt($0, to: prefix) }
    }

    private func fountainCandidates(prefix: String, linePrefix: String) -> [String] {
        guard kind == .fountain,
              linePrefix.trimmingCharacters(in: .whitespaces) == prefix,
              prefix == prefix.uppercased(),
              prefix.rangeOfCharacter(from: .letters) != nil else { return [] }
        let headings = Self.sceneHeadings.filter { $0.hasPrefix(prefix) && $0.count > prefix.count }
        let names = characters.filter { $0.hasPrefix(prefix) && $0.count > prefix.count }
        return headings + names
    }

    /// Keep what the user typed (its case) and append the rest of the candidate.
    private func adapt(_ candidate: String, to prefix: String) -> String {
        guard candidate.count >= prefix.count else { return candidate }
        return prefix + candidate.dropFirst(prefix.count)
    }

    // MARK: Index

    private func reindexIfNeeded() {
        guard dirty else { return }
        dirty = false
        counts = [:]
        forms = [:]
        characters = []

        for token in text.split(whereSeparator: { !Self.isWordCharacter($0) }) where token.count >= 4 {
            let word = String(token)
            let key = word.lowercased()
            counts[key, default: 0] += 1
            forms[key] = word
        }

        guard kind == .fountain else { return }
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.count > 1, t == t.uppercased(), t.rangeOfCharacter(from: .letters) != nil,
                  !t.hasSuffix("TO:"), !Self.isSceneHeading(t) else { continue }
            let name = t.split(separator: "(").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? t
            if !name.isEmpty, seen.insert(name).inserted { characters.append(name) }
        }
    }

    static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "'" || c == "’" || c == "-"
    }

    private static func isSceneHeading(_ line: String) -> Bool {
        let upper = line.uppercased()
        return ["INT", "EXT", "EST", "I/E"].contains { upper.hasPrefix($0) }
            || (line.hasPrefix(".") && !line.hasPrefix(".."))
    }
}
