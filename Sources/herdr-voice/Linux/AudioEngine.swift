import Foundation
import HerdrVoiceCore

#if canImport(Glibc)
import Glibc
#endif

/// Linux capture and playback over PortAudio.
///
/// Two mono float32 streams at the device's native rate: the capture callback does nothing but copy into a ring,
/// and the playback callback drains the queue, converts 24 kHz to the device rate and records what it handed to
/// the speaker as the echo-canceller reference. All conversion, cancelling and base64 work happens on the mic
/// worker, never in a callback.
///
/// The device rate (48 kHz here) is not the wire rate: the provider speaks 24 kHz mono PCM16 in both directions, so
/// `AudioResampler` converts each way. The echo timeline is the playback stream's own output, so both directions
/// have to be on one clock — which is why a single rate is negotiated for both streams.
final class AudioEngine {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    struct Diagnostics {
        let library: String
        let inputDevice: String
        let outputDevice: String
        let deviceRate: Double
        let inputLatencyMs: Double
        let outputLatencyMs: Double
        let chunkFrames: Int
        let micDroppedSamples: Int
        let playbackUnderruns: Int
        let aecEnabled: Bool
        let aecTailMs: Double
        let aecERLEdB: Float
    }

    /// 20 ms at the wire rate: the chunk size the provider protocol expects.
    static let chunk24k = Int(Audio.rate * Audio.chunkSeconds)
    /// How much audio the playback queue will hold before new chunks are refused.
    private static let playbackCapacity = Int(Audio.rate * 30)
    /// One second of slack on the capture side; overflow is dropped and counted, never waited on.
    private static let micCapacity = 48000
    /// Two seconds of reference history, enough for the lag plus the canceller's look-back.
    private static let referenceCapacity = 96000
    /// Playback scratch, sized for the largest block PortAudio hands us in practice.
    private static let playbackScratch = 16384

    let echoCancel: Bool
    let deviceRate: Double
    let framesPerChunk: Int
    let inputDeviceName: String
    let outputDeviceName: String

    /// Filled in from the streams once they exist; PortAudio reports the real numbers then, not before.
    private(set) var inputLatencySeconds: Double = 0.02
    private(set) var outputLatencySeconds: Double = 0.02

    /// Called on the mic worker every 20 ms with base64 PCM16 24 kHz mono and the chunk's rms.
    var onChunk: ((String, Float) -> Void)?
    /// While muted the canceller is bypassed: there is no point spending a filter on audio nobody will hear.
    var muted = false

    /// Written by the playback callback, read by `stats()`.
    private let statsBox = Locked<Stats>(Stats())
    private struct Stats {
        var outputRMS: Float = 0
        var underruns: Int = 0
    }

    private let library: PortAudio
    private let inputDevice: PortAudio.Device
    private let outputDevice: PortAudio.Device
    private var inputStream: UnsafeMutableRawPointer?
    private var outputStream: UnsafeMutableRawPointer?

    private let micRing = AudioSampleRing(capacity: AudioEngine.micCapacity)
    private let playbackRing = AudioSampleRing(capacity: AudioEngine.playbackCapacity)
    private let referenceRing = AudioSampleRing(capacity: AudioEngine.referenceCapacity)

    private let captureResampler: AudioResampler
    private let referenceResampler: AudioResampler
    private let playbackResampler: AudioResampler

    private let aec: AudioEchoCanceller?
    private let micQueue = DispatchQueue(label: "herdr-voice.mic", qos: .userInitiated)
    private var worker: DispatchSourceTimer?

    // Preallocated buffers: the callbacks and the worker only ever write into these.
    private let micScratch: UnsafeMutablePointer<Float>
    private let referenceScratch: UnsafeMutablePointer<Float>
    private let playbackScratch: UnsafeMutablePointer<Float>
    private let mic24: UnsafeMutablePointer<Float>
    private let reference24: UnsafeMutablePointer<Float>

    /// Total 24 kHz frames pulled from the playback queue by the device callback.
    private let consumedStorage: UnsafeMutablePointer<Int64>
    /// Set by `flushPlayback()`; the callback resets the queue and counters when it sees it.
    private let flushFlag: UnsafeMutablePointer<Int32>
    private let referenceLag: Int
    private var started = false

    var consumedFrames: Int64 { consumedStorage.pointee }

    init(echoCancel: Bool) throws {
        guard let library = PortAudio.shared else {
            throw Failure(description: """
            herdr-voice: PortAudio is not available (libportaudio.so.2 not found). \
            Install it with: sudo apt install libportaudio2
            """)
        }
        guard case .ready = library.initialize() else {
            throw Failure(description: "herdr-voice: PortAudio failed to initialise (Pa_Initialize)")
        }
        self.library = library
        self.echoCancel = echoCancel

        let environment = ProcessInfo.processInfo.environment
        // A `module-echo-cancel` source, when the machine has one, beats any per-app filter: it is the platform's
        // own canceller and it sees every stream, not just ours. Prefer it unless a device was named explicitly.
        let preferredEchoCancel = echoCancel
            ? library.devices().first { $0.isPlatformEchoCancel && $0.maxInputChannels > 0 }
            : nil
        let requestedInput = environment["HERDR_VOICE_INPUT_DEVICE"].flatMap { library.device(matching: $0, input: true) }
        let requestedOutput = environment["HERDR_VOICE_OUTPUT_DEVICE"].flatMap { library.device(matching: $0, input: false) }

        guard let input = requestedInput ?? preferredEchoCancel ?? library.device(library.defaultInputDevice) else {
            throw Failure(description: """
            herdr-voice: no audio input device. PortAudio sees \(library.deviceCount) device(s) but none can \
            capture; check that the microphone is connected and not in use, or set HERDR_VOICE_INPUT_DEVICE.
            """)
        }
        guard let output = requestedOutput ?? library.device(library.defaultOutputDevice) else {
            throw Failure(description: """
            herdr-voice: no audio output device. PortAudio sees \(library.deviceCount) device(s) but none can \
            play; check that the speakers are connected, or set HERDR_VOICE_OUTPUT_DEVICE.
            """)
        }
        guard input.maxInputChannels > 0 else {
            throw Failure(description: "herdr-voice: input device \(input.name) has no capture channels")
        }
        guard output.maxOutputChannels > 0 else {
            throw Failure(description: "herdr-voice: output device \(output.name) has no playback channels")
        }

        inputDevice = input
        outputDevice = output
        inputDeviceName = input.name
        outputDeviceName = output.name

        // 48 kHz is what every provider wire and the playback queue use, and what this class of device runs
        // natively. The ALSA plugin reports 44100 as a default hint even when the hardware is 48000, so the rate is
        // negotiated by actually opening the streams instead of trusting that hint. Some virtual devices (ALSA
        // loopback) block inside an open/close probe, so the rate can be pinned to skip negotiation entirely.
        let rate: Double
        if let pinned = environment["HERDR_VOICE_DEVICE_RATE"].flatMap(Double.init), pinned >= 8000, pinned <= 192_000 {
            rate = pinned
        } else {
            rate = try AudioEngine.negotiateRate(library: library, input: input, output: output)
        }
        deviceRate = rate
        framesPerChunk = Int(rate * Audio.chunkSeconds)
        guard let capture = AudioResampler(inputRate: rate, outputRate: Audio.rate),
              let reference = AudioResampler(inputRate: rate, outputRate: Audio.rate),
              let playback = AudioResampler(inputRate: Audio.rate, outputRate: rate) else {
            throw Failure(description: "herdr-voice: cannot build resamplers for a \(rate) Hz device")
        }
        captureResampler = capture
        referenceResampler = reference
        playbackResampler = playback

        // The canceller only earns its CPU when there is echo to remove; a headset user turns it off entirely.
        aec = echoCancel ? AudioEchoCanceller(sampleRate: Int(Audio.rate)) : nil

        func allocate(_ count: Int) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            return pointer
        }
        micScratch = allocate(AudioEngine.micCapacity > framesPerChunk ? framesPerChunk : AudioEngine.micCapacity)
        referenceScratch = allocate(AudioEngine.micCapacity > framesPerChunk ? framesPerChunk : AudioEngine.micCapacity)
        playbackScratch = allocate(AudioEngine.playbackScratch)
        mic24 = allocate(AudioEngine.chunk24k)
        reference24 = allocate(AudioEngine.chunk24k)
        consumedStorage = .allocate(capacity: 1)
        consumedStorage.initialize(to: 0)
        flushFlag = .allocate(capacity: 1)
        flushFlag.initialize(to: 0)

        // The echo in the mic now was played `inputLatency` ago. Reading the reference slightly behind the live
        // edge leaves the residual delay inside the canceller's 160 ms tail instead of in front of it.
        referenceLag = max(0, Int((0.02 + 0.01) * rate))
    }

    deinit {
        stop()
        micScratch.deallocate()
        referenceScratch.deallocate()
        playbackScratch.deallocate()
        mic24.deallocate()
        reference24.deallocate()
        consumedStorage.deallocate()
        flushFlag.deallocate()
        library.terminate()
    }

    /// Picks the rate both streams can actually open, preferring the device's native 48 kHz.
    ///
    /// PortAudio reports success or failure for a rate only by trying it, and the ALSA default device advertises
    /// 44100 while accepting 48000, so a negotiation beats reading `defaultSampleRate`.
    private static func negotiateRate(
        library: PortAudio, input: PortAudio.Device, output: PortAudio.Device
    ) throws -> Double {
        var candidates: [Double] = []
        for candidate in [48000.0, 44100.0, input.defaultSampleRate, output.defaultSampleRate]
        where candidate >= 8000 && candidate <= 192_000 && !candidates.contains(candidate) {
            candidates.append(candidate)
        }
        let userData = UnsafeMutableRawPointer(bitPattern: 0x1)!
        var failures: [String] = []
        for candidate in candidates {
            let inputProbe = library.open(
                input: true, device: input.index, rate: candidate, framesPerBuffer: 0, latency: 0.02,
                callback: audioEngineProbeCallback, userData: userData
            )
            guard let inputStream = inputProbe.stream else {
                failures.append("\(Int(candidate)) Hz capture: \(inputProbe.error ?? "refused")")
                continue
            }
            let outputProbe = library.open(
                input: false, device: output.index, rate: candidate, framesPerBuffer: 0, latency: 0.02,
                callback: audioEngineProbeCallback, userData: userData
            )
            guard let outputStream = outputProbe.stream else {
                failures.append("\(Int(candidate)) Hz playback: \(outputProbe.error ?? "refused")")
                library.close(inputStream)
                continue
            }
            library.close(outputStream)
            library.close(inputStream)
            return candidate
        }
        throw Failure(description: """
        herdr-voice: the microphone and the speakers share no usable sample rate. \
        Tried \(failures.joined(separator: "; "))
        """)
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !started else { return }

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let opened = library.open(
            input: true,
            device: inputDevice.index,
            rate: deviceRate,
            framesPerBuffer: 0,
            latency: 0.02,
            callback: audioEngineCaptureCallback,
            userData: userData
        )
        guard let inputStream = opened.stream else {
            throw Failure(description: """
            herdr-voice: cannot open microphone "\(inputDevice.name)" at \(Int(deviceRate)) Hz: \
            \(opened.error ?? "unknown error")
            """)
        }
        self.inputStream = inputStream

        let openedOutput = library.open(
            input: false,
            device: outputDevice.index,
            rate: deviceRate,
            framesPerBuffer: 0,
            latency: 0.02,
            callback: audioEngineRenderCallback,
            userData: userData
        )
        guard let outputStream = openedOutput.stream else {
            library.close(inputStream)
            self.inputStream = nil
            throw Failure(description: """
            herdr-voice: cannot open speakers "\(outputDevice.name)" at \(Int(deviceRate)) Hz: \
            \(openedOutput.error ?? "unknown error")
            """)
        }
        self.outputStream = outputStream

        // Real latencies come from the streams themselves; they only change the heard-ms accounting.
        if let info = library.streamInfo(inputStream) { inputLatencySeconds = info.inputLatency }
        if let info = library.streamInfo(outputStream) { outputLatencySeconds = info.outputLatency }

        let timer = DispatchSource.makeTimerSource(queue: micQueue)
        timer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(10), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.drainCapture() }
        timer.resume()
        worker = timer

        if let error = library.start(inputStream) {
            stop()
            throw Failure(description: "herdr-voice: microphone stream failed to start: \(error)")
        }
        if let error = library.start(outputStream) {
            stop()
            throw Failure(description: "herdr-voice: speaker stream failed to start: \(error)")
        }
        started = true
    }

    func stop() {
        worker?.cancel()
        worker = nil
        // Aborted, not drained: stopping a stream waits for its buffer to run out, and a virtual device whose
        // counterpart is not reading (ALSA loopback, a stalled server) never drains — shutdown would hang. Nothing
        // is lost that matters: the app is closing the device, not continuing the conversation.
        if let stream = inputStream {
            library.stop(stream, abort: true)
            library.close(stream)
            inputStream = nil
        }
        if let stream = outputStream {
            library.stop(stream, abort: true)
            library.close(stream)
            outputStream = nil
        }
        started = false
    }

    // MARK: - Real-time callbacks

    /// Capture callback: copy the block into the ring and return. No allocation, no lock, no waiting.
    fileprivate func capture(_ samples: UnsafePointer<Float>, frames: Int) {
        micRing.write(samples, count: frames)
    }

    /// Playback callback: pull queued 24 kHz audio, convert to the device rate, publish the reference.
    fileprivate func render(_ output: UnsafeMutablePointer<Float>, frames: Int) {
        if flushFlag.pointee != 0 {
            flushFlag.pointee = 0
            playbackRing.reset()
            playbackResampler.reset()
            consumedStorage.pointee = 0
        }
        let needed = playbackResampler.inputNeeded(forOutputFrames: frames)
        var made = 0
        if needed > 0 {
            let available = min(needed, min(playbackRing.available, AudioEngine.playbackScratch))
            if available > 0 {
                let got = playbackRing.peek(playbackScratch, count: available)
                playbackRing.skip(got)
                made = playbackResampler.process(
                    input: playbackScratch, inputCount: got, output: output, outputFrames: frames
                )
                consumedStorage.pointee += Int64(got)
                if got < needed {
                    _ = statsBox.tryWithLock { $0.underruns += 1 }
                }
            }
        } else {
            made = playbackResampler.process(input: playbackScratch, inputCount: 0, output: output, outputFrames: frames)
        }
        if made < frames {
            memset(output + made, 0, (frames - made) * MemoryLayout<Float>.size)
        }
        // The reference is the speaker signal itself, silence included: the canceller needs a continuous
        // timeline, not just the moments something was playing.
        referenceRing.write(output, count: frames)
        let level = AudioDSP.rms(output, frames)
        _ = statsBox.tryWithLock { $0.outputRMS = level }
    }

    // MARK: - Mic worker

    private func drainCapture() {
        let chunk = framesPerChunk
        let wireChunk = AudioEngine.chunk24k
        while micRing.available >= chunk {
            let read = micRing.read(micScratch, count: chunk)
            guard read == chunk else { break }
            let resampled = decimateToWire(micScratch, count: chunk, into: mic24, frames: wireChunk)
            guard resampled > 0 else { continue }
            _ = readReference(count: chunk)
            _ = decimateToWire(referenceScratch, count: chunk, into: reference24, frames: wireChunk)
            if echoCancel, !muted, let aec {
                var offset = 0
                while offset + aec.blockSize <= resampled {
                    aec.process(mic: mic24 + offset, reference: reference24 + offset)
                    offset += aec.blockSize
                }
            }
            let level = AudioDSP.rms(mic24, resampled)
            onChunk?(AudioDSP.pcm16Base64(mic24, resampled), level)
        }
    }

    @discardableResult
    private func decimateToWire(
        _ source: UnsafePointer<Float>, count: Int, into destination: UnsafeMutablePointer<Float>, frames: Int
    ) -> Int {
        captureResampler.process(input: source, inputCount: count, output: destination, outputFrames: frames)
    }

    /// Fills `referenceScratch` with the reference window ending `referenceLag` samples behind the live edge.
    /// Returns the count, or -1 when the ring does not have that window yet (streams still warming up).
    private func readReference(count: Int) -> Int {
        // When the writer has not advanced far enough for the lagged window — start-up, or the mic worker drained
        // two chunks in one tick — the previous block is left in place rather than zeroed: repeating 20 ms keeps
        // the reference continuous (the canceller's tail absorbs the small shift), while zeros would blind it.
        referenceRing.copyLatest(referenceScratch, count: count, lag: referenceLag) ? count : -1
    }

    // MARK: - Queue

    /// Main thread: queue one chunk of base64-decoded PCM16 (already converted to floats by the caller).
    func enqueue(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress, samples.count > 0 else { return }
        playbackRing.write(base, count: samples.count)
    }

    /// Main thread: drop everything queued. The callback performs the actual reset so the ring is never rewritten
    /// underneath the reader.
    func flushPlayback() {
        flushFlag.pointee = 1
    }

    // MARK: - Diagnostics

    func diagnostics() -> Diagnostics {
        let stats = statsBox.withLock { $0 }
        return Diagnostics(
            library: library.version,
            inputDevice: inputDeviceName,
            outputDevice: outputDeviceName,
            deviceRate: deviceRate,
            inputLatencyMs: inputLatencySeconds * 1000,
            outputLatencyMs: outputLatencySeconds * 1000,
            chunkFrames: AudioEngine.chunk24k,
            micDroppedSamples: Int(micRing.overflows.pointee),
            playbackUnderruns: stats.underruns,
            aecEnabled: echoCancel,
            aecTailMs: aec?.tailMs ?? 0,
            aecERLEdB: aec?.erleDB ?? 0
        )
    }

    /// Latency of the output path, used to convert "frames handed to the device" into "frames actually heard".
    var outputLatency: Double { outputLatencySeconds }

    /// Level of what the speaker was actually given, for the orb's voice ring.
    var outputLevel: Float { statsBox.withLock { $0.outputRMS } }
}

/// PortAudio callbacks are C function pointers: no captures, so the engine travels in `userData`.
private func audioEngineCaptureCallback(
    _ input: UnsafeRawPointer?,
    _ output: UnsafeMutableRawPointer?,
    _ frames: UInt,
    _ time: UnsafeRawPointer?,
    _ flags: UInt,
    _ userData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let userData, let input, frames > 0 else { return PortAudio.continueStream }
    let engine = Unmanaged<AudioEngine>.fromOpaque(userData).takeUnretainedValue()
    engine.capture(input.assumingMemoryBound(to: Float.self), frames: Int(frames))
    return PortAudio.continueStream
}

private func audioEngineRenderCallback(
    _ input: UnsafeRawPointer?,
    _ output: UnsafeMutableRawPointer?,
    _ frames: UInt,
    _ time: UnsafeRawPointer?,
    _ flags: UInt,
    _ userData: UnsafeMutableRawPointer?
) -> Int32 {
    guard let userData, let output, frames > 0 else { return PortAudio.continueStream }
    let engine = Unmanaged<AudioEngine>.fromOpaque(userData).takeUnretainedValue()
    engine.render(output.assumingMemoryBound(to: Float.self), frames: Int(frames))
    return PortAudio.continueStream
}

/// Probe streams are opened only to ask "can this device do this rate?", so the callback never runs.
private func audioEngineProbeCallback(
    _ input: UnsafeRawPointer?,
    _ output: UnsafeMutableRawPointer?,
    _ frames: UInt,
    _ time: UnsafeRawPointer?,
    _ flags: UInt,
    _ userData: UnsafeMutableRawPointer?
) -> Int32 {
    PortAudio.continueStream
}
