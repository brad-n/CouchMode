// Owns: the pure synthesis of the shell's interface sounds: soft clicks built from a
// band-passed noise burst plus a damped low-mid transient, shaped by a short fast-decay
// envelope with faded edges, and the rate limit for fast repeats. No audio APIs here;
// the app target only plays the samples.

import Foundation

public enum SoftTick {
    public enum Kind: CaseIterable, Sendable { case move, select, back, limit }

    public static let sampleRate: Double = 44_100

    public struct Spec: Sendable, Equatable {
        public let seconds: Double
        /// Centre of the band-passed noise and of the damped transient, in Hz.
        public let centerHz: Double
        /// Envelope time constant: amplitude falls to 1/e after this long.
        public let decaySeconds: Double
        /// Share of the damped sine transient mixed with the noise (0...1).
        public let tonalMix: Double
        public let peak: Float
    }

    public static func spec(_ kind: Kind) -> Spec {
        switch kind {
        case .move:   return Spec(seconds: 0.012, centerHz: 2_400, decaySeconds: 0.0028, tonalMix: 0.25, peak: 0.008)
        case .select: return Spec(seconds: 0.020, centerHz: 1_900, decaySeconds: 0.0050, tonalMix: 0.35, peak: 0.013)
        case .back:   return Spec(seconds: 0.016, centerHz: 1_500, decaySeconds: 0.0042, tonalMix: 0.30, peak: 0.010)
        case .limit:  return Spec(seconds: 0.018, centerHz: 520, decaySeconds: 0.0045, tonalMix: 0.15, peak: 0.011)
        }
    }

    /// Attack and release ramp lengths, so a buffer never starts or ends with a step.
    static let attackSeconds = 0.0008
    static let releaseSeconds = 0.003

    /// Envelope value (0...1) at sample `index` of `count`: raised-cosine attack, exponential
    /// decay, raised-cosine release that ends exactly at 0 on the last sample.
    public static func envelope(index: Int, count: Int, decaySeconds: Double) -> Float {
        guard count > 1, index >= 0, index < count else { return 0 }
        let t = Double(index) / sampleRate
        let attackN = max(1, Int(attackSeconds * sampleRate))
        let releaseN = max(1, Int(releaseSeconds * sampleRate))
        var e = exp(-t / decaySeconds)
        if index < attackN { e *= 0.5 - 0.5 * cos(Double.pi * Double(index) / Double(attackN)) }
        let fromEnd = count - 1 - index
        if fromEnd < releaseN { e *= 0.5 - 0.5 * cos(Double.pi * Double(fromEnd) / Double(releaseN)) }
        return Float(e)
    }

    /// Mono samples for one sound. Deterministic: the noise comes from a seeded generator.
    public static func samples(_ kind: Kind, seed: UInt64 = 0x5EED) -> [Float] {
        let s = spec(kind)
        let n = max(2, Int((s.seconds * sampleRate).rounded()))
        // Band-pass biquad (RBJ, constant 0 dB peak gain) over white noise.
        let w0 = 2 * Double.pi * s.centerHz / sampleRate
        let alpha = sin(w0) / (2 * 1.2)
        let a0 = 1 + alpha
        let b0 = alpha / a0, b2 = -alpha / a0
        let a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
        var state = seed | 1
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var raw = [Double](repeating: 0, count: n)
        for i in 0..<n {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let white = Double(Int64(bitPattern: state) >> 11) / Double(1 << 52) // -1...1
            let y = b0 * white + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = white; y2 = y1; y1 = y
            let t = Double(i) / sampleRate
            let tone = sin(2 * Double.pi * s.centerHz * t)
            raw[i] = (1 - s.tonalMix) * y + s.tonalMix * tone
        }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = Float(raw[i]) * envelope(index: i, count: n, decaySeconds: s.decaySeconds) }
        // Remove any DC offset, then normalise to the kind's peak (re-zero the last sample).
        let mean = out.reduce(0, +) / Float(n)
        for i in 0..<n { out[i] = Float(Double(out[i] - mean * envelope(index: i, count: n, decaySeconds: s.decaySeconds))) }
        let maxAbs = out.map { abs($0) }.max() ?? 0
        if maxAbs > 0 { let g = s.peak / maxAbs; for i in 0..<n { out[i] *= g } }
        out[n - 1] = 0
        return out
    }

    /// Fast repeats retrigger the same voice; this also caps how often a kind may start.
    public struct RateLimiter: Sendable {
        public static let minInterval: TimeInterval = 0.045
        private var last: [Kind: TimeInterval] = [:]
        public init() {}

        /// True when a sound of `kind` may start at `now` (seconds on any steady clock).
        public mutating func allow(_ kind: Kind, now: TimeInterval) -> Bool {
            if let prev = last[kind], now - prev < Self.minInterval, now >= prev { return false }
            last[kind] = now
            return true
        }
    }
}
