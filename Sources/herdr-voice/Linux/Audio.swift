import Foundation
import HerdrVoiceCore

/// Mic capture and playback on Linux.
///
/// This is the seam the macOS implementation fills with AVAudioEngine plus Apple voice processing. On Linux it is
/// the same contract over PortAudio at the device's native rate: a capture ring the real-time callback only writes
/// to, a playback queue drained by the output callback, and 24 kHz PCM16 chunks on the provider wire in both
/// directions.
///
/// Echo cancellation: macOS borrows Apple's voice-processing unit, which the OS runs for the app. PipeWire's
/// `module-echo-cancel` would be the platform equivalent and is preferred when it exists — `AudioEngine` selects
/// such a source by name — but a stock PipeWire/PulseAudio desktop has no echo-cancel source, so the equivalent
/// here is the software canceller in `AudioAEC`: a partitioned-block frequency-domain adaptive filter driven by the
/// assistant's own playback, subtracting speaker echo from the captured stream before it is sent. It is bypassed
/// while muted, exactly as the macOS one is, because audio nobody will hear is not worth a filter.
///
/// Contract (identical on both platforms):
/// - `start()` brings capture and playback up or throws;
/// - `onMic` is called off the main thread with base64 PCM16 24 kHz mono, every ~20 ms, with the chunk's rms;
/// - `play(base64:item:)` queues assistant audio and reports start/stop through `onSpeakingChanged` on main;
/// - `interrupt()` stops playback and returns how much of the current item was heard;
/// - `micLevel`/`outLevel` are the levels the orb draws.
final class Audio {
    static let rate = 24000.0
    static let chunkSeconds = 0.02

    /// Whether echo cancellation is used at all.
    let echoCancel: Bool

    /// Called on the mic queue every 20 ms with base64 PCM16 24 kHz mono and the chunk's rms level.
    var onMic: ((String, Float) -> Void)?
    /// Called on main when playback starts or stops, so Esc can be grabbed and released on the transition
    /// instead of being polled every frame.
    var onSpeakingChanged: ((Bool) -> Void)?

    private(set) var micLevel: Float = 0
    private(set) var outLevel: Float = 0

    /// Playback is tracked by what the device actually consumed, not by what was queued: the queue drains ahead of
    /// the speaker, so queued samples would overstate what has been heard.
    private var playback = PlaybackLedger()
    /// One entry per `play` call, in the order the ledger sees them, with the running 24 kHz frame count.
    private var pending: [(item: String, frames: Int, end: Int64)] = []
    /// Bumped on interrupt so late completions from a flushed queue are ignored.
    private var generation = 0

    private var engine: AudioEngine?
    private var publisher: DispatchSourceTimer?

    init(echoCancel: Bool = ProcessInfo.processInfo.environment["HERDR_VOICE_ECHO_CANCEL"] != "0") {
        self.echoCancel = echoCancel
    }

    deinit {
        publisher?.cancel()
        engine?.stop()
    }

    struct Unavailable: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
    }

    func start() throws {
        guard engine == nil else { return }
        let engine: AudioEngine
        do {
            engine = try AudioEngine(echoCancel: echoCancel)
        } catch {
            throw Unavailable(what: "\(error)")
        }
        engine.onChunk = { [weak self] base64, level in
            guard let self else { return }
            self.micLevel = level
            self.onMic?(base64, level)
        }
        do {
            try engine.start()
        } catch {
            throw Unavailable(what: "\(error)")
        }
        self.engine = engine
        startPublisher()
    }

    func stop() {
        publisher?.cancel()
        publisher = nil
        engine?.stop()
        engine = nil
    }

    /// While muted nothing from the mic reaches the provider. Capture keeps running and the chunks are still
    /// delivered — the session drops them itself (`Realtime.swift` returns early when muted) — but the canceller is
    /// bypassed, which is where the cost is. Playback is untouched: you still hear the voice.
    func setMuted(_ muted: Bool) {
        engine?.muted = muted
    }

    /// Queues one base64 PCM16 chunk of assistant audio. Main queue only, like `interrupt`.
    func play(base64: String, item: String) {
        guard let engine, let data = Data(base64Encoded: base64), data.count >= 2 else { return }
        let frames = data.count / 2
        var samples = [Float](repeating: 0, count: frames)
        data.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                samples[i] = Float(Int16(littleEndian: source[i])) / 32768
            }
        }
        let wasSpeaking = playback.isSpeaking
        playback.enqueue(item: item, frames: frames)
        if !wasSpeaking { onSpeakingChanged?(true) }
        pending.append((item: item, frames: frames, end: (pending.last?.end ?? 0) + Int64(frames)))
        samples.withUnsafeBufferPointer { engine.enqueue($0) }
    }

    /// Main queue only, like `play` and `interrupt`.
    var isSpeaking: Bool { playback.isSpeaking }

    /// Stops playback and returns how many ms of the current item were heard, for conversation.item.truncate.
    func interrupt() -> (item: String, heardMs: Int)? {
        let heard = playback.interrupt(sampleRate: Int(Audio.rate))
        generation += 1
        pending.removeAll()
        engine?.flushPlayback()
        if heard != nil { onSpeakingChanged?(false) }
        outLevel = 0
        return heard
    }

    /// PortAudio's latency is not zero: audio handed to the device now is heard a few tens of ms later. Advancing
    /// the ledger only by what has actually left the latency window is what makes `heardMs` mean "heard".
    private func startPublisher() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.publish() }
        timer.resume()
        publisher = timer
    }

    private func publish() {
        guard let engine else { return }
        outLevel = engine.outputLevel
        let latency = Int64(engine.outputLatency * Audio.rate)
        let heard = max(0, engine.consumedFrames - latency)
        let gen = generation
        while let head = pending.first, heard >= head.end {
            pending.removeFirst()
            guard gen == generation else { return }
            playback.completed(item: head.item, frames: head.frames)
            if !playback.isSpeaking { onSpeakingChanged?(false) }
        }
    }

    /// Diagnostics for the check script: devices, latencies, drop counts and the canceller's measured ERLE.
    var diagnostics: AudioEngine.Diagnostics? { engine?.diagnostics() }
}
