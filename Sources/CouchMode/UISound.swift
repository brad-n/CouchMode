// Owns: playing the shell's interface sounds (soft ticks on focus moves, select, back and
// limit taps). The samples come from CouchModeCore.SoftTick; this only feeds them to the
// audio engine, retriggering one voice, and honors Prefs.uiSounds.

import AVFoundation
import CouchModeCore
import os

@MainActor
final class UISound {
    typealias Kind = SoftTick.Kind

    private static let log = Logger(subsystem: "local.brad.htpcshell", category: "sound")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: SoftTick.sampleRate, channels: 1)!
    private var buffers: [Kind: AVAudioPCMBuffer] = [:]
    private var limiter = SoftTick.RateLimiter()
    private var started = false

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        for kind in Kind.allCases { buffers[kind] = buffer(SoftTick.samples(kind)) }
    }

    func play(_ kind: Kind) {
        guard Prefs.uiSounds, let buffer = buffers[kind] else { return }
        guard limiter.allow(kind, now: ProcessInfo.processInfo.systemUptime) else { return }
        if !started {
            do { try engine.start(); started = true } catch {
                Self.log.error("sound engine start failed")
                return
            }
        }
        // .interrupts replaces whatever is still playing, so repeats never queue a backlog.
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
        Self.log.debug("tick \(String(describing: kind), privacy: .public)")
    }

    private func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let data = buffer.floatChannelData?[0] else { return nil }
        for (i, v) in samples.enumerated() { data[i] = v }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
