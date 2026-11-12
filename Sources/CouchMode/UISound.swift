// Owns: the shell's interface sounds: a soft tick on focus moves and short
// two-note chimes for select and back. Synthesized here (our own tones, no
// sound files), quiet, and only when Prefs.uiSounds is on.

import AVFoundation

@MainActor
final class UISound {
    enum Kind { case move, select, back }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var buffers: [Kind: AVAudioPCMBuffer] = [:]
    private var started = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        buffers[.move] = tone([(1760, 0.028)], amplitude: 0.05)
        buffers[.select] = tone([(880, 0.045), (1318.5, 0.07)], amplitude: 0.07)
        buffers[.back] = tone([(1318.5, 0.045), (880, 0.07)], amplitude: 0.06)
    }

    func play(_ kind: Kind) {
        guard Prefs.uiSounds, let buffer = buffers[kind] else { return }
        if !started {
            do { try engine.start(); started = true } catch { return }
        }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    /// Sine notes back to back, each with a fast attack and soft decay.
    private func tone(_ notes: [(freq: Double, seconds: Double)], amplitude: Float) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let total = notes.reduce(0) { $0 + Int($1.seconds * rate) }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)),
              let data = buffer.floatChannelData?[0] else { return nil }
        var i = 0
        for note in notes {
            let n = Int(note.seconds * rate)
            for k in 0..<n {
                let t = Double(k) / rate
                let attack = min(1, Double(k) / (rate * 0.003))
                let decay = exp(-t / (note.seconds * 0.45))
                data[i] = amplitude * Float(sin(2 * .pi * note.freq * t) * attack * decay)
                i += 1
            }
        }
        buffer.frameLength = AVAudioFrameCount(total)
        return buffer
    }
}
