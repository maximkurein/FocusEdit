import AppKit
import AVFoundation

/// Lightweight typewriter-click service.
///
/// No audio assets ship with the prototype, so the clicks are synthesised at
/// startup (a short noisy, fast-decaying transient — plus a bell tail for the
/// carriage return) and rendered into in-memory WAV data. Each sound keeps a
/// tiny pool of `AVAudioPlayer`s so quick successive keystrokes can overlap.
final class TypewriterSounds {

    enum Key {
        case character   // ordinary key
        case space
        case `return`    // Enter / newline
        case delete      // Backspace
    }

    var enabled = false
    var volume: Float = 0.5 {
        didSet { pools.values.flatMap { $0 }.forEach { $0.volume = volume } }
    }

    private var pools: [Key: [AVAudioPlayer]] = [:]
    private var cursor: [Key: Int] = [:]
    private let poolSize = 4

    init() {
        buildPool(.character, data: Synth.key())
        buildPool(.space,     data: Synth.space())
        buildPool(.return,    data: Synth.carriageReturn())
        buildPool(.delete,    data: Synth.delete())
    }

    /// Classify a text mutation and play the matching click.
    func playForEdit(replacement: String, isDeletion: Bool) {
        guard enabled else { return }
        let key: Key
        if isDeletion {
            key = .delete
        } else if replacement.contains("\n") {
            key = .return
        } else if replacement == " " {
            key = .space
        } else {
            key = .character
        }
        play(key)
    }

    func play(_ key: Key) {
        guard enabled, let players = pools[key], !players.isEmpty else { return }
        let i = (cursor[key] ?? 0) % players.count
        cursor[key] = i + 1
        let player = players[i]
        player.currentTime = 0
        player.play()
    }

    private func buildPool(_ key: Key, data: Data) {
        var players: [AVAudioPlayer] = []
        for _ in 0..<poolSize {
            if let p = try? AVAudioPlayer(data: data) {
                p.volume = volume
                p.prepareToPlay()
                players.append(p)
            }
        }
        pools[key] = players
        cursor[key] = 0
    }
}

// MARK: - Click synthesis (16-bit mono PCM WAV, generated once)

private enum Synth {
    static let sampleRate = 44_100.0

    static func key() -> Data {
        wav(render(freq: 2000, duration: 0.040, decay: 130, noiseMix: 0.70, amp: 0.22))
    }
    static func space() -> Data {
        wav(render(freq: 1400, duration: 0.050, decay: 95, noiseMix: 0.60, amp: 0.26))
    }
    static func delete() -> Data {
        wav(render(freq: 1000, duration: 0.035, decay: 150, noiseMix: 0.55, amp: 0.20))
    }
    /// Carriage return: a key-like click with a short bell tail layered on top.
    static func carriageReturn() -> Data {
        var click = render(freq: 1600, duration: 0.180, decay: 100, noiseMix: 0.60, amp: 0.22)
        let bell  = render(freq: 1920, duration: 0.180, decay: 16,  noiseMix: 0.0,  amp: 0.16)
        for i in 0..<min(click.count, bell.count) {
            let mixed = Int(click[i]) + Int(bell[i])
            click[i] = Int16(max(-32768, min(32767, mixed)))
        }
        return wav(click)
    }

    /// One decaying, partly-noisy transient.
    private static func render(freq: Double, duration: Double, decay: Double,
                               noiseMix: Double, amp: Double) -> [Int16] {
        let count = Int(sampleRate * duration)
        var out = [Int16](repeating: 0, count: count)
        var rng = SystemRandomNumberGenerator()
        for i in 0..<count {
            let t = Double(i) / sampleRate
            let env = exp(-decay * t)
            let tone = sin(2.0 * .pi * freq * t)
            let noise = Double.random(in: -1...1, using: &rng)
            // Soft attack over the first 2 ms to avoid a hard pop.
            let attack = min(1.0, t / 0.002)
            let s = amp * env * attack * ((1 - noiseMix) * tone + noiseMix * noise)
            out[i] = Int16(max(-1.0, min(1.0, s)) * 32767.0)
        }
        return out
    }

    /// Wrap PCM samples in a canonical 44-byte WAV (RIFF) header.
    private static func wav(_ samples: [Int16]) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = UInt32(samples.count * 2)

        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        str("RIFF"); u32(36 + dataSize); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(channels)
        u32(UInt32(sampleRate)); u32(byteRate); u16(blockAlign); u16(bitsPerSample)
        str("data"); u32(dataSize)
        for s in samples { var x = s.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        return d
    }
}
