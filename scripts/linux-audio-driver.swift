import Foundation

#if canImport(Glibc)
import Glibc
#endif

// Measurement harness for the Linux audio path.
//
// This is not part of the app: `scripts/linux-audio-check` compiles it together with the Linux audio sources so the
// real `Audio` class — real PortAudio streams, real devices, real resampler and canceller — can be exercised and
// measured. Every number it prints comes from audio that actually went through the device, and every mode exits
// non-zero when its check fails.
//
// Usage: linux-audio-driver <devices|capture|playback|aec|cpu|synthetic> [args]

enum DriverError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

// MARK: - Measurement helpers

func rms(_ samples: [Float]) -> Double {
    guard !samples.isEmpty else { return 0 }
    var sum = 0.0
    for value in samples { sum += Double(value) * Double(value) }
    return (sum / Double(samples.count)).squareRoot()
}

/// Amplitude of `frequency` in `samples`, in dBFS, by Goertzel. Independent of the canceller's own reporting: this
/// is measured off the microphone signal only.
func toneLevelDB(_ samples: [Float], rate: Double, frequency: Double) -> Double {
    guard samples.count > 8 else { return -200 }
    let omega = 2 * Double.pi * frequency / rate
    let coefficient = 2 * cos(omega)
    var s1 = 0.0
    var s2 = 0.0
    for value in samples {
        let s0 = Double(value) + coefficient * s1 - s2
        s2 = s1
        s1 = s0
    }
    let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
    let amplitude = 2 * (max(power, 0)).squareRoot() / Double(samples.count)
    return 20 * log10(max(amplitude, 1e-12))
}

func peak(_ samples: [Float]) -> Double {
    var value = 0.0
    for sample in samples { value = max(value, Double(abs(sample))) }
    return value
}

/// 16-bit mono WAV, so the evidence can be listened to and re-analysed outside this harness.
func writeWav(_ path: String, samples: [Float], rate: Int) throws {
    var data = Data()
    func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    let byteCount = UInt32(samples.count * 2)
    data.append(contentsOf: Array("RIFF".utf8))
    append32(36 + byteCount)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append32(16)
    append16(1) // PCM
    append16(1) // mono
    append32(UInt32(rate))
    append32(UInt32(rate * 2))
    append16(2)
    append16(16)
    data.append(contentsOf: Array("data".utf8))
    append32(byteCount)
    for sample in samples {
        let clamped = max(-1.0, min(1.0, Double(sample)))
        let value = UInt16(bitPattern: Int16((clamped * 32767).rounded()))
        append16(value)
    }
    try data.write(to: URL(fileURLWithPath: path))
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(Int32(RUSAGE_SELF.rawValue), &usage)
    func seconds(_ time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
    return seconds(usage.ru_utime) + seconds(usage.ru_stime)
}

func report(_ line: String) {
    print(line)
    fflush(stdout)
}

func fail(_ message: String) -> Never {
    print("FAIL \(message)")
    fflush(stdout)
    exit(1)
}

// MARK: - Capture collector

/// Thread-safe sink for the chunks `Audio` delivers, plus the timing needed to prove the 20 ms cadence.
final class Chunks {
    private let lock = NSLock()
    private var storage: [Float] = []
    private var levelSum: Double = 0
    private var levelPeak: Float = 0
    private var count = 0
    private var payloads: Set<Int> = []
    private var lastArrival: Date?
    private var maxGap: Double = 0
    private var byteMismatch = 0

    func add(base64: String, level: Float, expectedPayload: Int) {
        let decoded = Data(base64Encoded: base64) ?? Data()
        let samples = Chunks.decode(decoded)
        lock.lock()
        count += 1
        payloads.insert(decoded.count)
        if decoded.count != expectedPayload { byteMismatch += 1 }
        storage.append(contentsOf: samples)
        levelSum += Double(level)
        levelPeak = max(levelPeak, level)
        let now = Date()
        if let last = lastArrival { maxGap = max(maxGap, now.timeIntervalSince(last)) }
        lastArrival = now
        lock.unlock()
    }

    private static func decode(_ data: Data) -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity(data.count / 2)
        data.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Int16.self)
            for i in 0..<source.count {
                samples.append(Float(Int16(littleEndian: source[i])) / 32768)
            }
        }
        return samples
    }

    struct Summary {
        let count: Int
        let samples: [Float]
        let levelAverage: Double
        let levelPeak: Float
        let payloads: [Int]
        let maxGap: Double
        let byteMismatch: Int
    }

    func summary() -> Summary {
        lock.lock()
        defer { lock.unlock() }
        return Summary(
            count: count,
            samples: storage,
            levelAverage: count > 0 ? levelSum / Double(count) : 0,
            levelPeak: levelPeak,
            payloads: payloads.sorted(),
            maxGap: maxGap,
            byteMismatch: byteMismatch
        )
    }

    func samplesFrom(_ start: Double, to end: Double, rate: Double) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let from = max(0, Int(start * rate))
        let to = min(storage.count, Int(end * rate))
        guard from < to else { return [] }
        return Array(storage[from..<to])
    }

    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}

// MARK: - Tone generator

/// 24 kHz PCM16 mono, in the same 20 ms chunk shape the provider sends, with continuous phase across chunks.
final class Tone {
    let frequency: Double
    let amplitude: Double
    private var phase: Double = 0

    init(frequency: Double, amplitude: Double) {
        self.frequency = frequency
        self.amplitude = amplitude
    }

    func chunks(frames: Int, chunk: Int = 480) -> [String] {
        var result: [String] = []
        var remaining = frames
        while remaining > 0 {
            let count = min(chunk, remaining)
            var samples = [Float](repeating: 0, count: count)
            for i in 0..<count {
                samples[i] = Float(amplitude * sin(phase))
                phase += 2 * Double.pi * frequency / Audio.rate
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
            }
            var data = Data(capacity: count * 2)
            for sample in samples {
                let clamped = max(-1.0, min(1.0, Double(sample)))
                let value = UInt16(bitPattern: Int16((clamped * 32767).rounded()))
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
            result.append(data.base64EncodedString())
            remaining -= count
        }
        return result
    }
}

/// Broadband reference for the canceller: tone plus deterministic white noise.
///
/// A pure tone is rank-one excitation — it constrains the adaptive filter in one direction only, so a 3840-tap
/// filter takes many seconds to lock on and drops out again. Speech is broadband, so the echo measurement uses a
/// broadband reference and reads the tone component out of it to score suppression.
final class Broadband {
    let toneAmplitude: Double
    let noiseAmplitude: Double
    private var phase: Double = 0
    private var seed: UInt64 = 0x243F_6A88_85A3_08D3

    init(toneAmplitude: Double, noiseAmplitude: Double) {
        self.toneAmplitude = toneAmplitude
        self.noiseAmplitude = noiseAmplitude
    }

    func chunks(frames: Int, chunk: Int = 480) -> [String] {
        var result: [String] = []
        var remaining = frames
        while remaining > 0 {
            let count = min(chunk, remaining)
            var data = Data(capacity: count * 2)
            for _ in 0..<count {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let white = Double(Int64(bitPattern: seed >> 11) % 2000) / 1000
                var sample = toneAmplitude * sin(phase) + noiseAmplitude * white
                phase += 2 * Double.pi * 700 / Audio.rate
                if phase > 2 * Double.pi { phase -= 2 * Double.pi }
                sample = max(-1, min(1, sample))
                let value = UInt16(bitPattern: Int16((sample * 32767).rounded()))
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
            result.append(data.base64EncodedString())
            remaining -= count
        }
        return result
    }
}

// MARK: - Driver

@main
struct Driver {
    static var audio: Audio?
    static var chunks = Chunks()
    static let speakingChanges = SpeakingTracker()

    final class SpeakingTracker {
        private let lock = NSLock()
        private var events: [Bool] = []
        private var timestamps: [Double] = []

        func record(_ speaking: Bool) {
            lock.lock()
            events.append(speaking)
            timestamps.append(Date().timeIntervalSince1970)
            lock.unlock()
        }

        var snapshot: (events: [Bool], timestamps: [Double]) {
            lock.lock()
            defer { lock.unlock() }
            return (events, timestamps)
        }
    }

    static func main() {
        try? FileManager.default.createDirectory(
            atPath: "/tmp/audio-evidence", withIntermediateDirectories: true
        )
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let mode = arguments.first else {
            print("usage: linux-audio-driver <devices|capture|playback|aec|cpu|synthetic> [args]")
            exit(2)
        }
        switch mode {
        case "devices":
            devices()
        case "capture":
            start(seconds: Double(arguments.count > 1 ? arguments[1] : "1") ?? 1, mode: .capture)
        case "playback":
            start(seconds: 0, mode: .playback)
        case "aec":
            let on = (arguments.count > 1 ? arguments[1] : "on") != "off"
            start(seconds: Double(arguments.count > 2 ? arguments[2] : "3") ?? 3, mode: .aec(on))
        case "cpu":
            start(seconds: Double(arguments.count > 1 ? arguments[1] : "5") ?? 5, mode: .cpu)
        case "synthetic":
            synthetic()
        case "dsp":
            dsp()
        case "aeccase":
            aecCase(
                delay: Int(arguments.count > 1 ? arguments[1] : "0") ?? 0,
                gain: Float(arguments.count > 2 ? arguments[2] : "0.5") ?? 0.5,
                constrained: (arguments.count > 3 ? arguments[3] : "on") != "off",
                step: Float(arguments.count > 4 ? arguments[4] : "0.35") ?? 0.35,
                partitions: Int(arguments.count > 5 ? arguments[5] : "16") ?? 16
            )
        default:
            print("unknown mode \(mode)")
            exit(2)
        }
    }

    // MARK: Devices

    static func devices() {
        guard let library = PortAudio.shared else { fail("libportaudio not found") }
        _ = library.initialize()
        report("RESULT library=\(library.version) devices=\(library.deviceCount)")
        report("RESULT default_input=\(library.defaultInputDevice) default_output=\(library.defaultOutputDevice)")
        for device in library.devices() {
            let flags = "\(device.maxInputChannels)/\(device.maxOutputChannels)"
            report("DEVICE index=\(device.index) rate=\(Int(device.defaultSampleRate)) channels=\(flags) echo_cancel=\(device.isPlatformEchoCancel) name=\(device.name)")
        }
        // An echo-cancel source is the preferred Linux equivalent of Apple's voice processing; say plainly whether
        // this machine has one, because that decides which canceller is in play.
        let echoCancel = library.devices().filter { $0.isPlatformEchoCancel }
        report("RESULT platform_echo_cancel_devices=\(echoCancel.count)")
        exit(0)
    }

    // MARK: Start

    enum Mode {
        case capture
        case playback
        case aec(Bool)
        case cpu

        var echoCancel: Bool {
            switch self {
            case .aec(let on): return on
            case .cpu: return true
            default: return true
            }
        }
    }

    static func start(seconds: Double, mode: Mode) {
        let audio = Audio(echoCancel: mode.echoCancel)
        self.audio = audio
        audio.onMic = { base64, level in
            chunks.add(base64: base64, level: level, expectedPayload: 960)
        }
        audio.onSpeakingChanged = { speaking in speakingChanges.record(speaking) }
        do {
            try audio.start()
        } catch {
            fail("start() threw: \(error)")
        }
        if let diagnostics = audio.diagnostics {
            report("RESULT library=\(diagnostics.library)")
            report("RESULT input=\"\(diagnostics.inputDevice)\" output=\"\(diagnostics.outputDevice)\"")
            report("RESULT device_rate=\(Int(diagnostics.deviceRate)) chunk_frames=\(diagnostics.chunkFrames)")
            report("RESULT latency_in_ms=\(String(format: "%.1f", diagnostics.inputLatencyMs)) latency_out_ms=\(String(format: "%.1f", diagnostics.outputLatencyMs))")
            report("RESULT aec=\(diagnostics.aecEnabled) aec_tail_ms=\(String(format: "%.0f", diagnostics.aecTailMs))")
        }

        switch mode {
        case .capture:
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finishCapture(audio: audio, seconds: seconds) }
        case .playback:
            runPlayback(audio: audio)
        case .aec(let on):
            runAEC(audio: audio, on: on, seconds: seconds)
        case .cpu:
            runCPU(audio: audio, seconds: seconds)
        }
        dispatchMain()
    }

    // MARK: Capture

    static func finishCapture(audio: Audio, seconds: Double) {
        let summary = chunks.summary()
        let rate = Audio.rate
        let expected = Int(seconds / Audio.chunkSeconds)
        try? writeWav("/tmp/audio-evidence/capture-24k.wav", samples: summary.samples, rate: Int(rate))
        report("RESULT chunks=\(summary.count) expected≈\(expected)")
        report("RESULT captured_frames=\(summary.samples.count) captured_ms=\(String(format: "%.0f", Double(summary.samples.count) * 1000 / rate))")
        report("RESULT payloads=\(summary.payloads) payload_mismatches=\(summary.byteMismatch)")
        report("RESULT level_avg=\(String(format: "%.5f", summary.levelAverage)) level_peak=\(String(format: "%.5f", Double(summary.levelPeak)))")
        report("RESULT max_chunk_gap_ms=\(String(format: "%.1f", summary.maxGap * 1000))")
        let tolerance = max(3, expected / 4)
        if abs(summary.count - expected) > tolerance { fail("chunk count \(summary.count) is not within \(tolerance) of \(expected)") }
        if summary.byteMismatch > 0 { fail("\(summary.byteMismatch) chunks were not 960 bytes (20 ms of PCM16 at 24 kHz)") }
        if summary.samples.count < Int(seconds * rate * 0.75) { fail("captured less than 75% of the requested audio") }
        if summary.maxGap > 0.15 { fail("chunk gap of \(Int(summary.maxGap * 1000)) ms exceeds 150 ms") }
        report("PASS capture delivered \(summary.count) chunks of 20 ms over \(String(format: "%.1f", seconds)) s")
        audio.stop()
        exit(0)
    }

    // MARK: Playback

    static func runPlayback(audio: Audio) {
        let tone = Tone(frequency: 1000, amplitude: 0.25)
        let oneShot = tone.chunks(frames: Int(Audio.rate)) // 1 s
        let start = Date()
        report("RESULT playback_start=\(String(format: "%.3f", 0))")

        // Feed like a provider would: a burst of chunks every 80 ms, well inside the 30 s queue.
        var fed = 0
        var interruptArmed = false
        let feeding = DispatchSource.makeTimerSource(queue: .main)
        feeding.schedule(deadline: .now(), repeating: .milliseconds(60))
        feeding.setEventHandler {
            guard fed < oneShot.count else { feeding.cancel(); return }
            for chunk in oneShot[fed..<min(fed + 4, oneShot.count)] {
                audio.play(base64: chunk, item: "item-1")
            }
            fed = min(fed + 4, oneShot.count)
        }
        feeding.resume()

        // Mid-stream stats while it plays.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            report("RESULT is_speaking_during=\(audio.isSpeaking) out_level=\(String(format: "%.4f", audio.outLevel))")
        }

        // Then a second item that we cut off, to exercise interrupt() and heard-ms accounting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            interruptArmed = true
            let long = Tone(frequency: 1000, amplitude: 0.25).chunks(frames: Int(Audio.rate * 2))
            for chunk in long { audio.play(base64: chunk, item: "item-2") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            let heard = audio.interrupt()
            let elapsed = Date().timeIntervalSince(start) - 2.2
            report("RESULT interrupt_item=\(heard?.item ?? "none") heard_ms=\(heard?.heardMs ?? -1) since_arm_ms=\(String(format: "%.0f", elapsed * 1000))")
            report("RESULT is_speaking_after_interrupt=\(audio.isSpeaking)")
            if let heard {
                // The item started 0.8 s before the interrupt: anything wildly outside that is an accounting bug.
                if heard.heardMs < 300 || heard.heardMs > 1100 {
                    fail("heardMs \(heard.heardMs) is not within 300...1100 ms of the 800 ms played of item-2")
                }
                if heard.item != "item-2" { fail("interrupt reported item \(heard.item), expected item-2") }
            } else {
                fail("interrupt() returned nil while an item was playing")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
            _ = interruptArmed
            let summary = chunks.summary()
            let events = speakingChanges.snapshot.events
            try? writeWav("/tmp/audio-evidence/playback-capture-24k.wav", samples: summary.samples, rate: Int(Audio.rate))
            report("RESULT speaking_events=\(events)")
            report("RESULT out_level_final=\(String(format: "%.4f", audio.outLevel))")
            // Acoustic proof: the mic must hear the tone only while it is being played.
            // Best 200 ms window while clip one plays versus after everything has stopped: the clip start is not
            // sample-exact relative to the capture, so a fixed window would measure whatever happened to land there.
            let window = 0.2
            var playingDB = -200.0
            var t = 0.02
            while t + window <= 1.2 {
                playingDB = max(playingDB, toneLevelDB(chunks.samplesFrom(t, to: t + window, rate: Audio.rate), rate: Audio.rate, frequency: 1000))
                t += window
            }
            var quietDB = -200.0
            t = 2.4
            while t + window <= 2.78 {
                quietDB = max(quietDB, toneLevelDB(chunks.samplesFrom(t, to: t + window, rate: Audio.rate), rate: Audio.rate, frequency: 1000))
                t += window
            }
            report("RESULT mic_tone_quiet_db=\(String(format: "%.1f", quietDB)) mic_tone_playing_db=\(String(format: "%.1f", playingDB))")
            report("RESULT mic_tone_rise_db=\(String(format: "%.1f", playingDB - quietDB))")
            guard events.contains(true) else { fail("onSpeakingChanged(true) never fired") }
            if !events.contains(false) && audio.isSpeaking { fail("playback never finished: still speaking 2.8 s after a 1 s item") }
            if playingDB - quietDB < 12 {
                fail("the rendered tone did not reach the microphone (rise \(String(format: "%.1f", playingDB - quietDB)) dB, need 12)")
            }
            report("PASS playback rendered through the real device and was measured at the microphone")
            audio.stop()
            exit(0)
        }
    }

    // MARK: AEC

    static func runAEC(audio: Audio, on: Bool, seconds: Double) {
        let reference = Broadband(toneAmplitude: 0.14, noiseAmplitude: 0.1)
        let frames = Int(Audio.rate * (seconds + 1.5))
        let block = reference.chunks(frames: frames)
        var fed = 0
        let feeding = DispatchSource.makeTimerSource(queue: .main)
        feeding.schedule(deadline: .now(), repeating: .milliseconds(60))
        feeding.setEventHandler {
            guard fed < block.count else { feeding.cancel(); return }
            for chunk in block[fed..<min(fed + 4, block.count)] {
                audio.play(base64: chunk, item: "aec-reference")
            }
            fed = min(fed + 4, block.count)
        }
        feeding.resume()

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds + 1.5) {
            let summary = chunks.summary()
            let rate = Audio.rate
            // Skip the first 1.5 s: the canceller needs signal to adapt and the streams need to settle. The
            // reference plays for seconds + 1, so this window is entirely inside it.
            let measured = chunks.samplesFrom(1.5, to: 1.5 + seconds, rate: rate)
            let label = on ? "on" : "off"
            try? writeWav("/tmp/audio-evidence/aec-\(label)-capture-24k.wav", samples: summary.samples, rate: Int(rate))
            let diagnostics = audio.diagnostics
            report("RESULT aec=\(label) captured_frames=\(measured.count) chunks=\(summary.count)")
            report("RESULT echo_tone_db=\(String(format: "%.1f", toneLevelDB(measured, rate: rate, frequency: 700)))")
            report("RESULT echo_rms=\(String(format: "%.5f", rms(measured))) peak=\(String(format: "%.4f", peak(measured)))")
            report("RESULT canceller_erle_db=\(String(format: "%.1f", diagnostics?.aecERLEdB ?? 0))")
            if measured.count < Int(seconds * rate * 0.5) { fail("captured only \(measured.count) frames during the AEC run") }
            audio.stop()
            exit(0)
        }
    }

    // MARK: CPU

    static func runCPU(audio: Audio, seconds: Double) {
        let tone = Tone(frequency: 500, amplitude: 0.25)
        // Continuous reference so the canceller is actually adapting: that is the load being measured.
        let block = tone.chunks(frames: Int(Audio.rate * (seconds + 2)))
        var fed = 0
        let feeding = DispatchSource.makeTimerSource(queue: .main)
        feeding.schedule(deadline: .now(), repeating: .milliseconds(60))
        feeding.setEventHandler {
            guard fed < block.count else { feeding.cancel(); return }
            for chunk in block[fed..<min(fed + 4, block.count)] {
                audio.play(base64: chunk, item: "cpu-reference")
            }
            fed = min(fed + 4, block.count)
        }
        feeding.resume()

        // Warm up first, so the measurement is steady-state rather than stream start-up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let before = cpuSeconds()
            let wall = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                let used = cpuSeconds() - before
                let elapsed = Date().timeIntervalSince(wall)
                let summary = chunks.summary()
                let diagnostics = audio.diagnostics
                let percent = used / elapsed * 100
                report("RESULT cpu_seconds=\(String(format: "%.3f", used)) wall_seconds=\(String(format: "%.3f", elapsed))")
                report("RESULT cpu_percent_of_one_core=\(String(format: "%.1f", percent))")
                report("RESULT aec_erle_db=\(String(format: "%.1f", diagnostics?.aecERLEdB ?? 0))")
                report("RESULT chunks=\(summary.count) mic_dropped=\(diagnostics?.micDroppedSamples ?? -1) underruns=\(diagnostics?.playbackUnderruns ?? -1)")
                if summary.count < Int(seconds / Audio.chunkSeconds * 0.6) { fail("mic chunks stalled during the CPU run") }
                report("PASS cpu measured over \(String(format: "%.1f", seconds)) s")
                audio.stop()
                exit(0)
            }
        }
    }

    // MARK: DSP isolation tests

    /// Checks the two numerical building blocks on their own, so a canceller problem can be attributed.
    static func dsp() {
        var problems = 0
        func check(_ name: String, _ condition: Bool, _ detail: String) {
            report("RESULT \(name): \(detail)")
            if !condition { problems += 1 }
        }

        // 1. FFT round trip.
        guard let fft = AudioFFT(n: 512) else { fail("could not create a 512-point FFT") }
        var re = [Float](repeating: 0, count: 512)
        var im = [Float](repeating: 0, count: 512)
        var original = [Float](repeating: 0, count: 512)
        for i in 0..<512 {
            original[i] = Float(sin(Double(i) * 0.37) * 0.6 + cos(Double(i) * 0.11) * 0.3)
            re[i] = original[i]
        }
        let reference = re
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                fft.forward(rp.baseAddress!, ip.baseAddress!)
                fft.inverse(rp.baseAddress!, ip.baseAddress!)
            }
        }
        var maximumError: Float = 0
        for i in 0..<512 { maximumError = max(maximumError, abs(re[i] - reference[i])) }
        check("fft_roundtrip", maximumError < 1e-4, "max abs error \(maximumError)")

        // 2. FFT of a real tone lands in the expected bin.
        let rate = 24000.0
        let frequency = 1000.0
        for i in 0..<512 {
            re[i] = Float(sin(2 * Double.pi * frequency * Double(i) / rate))
            im[i] = 0
        }
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in fft.forward(rp.baseAddress!, ip.baseAddress!) }
        }
        var peakBin = 0
        var peakMagnitude: Float = 0
        for b in 0..<257 {
            let magnitude = (re[b] * re[b] + im[b] * im[b]).squareRoot()
            if magnitude > peakMagnitude { peakMagnitude = magnitude; peakBin = b }
        }
        let expectedBin = Int((frequency / rate * 512).rounded())
        check("fft_tone_bin", abs(peakBin - expectedBin) <= 1, "peak bin \(peakBin), expected \(expectedBin)")
        check("fft_dc_is_quiet", abs(re[0]) < peakMagnitude * 0.05, "dc \(re[0]) vs peak \(peakMagnitude)")

        // 3. Resamplers preserve a tone's level and frequency in both directions.
        if let downsample = AudioResampler(inputRate: 48000, outputRate: 24000),
           let upsample = AudioResampler(inputRate: 24000, outputRate: 48000) {
            var input48 = [Float](repeating: 0, count: 48000)
            for i in 0..<input48.count {
                input48[i] = Float(0.5 * sin(2 * Double.pi * 1000 * Double(i) / 48000))
            }
            var output24 = [Float](repeating: 0, count: 24000)
            var consumed = 0
            var produced = 0
            while consumed + 960 <= input48.count && produced + 480 <= output24.count {
                let made = output24.withUnsafeMutableBufferPointer { out -> Int in
                    input48.withUnsafeBufferPointer { src -> Int in
                        downsample.process(
                            input: src.baseAddress! + consumed, inputCount: 960,
                            output: out.baseAddress! + produced, outputFrames: 480
                        )
                    }
                }
                consumed += 960
                produced += made
                if made == 0 { break }
            }
            let steady = Array(output24[4800..<min(produced, 20000)])
            let downDB = toneLevelDB(steady, rate: 24000, frequency: 1000)
            let inputDB = toneLevelDB(Array(input48[9600..<40000]), rate: 48000, frequency: 1000)
            check("resample_48000_to_24000", abs(downDB - inputDB) < 1.0,
                  "\(String(format: "%.2f", downDB)) dBFS vs \(String(format: "%.2f", inputDB)) dBFS in, \(produced) frames")

            var input24 = [Float](repeating: 0, count: 24000)
            for i in 0..<input24.count {
                input24[i] = Float(0.5 * sin(2 * Double.pi * 1000 * Double(i) / 24000))
            }
            var output48 = [Float](repeating: 0, count: 48000)
            var consumedUp = 0
            var producedUp = 0
            while consumedUp + 480 <= input24.count && producedUp + 960 <= output48.count {
                let made = output48.withUnsafeMutableBufferPointer { out -> Int in
                    input24.withUnsafeBufferPointer { src -> Int in
                        upsample.process(
                            input: src.baseAddress! + consumedUp, inputCount: 480,
                            output: out.baseAddress! + producedUp, outputFrames: 960
                        )
                    }
                }
                consumedUp += 480
                producedUp += made
                if made == 0 { break }
            }
            let steadyUp = Array(output48[9600..<min(producedUp, 40000)])
            let upDB = toneLevelDB(steadyUp, rate: 48000, frequency: 1000)
            let inputUpDB = toneLevelDB(Array(input24[4800..<20000]), rate: 24000, frequency: 1000)
            check("resample_24000_to_48000", abs(upDB - inputUpDB) < 1.0,
                  "\(String(format: "%.2f", upDB)) dBFS vs \(String(format: "%.2f", inputUpDB)) dBFS in, \(producedUp) frames")
        } else {
            check("resamplers", false, "could not build 48k/24k resamplers")
        }

        report(problems == 0 ? "PASS dsp building blocks" : "FAIL \(problems) dsp check(s) failed")
        exit(problems == 0 ? 0 : 1)
    }

    // MARK: Canceller case study

    /// Runs the canceller against a synthetic path with a chosen pure delay and gain, printing the error-to-mic
    /// ratio as it adapts. Used to attribute convergence problems to the algorithm rather than to acoustics.
    static func aecCase(delay: Int, gain: Float, constrained: Bool, step: Float, partitions: Int = 16) {
        let rate = 24000
        guard let aec = AudioEchoCanceller(sampleRate: rate, partitions: partitions, constrained: constrained) else {
            fail("could not create the canceller")
        }
        aec.step = step
        let block = aec.blockSize
        let seconds = 4.0
        let total = Int(Double(rate) * seconds)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var reference = [Float](repeating: 0, count: total)
        for i in 0..<total {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: seed >> 12) % 1000) / 1000 * 0.3
            reference[i] = noise + Float(0.2 * sin(2 * Double.pi * 700 * Double(i) / Double(rate)))
        }
        var mic = [Float](repeating: 0, count: total)
        for i in 0..<total {
            var echo: Float = 0
            if i - delay >= 0 { echo = gain * reference[i - delay] }
            mic[i] = echo
        }
        var clean = [Float](repeating: 0, count: total)
        var index = 0
        var blockIndex = 0
        while index + block <= total {
            var capture = Array(mic[index..<(index + block)])
            let far = Array(reference[index..<(index + block)])
            capture.withUnsafeMutableBufferPointer { micPointer in
                far.withUnsafeBufferPointer { farPointer in
                    aec.process(mic: micPointer.baseAddress!, reference: farPointer.baseAddress!)
                }
            }
            for i in 0..<block { clean[index + i] = capture[i] }
            if blockIndex % 50 == 0 || blockIndex < 5 {
                let micRMS = rms(Array(mic[index..<(index + block)]))
                let errRMS = rms(capture)
                let ratio = errRMS > 0 ? 20 * log10(errRMS / max(micRMS, 1e-12)) : -999
                report("RESULT block=\(blockIndex) mic_rms=\(String(format: "%.6f", micRMS)) err_rms=\(String(format: "%.6f", errRMS)) ratio_db=\(String(format: "%.1f", ratio)) w_max_db=\(String(format: "%.1f", aec.weightPeakDB))")
            }
            index += block
            blockIndex += 1
        }
        let measureFrom = Int(2.0 * Double(rate))
        let echoDB = 20 * log10(max(rms(Array(mic[measureFrom...])), 1e-12))
        let cleanDB = 20 * log10(max(rms(Array(clean[measureFrom...])), 1e-12))
        report("RESULT delay=\(delay) gain=\(gain) constrained=\(constrained) step=\(step) partitions=\(partitions)")
        report("RESULT erle_db=\(String(format: "%.1f", echoDB - cleanDB)) canceller_reported=\(String(format: "%.1f", aec.erleDB))")
        exit(0)
    }

    // MARK: Synthetic

    /// Offline proof of the canceller itself: a known echo path (delay, gain, decaying tail) applied to a generated
    /// reference, with the microphone signal modelled as echo plus noise. No device involved, so this isolates the
    /// algorithm from acoustics.
    static func synthetic() {
        let rate = 24000
        guard let aec = AudioEchoCanceller(sampleRate: rate) else { fail("could not create the canceller") }
        let seconds = 4.0
        let total = Int(Double(rate) * seconds)
        var reference = [Float](repeating: 0, count: total)
        // Broadband excitation: a tone alone can be nulled by a single narrow filter, which would flatter the test.
        var seed: UInt64 = 0x1234_5678
        for i in 0..<total {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: seed >> 11) % 2000) / 1000 * 0.25
            let tone = Float(0.25 * sin(2 * Double.pi * 700 * Double(i) / Double(rate)))
            reference[i] = 0.5 * (noise + tone)
        }
        // Echo path: 20 ms of pure delay, 0.45 gain, three decaying reflections.
        var mic = [Float](repeating: 0, count: total)
        let taps: [(delay: Int, gain: Float)] = [
            (480, 0.45), (720, 0.18), (960, 0.07), (1200, 0.03)
        ]
        for i in 0..<total {
            var echo: Float = 0
            for tap in taps where i - tap.delay >= 0 {
                echo += tap.gain * reference[i - tap.delay]
            }
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Int64(bitPattern: seed >> 11) % 1000) / 1000 * 0.0008
            mic[i] = echo + noise
        }

        let block = aec.blockSize
        var clean = [Float](repeating: 0, count: total)
        var index = 0
        while index + block <= total {
            var capture = Array(mic[index..<(index + block)])
            let far = Array(reference[index..<(index + block)])
            capture.withUnsafeMutableBufferPointer { micPointer in
                far.withUnsafeBufferPointer { farPointer in
                    aec.process(mic: micPointer.baseAddress!, reference: farPointer.baseAddress!)
                }
            }
            for i in 0..<block { clean[index + i] = capture[i] }
            index += block
        }

        // Measure the tail, after the filter has had time to converge.
        let measureFrom = Int(2.0 * Double(rate))
        let echoTail = Array(mic[measureFrom...])
        let cleanTail = Array(clean[measureFrom...])
        let echoDB = 20 * log10(max(rms(echoTail), 1e-12))
        let cleanDB = 20 * log10(max(rms(cleanTail), 1e-12))
        let erle = echoDB - cleanDB
        report("RESULT mode=synthetic tone_db=\(String(format: "%.1f", toneLevelDB(echoTail, rate: Double(rate), frequency: 700)))")
        report("RESULT echo_rms_db=\(String(format: "%.1f", echoDB)) residual_rms_db=\(String(format: "%.1f", cleanDB))")
        report("RESULT erle_db=\(String(format: "%.1f", erle)) canceller_reported_db=\(String(format: "%.1f", aec.erleDB))")
        report("RESULT aec_tail_ms=\(String(format: "%.0f", aec.tailMs)) constrained=\(aec.constrained)")
        if erle < 15 {
            fail("echo return loss enhancement \(String(format: "%.1f", erle)) dB is below the 15 dB target")
        }
        report("PASS synthetic echo path suppressed by \(String(format: "%.1f", erle)) dB")
        exit(0)
    }
}
