import Foundation

/// A writing session: words written since the document was opened (or the goal
/// was set), and the time actually spent writing. Mirrors `windows/src/session.ts`;
/// times are milliseconds, as there.
struct Session {
    /// Typing counts as writing for this long after the last change.
    static let idleMs = 30_000

    private var baseline = 0
    private var words = 0
    private(set) var activeMs = 0
    private var lastActivity = Int.min / 2
    private var lastTick: Int?

    static func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    /// Start over from a document with `words` words in it.
    mutating func reset(words: Int, now: Int = Session.nowMs()) {
        baseline = words
        self.words = words
        activeMs = 0
        lastActivity = Int.min / 2
        lastTick = now
    }

    /// The text changed: it now has `words` words.
    mutating func note(words: Int, now: Int = Session.nowMs()) {
        self.words = words
        lastActivity = now
    }

    /// Call about once a second; adds the time since the last call if writing is going on.
    mutating func tick(now: Int = Session.nowMs()) {
        let since = lastTick.map { now - $0 } ?? 0
        lastTick = now
        // A long gap means the computer slept, not that the user wrote: ignore it.
        if now - lastActivity <= Self.idleMs, since > 0, since <= 5000 { activeMs += since }
    }

    /// Words added since the start (never negative: deleting does not count against you).
    var written: Int { max(0, words - baseline) }

    /// 0…1
    func progress(goal: Int) -> Double {
        goal > 0 ? min(1, Double(written) / Double(goal)) : 0
    }

    /// Words as the word count shows them: runs of non-space characters.
    static func countWords(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            let space = CharacterSet.whitespacesAndNewlines.contains(scalar)
            if !space, !inWord { count += 1 }
            inWord = !space
        }
        return count
    }

    /// 75 s → "1:15", 3725 s → "1:02:05"
    static func formatDuration(ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = total % 3600 / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func plural(_ n: Int) -> String { n == 1 ? "1 word" : "\(n) words" }
}
