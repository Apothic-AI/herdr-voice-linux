import Foundation

/// Streaming polyphase resampler with preallocated state.
///
/// The device runs at its own native rate (48 kHz here) while the provider wire is 24 kHz, so both directions need
/// a converter that costs nothing per block. The ratio is kept exact — `up`/`down` come from the gcd of the two
/// integer rates — so 48 kHz to 24 kHz is a 2:1 half-band and 44.1 kHz to 24 kHz is 80:147, with no accumulating
/// rounding error and no drift against the device clock.
///
/// Filtering is a windowed-sinc prototype of `up * tapsPerPhase` taps; phase `p` uses every `up`-th tap, which is
/// exactly the zero-stuffed convolution evaluated only where it is needed.
final class AudioResampler {
    let inputRate: Double
    let outputRate: Double
    /// Upsampling factor of the exact ratio.
    let up: Int
    /// Downsampling factor of the exact ratio.
    let down: Int
    let tapsPerPhase: Int

    private let filter: UnsafeMutablePointer<Float>
    private let history: UnsafeMutablePointer<Float>
    /// The history ring has to hold the incoming block as well as the filter taps, or a block larger than the
    /// filter wraps the ring and each sample overwrites a neighbour that is still needed.
    private let historyCapacity: Int
    /// Total input samples consumed so far; input `i` lives at `history[i % historyCapacity]`.
    private var consumedInputs: Int64 = 0
    /// Absolute position in the upsampled stream.
    private var phase: Int64 = 0

    init?(inputRate: Double, outputRate: Double, tapsPerPhase: Int = 24, maxBlock: Int = 8192) {
        let input = Int(inputRate.rounded())
        let output = Int(outputRate.rounded())
        guard input > 0, output > 0, tapsPerPhase >= 4, maxBlock >= 64 else { return nil }
        guard abs(Double(input) - inputRate) < 0.5, abs(Double(output) - outputRate) < 0.5 else { return nil }

        self.inputRate = Double(input)
        self.outputRate = Double(output)
        self.tapsPerPhase = tapsPerPhase
        let divisor = AudioResampler.gcd(input, output)
        up = output / divisor
        down = input / divisor
        guard up <= 512, down <= 512 else { return nil }

        let length = tapsPerPhase * up
        filter = .allocate(capacity: length)
        filter.initialize(repeating: 0, count: length)
        historyCapacity = maxBlock + tapsPerPhase
        history = .allocate(capacity: historyCapacity)
        history.initialize(repeating: 0, count: historyCapacity)

        // Lowpass at the lower of the two Nyquists, scaled so each phase has unity DC gain. With up == 1 and
        // down == 2 this is the usual half-band; with up == 2 it interpolates without a level change.
        let cutoff = 0.5 / Double(max(up, down))
        let center = Double(length - 1) / 2
        for n in 0..<length {
            let offset = Double(n) - center
            let t = 2 * cutoff * offset
            let sinc = abs(t) < 1e-9 ? 1.0 : sin(.pi * t) / (.pi * t)
            let window = 0.42
                - 0.5 * cos(2 * .pi * Double(n) / Double(length - 1))
                + 0.08 * cos(4 * .pi * Double(n) / Double(length - 1))
            filter[n] = Float(Double(up) * 2 * cutoff * sinc * window)
        }
        // Normalise each phase to unity DC so a constant input stays constant, which also removes the tiny
        // amplitude ripple a windowed sinc leaves between phases.
        for p in 0..<up {
            var sum: Float = 0
            var k = 0
            while p + k * up < length {
                sum += filter[p + k * up]
                k += 1
            }
            guard abs(sum) > 0.25 else { continue }
            k = 0
            while p + k * up < length {
                filter[p + k * up] /= sum
                k += 1
            }
        }
    }

    deinit {
        filter.deallocate()
        history.deallocate()
    }

    /// How many input samples `process` needs to emit exactly `frames` output samples (0 when nothing is
    /// needed because output is already owed from earlier input).
    func inputNeeded(forOutputFrames frames: Int) -> Int {
        guard frames > 0 else { return 0 }
        let last = phase + Int64(frames - 1) * Int64(down)
        let lastIndex = last / Int64(up)
        return max(0, Int(lastIndex + 1 - consumedInputs))
    }

    /// Converts `inputCount` new input samples, writing at most `outputFrames` output samples.
    ///
    /// Returns how many were written; the caller fills any remainder with silence. Input that arrives while the
    /// resampler has no output demand is kept in the history ring and used by the next call, so blocks line up
    /// across calls without a gap.
    @discardableResult
    func process(
        input: UnsafePointer<Float>,
        inputCount: Int,
        output: UnsafeMutablePointer<Float>,
        outputFrames: Int
    ) -> Int {
        guard outputFrames > 0 else { return 0 }
        let taps = tapsPerPhase
        let capacity = historyCapacity
        for i in 0..<max(0, inputCount) {
            history[Int(consumedInputs % Int64(capacity))] = input[i]
            consumedInputs += 1
        }
        let available = consumedInputs
        var produced = 0
        while produced < outputFrames {
            let index = phase / Int64(up)
            guard index < available else { break }
            let p = Int(phase % Int64(up))
            var accumulator: Float = 0
            for k in 0..<taps {
                let sample = index - Int64(k)
                guard sample >= 0, sample < available else { break }
                accumulator += filter[p + k * up] * history[Int(sample % Int64(capacity))]
            }
            output[produced] = accumulator
            produced += 1
            phase += Int64(down)
        }
        return produced
    }

    /// Drops all state. Used when playback is abandoned mid-stream.
    func reset() {
        history.update(repeating: 0, count: historyCapacity)
        consumedInputs = 0
        phase = 0
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = a
        var y = b
        while y != 0 {
            let t = x % y
            x = y
            y = t
        }
        return x
    }
}
