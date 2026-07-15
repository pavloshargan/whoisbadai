import AVFoundation

/// Plays an anime-style "whip" (smack) when a whip gesture fires.
///
/// Like the whip visuals, the sound ships with no asset: the waveform is
/// synthesized once at init into an `AVAudioPCMBuffer` and replayed through
/// a persistent `AVAudioEngine`. Recipe for a cartoon smack:
///
///   1. a band-passed white-noise burst (~1.8 kHz) with instant attack and
///      ~25 ms decay — the "skin slap"
///   2. a sine "pop" sweeping 750 Hz → 190 Hz — the comedic cartoon body
///   3. a low 110 Hz thump for weight
///
/// summed and soft-clipped with tanh for a slightly compressed, punchy feel.
@MainActor
final class WhipSoundPlayer {

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// The bundled whip clip (Resources/whip.caf); synth is the fallback.
    private let buffer: AVAudioPCMBuffer
    private var engineStarted = false
    private var connectedFormat: AVAudioFormat

    init() {
        buffer = Self.loadBundledWhip() ?? Self.synthesizeWhip()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        connectedFormat = buffer.format
        // Don't start the engine yet: it owns an audio-device handle, so we
        // grab it lazily on the first actual play.
    }

    /// The shipped clip, recorded from system audio during development.
    private static func loadBundledWhip() -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: "whip", withExtension: "caf") else {
            return nil
        }
        do {
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length))
            else { return nil }
            try file.read(into: buffer)
            return buffer
        } catch {
            NSLog("WhipSoundPlayer: failed to load bundled sound: \(error)")
            return nil
        }
    }

    /// Play the smack. `intensity` is the gesture's peak acceleration in g;
    /// harder whips are louder.
    func play(intensity: Double) {
        // 1.6 g (threshold) → ~0.55, 5 g+ → 1.0
        schedule(buffer, volume: Float(min(0.3 + intensity * 0.15, 1.0)))
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, volume: Float) {
        // The player's connection format must match the buffer (recordings
        // are 48 kHz stereo, the synth is 44.1 kHz) — reconnect on change.
        if !connectedFormat.isEqual(buffer.format) {
            player.stop()
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
            connectedFormat = buffer.format
        }
        if !engineStarted {
            do {
                try engine.start()
                engineStarted = true
            } catch {
                NSLog("WhipSoundPlayer: audio engine failed to start: \(error)")
                return
            }
        }
        // Interrupt, never queue: a rapid burst of whips must not stack
        // buffers that keep playing seconds after the user stops.
        player.stop()
        player.volume = volume
        player.scheduleBuffer(buffer, at: nil)
        player.play()
    }

    /// Release the audio device (called when whoisbadai is disabled).
    func shutdown() {
        guard engineStarted else { return }
        player.stop()
        engine.stop()
        engineStarted = false
    }

    // MARK: Synthesis

    private static func synthesizeWhip() -> AVAudioPCMBuffer {
        let sampleRate = 44100.0
        let duration = 0.22
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount

        // Deterministic noise (linear congruential generator) so every launch
        // sounds identical.
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func whiteNoise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(UInt64.max >> 11) * 2.0 - 1.0
        }

        // RBJ-cookbook biquad band-pass centered on the "slap" frequency.
        let center = 1800.0, q = 0.9
        let omega = 2.0 * Double.pi * center / sampleRate
        let alpha = sin(omega) / (2.0 * q)
        let a0 = 1.0 + alpha
        let b0 = alpha / a0, b2 = -alpha / a0
        let a1 = -2.0 * cos(omega) / a0, a2 = (1.0 - alpha) / a0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

        var sweepPhase = 0.0
        var thumpPhase = 0.0

        for frame in 0..<Int(frameCount) {
            let t = Double(frame) / sampleRate

            // 1. Slap: filtered noise, sharp exponential decay.
            let x0 = whiteNoise()
            let filtered = b0 * x0 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x0
            y2 = y1; y1 = filtered
            let slap = filtered * exp(-t / 0.025) * 2.2

            // 2. Cartoon pop: sine sweeping 750 Hz down to 190 Hz.
            let sweepFreq = 190.0 + 560.0 * exp(-t / 0.045)
            sweepPhase += 2.0 * Double.pi * sweepFreq / sampleRate
            let pop = sin(sweepPhase) * exp(-t / 0.05) * 0.8

            // 3. Thump: low sine for body.
            thumpPhase += 2.0 * Double.pi * 110.0 / sampleRate
            let thump = sin(thumpPhase) * exp(-t / 0.07) * 0.45

            // Mix + tanh soft clip ≈ gentle compression, keeps peaks < 1.
            let sample = Float(tanh(slap + pop + thump))
            buffer.floatChannelData?[0][frame] = sample
            buffer.floatChannelData?[1][frame] = sample
        }
        return buffer
    }
}
