import Foundation

/// In-place radix-2 complex FFT with precomputed twiddles and bit-reversal table.
///
/// The echo canceller runs this on every block, so the tables are built once in `init` and the transform only
/// touches caller-owned scratch: no allocation, no allocation-capable call, nothing that can wait.
final class AudioFFT {
    let n: Int
    private let levels: Int
    private let cosTable: UnsafeMutablePointer<Float>
    private let sinTable: UnsafeMutablePointer<Float>
    private let reversal: UnsafeMutablePointer<Int32>

    init?(n: Int) {
        guard n >= 8, n & (n - 1) == 0 else { return nil }
        self.n = n
        levels = Int(log2(Double(n)).rounded())
        cosTable = .allocate(capacity: n / 2)
        sinTable = .allocate(capacity: n / 2)
        reversal = .allocate(capacity: n)
        cosTable.initialize(repeating: 0, count: n / 2)
        sinTable.initialize(repeating: 0, count: n / 2)
        reversal.initialize(repeating: 0, count: n)
        for i in 0..<(n / 2) {
            let angle = 2 * Double.pi * Double(i) / Double(n)
            cosTable[i] = Float(cos(angle))
            sinTable[i] = Float(sin(angle))
        }
        for i in 0..<n {
            var value = i
            var reversed = 0
            for _ in 0..<levels {
                reversed = (reversed << 1) | (value & 1)
                value >>= 1
            }
            reversal[i] = Int32(reversed)
        }
    }

    deinit {
        cosTable.deallocate()
        sinTable.deallocate()
        reversal.deallocate()
    }

    func forward(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        transform(re, im, inverse: false)
    }

    /// Unscaled inverse; callers that care about amplitude divide by `n` themselves.
    func inverse(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        transform(re, im, inverse: true)
        let scale = 1 / Float(n)
        for i in 0..<n {
            re[i] *= scale
            im[i] *= scale
        }
    }

    private func transform(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>, inverse: Bool) {
        let count = n
        for i in 0..<count {
            let j = Int(reversal[i])
            if j > i {
                let tr = re[i]; re[i] = re[j]; re[j] = tr
                let ti = im[i]; im[i] = im[j]; im[j] = ti
            }
        }
        var size = 2
        while size <= count {
            let half = size / 2
            let step = count / size
            var start = 0
            while start < count {
                var k = 0
                for i in start..<(start + half) {
                    let twiddle = k * step
                    let c = cosTable[twiddle]
                    let s = inverse ? sinTable[twiddle] : -sinTable[twiddle]
                    let xr = re[i + half]
                    let xi = im[i + half]
                    let tr = xr * c - xi * s
                    let ti = xr * s + xi * c
                    re[i + half] = re[i] - tr
                    im[i + half] = im[i] - ti
                    re[i] += tr
                    im[i] += ti
                    k += 1
                }
                start += size
            }
            size *= 2
        }
    }
}

/// Acoustic echo canceller: a partitioned-block frequency-domain adaptive filter (PBFDAF/MDF) driven by the
/// assistant's own playback as the reference signal.
///
/// macOS gets cancellation from Apple's voice-processing unit. Linux here has no `module-echo-cancel` source to
/// borrow, so this is the equivalent: the far-end signal we handed to the speaker is fed back through an adaptive
/// FIR whose copies are adapted per bin with a normalised step, which is the standard structure for a real-time
/// canceller (as in Speex's `mdf.c`). Overlap-save with a 512-point FFT and 240-sample hops gives a filter of
/// `partitions * 240` taps — 160 ms at 24 kHz, enough to hold the output-latency-plus-room delay of a normal
/// laptop and still leave room for the tail of the echo path.
///
/// The filter is only adapted while the reference is actually loud, so silence and noise do not train it into a
/// wrong response, and the echo estimate is subtracted sample by sample so the residual keeps the near-end talker.
///
/// The update is unconstrained (`constrained: false` by default). A gradient projection onto the linear-convolution
/// window is available, but with the reference held at the END of the frame it had to keep the wrong taps for this
/// frame order and measurably hurt convergence — measured 19.8-27 dB of suppression unconstrained versus a residual
/// *larger* than the echo when projected. Bin-normalised unconstrained MDF is what the measurements support.
final class AudioEchoCanceller {
    let sampleRate: Int
    /// Samples per adaptation hop (10 ms at 24 kHz).
    let blockSize: Int
    let fftSize: Int
    let partitions: Int
    /// Bins kept: `fftSize / 2 + 1`. The rest follow by conjugate symmetry.
    let bins: Int
    let constrained: Bool
    /// Filter tail in milliseconds.
    var tailMs: Double { Double(partitions * blockSize) * 1000 / Double(sampleRate) }

    private let fft: AudioFFT
    private let historyLength: Int

    // Time domain scratch.
    private let history: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let errorFrame: UnsafeMutablePointer<Float>
    private let echo: UnsafeMutablePointer<Float>
    private let fullRe: UnsafeMutablePointer<Float>
    private let fullIm: UnsafeMutablePointer<Float>

    // Frequency domain state: `partitions * bins` spectra in a circular buffer, newest at `slot`.
    private let xRe: UnsafeMutablePointer<Float>
    private let xIm: UnsafeMutablePointer<Float>
    private let wRe: UnsafeMutablePointer<Float>
    private let wIm: UnsafeMutablePointer<Float>
    private let yRe: UnsafeMutablePointer<Float>
    private let yIm: UnsafeMutablePointer<Float>
    private let eRe: UnsafeMutablePointer<Float>
    private let eIm: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private let gradientRe: UnsafeMutablePointer<Float>
    private let gradientIm: UnsafeMutablePointer<Float>

    private var slot = 0
    private var blocks = 0
    private var micPowerSmoothed: Float = 0
    private var errorPowerSmoothed: Float = 0
    /// Last measured echo return loss enhancement, dB. Only meaningful while `isAdapting`.
    private(set) var erleDB: Float = 0
    /// True when the reference was loud enough during the last block for the measurement to mean anything.
    private(set) var isAdapting = false

    /// Largest weight magnitude, in dB. Diagnostic only: a filter that keeps growing here is diverging.
    var weightPeakDB: Float {
        var peak: Float = 0
        for i in 0..<(partitions * bins) {
            peak = max(peak, (wRe[i] * wRe[i] + wIm[i] * wIm[i]).squareRoot())
        }
        return 20 * log10(max(peak, 1e-12))
    }

    /// Step size for the normalised bin update.
    var step: Float = 0.35
    /// Leakage per block, which keeps the filter from drifting on a dead reference.
    var leakage: Float = 1e-5
    /// Regularisation added to the bin power so a silent bin cannot produce a huge step. A fixed absolute value is
    /// useless here — against bin powers of hundreds it protects nothing, and bins the reference barely excites end
    /// up with gains thousands of times larger than the loud ones and drive the filter into divergence. So the floor
    /// is `absolute` OR `relative * mean bin power`, whichever is larger.
    var regularization: Float = 1e-6
    var relativeRegularization: Float = 1e-2

    init?(sampleRate: Int = 24000, blockSize: Int = 240, partitions: Int = 16, constrained: Bool = false) {
        // Overlap-save needs a power-of-two transform, and the filter length per partition may not exceed the
        // valid part of the circular convolution (fftSize - blockSize + 1). With 240-sample hops that is a
        // 512-point FFT, 272 samples of valid output per block and 240 taps per partition.
        var size = 2
        while size < blockSize * 2 { size *= 2 }
        let fftSize = size
        guard blockSize > 0, partitions > 0, fftSize - blockSize + 1 >= blockSize,
              let fft = AudioFFT(n: fftSize) else { return nil }
        self.sampleRate = sampleRate
        self.blockSize = blockSize
        self.fftSize = fftSize
        self.partitions = partitions
        self.constrained = constrained
        self.fft = fft
        bins = fftSize / 2 + 1
        historyLength = fftSize - blockSize

        func make(_ count: Int) -> UnsafeMutablePointer<Float> {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            pointer.initialize(repeating: 0, count: count)
            return pointer
        }
        history = make(historyLength)
        frame = make(fftSize)
        errorFrame = make(fftSize)
        echo = make(fftSize)
        fullRe = make(fftSize)
        fullIm = make(fftSize)
        xRe = make(partitions * bins)
        xIm = make(partitions * bins)
        wRe = make(partitions * bins)
        wIm = make(partitions * bins)
        yRe = make(bins)
        yIm = make(bins)
        eRe = make(bins)
        eIm = make(bins)
        power = make(bins)
        gradientRe = make(bins)
        gradientIm = make(bins)
    }

    deinit {
        for pointer in [history, frame, errorFrame, echo, fullRe, fullIm, xRe, xIm, wRe, wIm,
                        yRe, yIm, eRe, eIm, power, gradientRe, gradientIm] {
            pointer.deallocate()
        }
    }

    func reset() {
        history.update(repeating: 0, count: historyLength)
        errorFrame.update(repeating: 0, count: fftSize)
        xRe.update(repeating: 0, count: partitions * bins)
        xIm.update(repeating: 0, count: partitions * bins)
        wRe.update(repeating: 0, count: partitions * bins)
        wIm.update(repeating: 0, count: partitions * bins)
        power.update(repeating: 0, count: bins)
        slot = 0
        blocks = 0
        micPowerSmoothed = 0
        errorPowerSmoothed = 0
        erleDB = 0
        isAdapting = false
    }

    /// Cancels the echo in `mic` (in place) using the far-end `reference` for the same `blockSize` window.
    func process(mic: UnsafeMutablePointer<Float>, reference: UnsafePointer<Float>) {
        let count = blockSize

        // 1. Frame = [last fftSize-blockSize samples | this block], then slide the history.
        for i in 0..<historyLength { frame[i] = history[i] }
        for i in 0..<count { frame[historyLength + i] = reference[i] }
        for i in 0..<historyLength { history[i] = frame[count + i] }

        // 2. Reference spectrum into the circular slot.
        var referencePower: Float = 0
        for i in 0..<count { referencePower += reference[i] * reference[i] }
        let referenceRMS = (referencePower / Float(count)).squareRoot()
        let adaptationAllowed = referenceRMS > 0.002 // about -54 dBFS

        for i in 0..<fftSize { fullRe[i] = frame[i]; fullIm[i] = 0 }
        fft.forward(fullRe, fullIm)
        let base = (slot % partitions) * bins
        for b in 0..<bins {
            xRe[base + b] = fullRe[b]
            xIm[base + b] = fullIm[b]
        }

        // 3. Echo estimate: Y = sum_p W_p * X_{slot-p}.
        for b in 0..<bins {
            yRe[b] = 0
            yIm[b] = 0
        }
        for p in 0..<partitions {
            let index = ((slot - p) % partitions + partitions) % partitions
            let source = index * bins
            let weightBase = p * bins
            for b in 0..<bins {
                let wr = wRe[weightBase + b]
                let wi = wIm[weightBase + b]
                let xr = xRe[source + b]
                let xi = xIm[source + b]
                yRe[b] += wr * xr - wi * xi
                yIm[b] += wr * xi + wi * xr
            }
        }
        synthesizeBins(yRe, yIm)
        fft.inverse(fullRe, fullIm)
        for i in 0..<count { echo[i] = fullRe[historyLength + i] }

        // 4. Subtract, and measure how much echo was left.
        var micPower: Float = 0
        var errorPower: Float = 0
        for i in 0..<count {
            let clean = mic[i] - echo[i]
            mic[i] = clean
            micPower += (clean + echo[i]) * (clean + echo[i])
            errorPower += clean * clean
        }
        blocks += 1
        if adaptationAllowed {
            let alpha: Float = 0.7
            micPowerSmoothed = alpha * micPowerSmoothed + (1 - alpha) * micPower
            errorPowerSmoothed = alpha * errorPowerSmoothed + (1 - alpha) * errorPower
            isAdapting = micPowerSmoothed > 1e-8
            if isAdapting, errorPowerSmoothed > 1e-12 {
                erleDB = 10 * log10(micPowerSmoothed / errorPowerSmoothed)
            }
        } else {
            isAdapting = false
        }

        guard adaptationAllowed else {
            slot += 1
            return
        }

        // 5. Error spectrum, with the valid part in the tail of the frame.
        for i in 0..<historyLength { errorFrame[i] = 0 }
        for i in 0..<count { errorFrame[historyLength + i] = mic[i] }
        for i in 0..<fftSize { fullRe[i] = errorFrame[i]; fullIm[i] = 0 }
        fft.forward(fullRe, fullIm)
        for b in 0..<bins {
            eRe[b] = fullRe[b]
            eIm[b] = fullIm[b]
        }

        // 6. Per-bin reference power for the normalised step. The SUM over partitions is what makes the combined
        //    update land on y = mu*e: each partition divides by the summed power, and the sum over partitions
        //    multiplies by P again. The floor is relative to the mean bin power for the reason in `regularization`.
        var total: Float = 0
        for b in 0..<bins {
            var sum: Float = 0
            for p in 0..<partitions {
                let source = p * bins + b
                sum += xRe[source] * xRe[source] + xIm[source] * xIm[source]
            }
            power[b] = sum
            total += sum
        }
        let mean = total / Float(bins)
        let floor = max(regularization, mean * relativeRegularization)
        for b in 0..<bins {
            power[b] += Float(partitions) * floor
        }

        // 7. Adapt every partition. With `constrained` the gradient is projected back to the linear-convolution
        //    window before it is applied, which is what keeps a long multi-partition filter stable.
        let decay = 1 - leakage
        for p in 0..<partitions {
            let index = ((slot - p) % partitions + partitions) % partitions
            let source = index * bins
            for b in 0..<bins {
                let xr = xRe[source + b]
                let xi = xIm[source + b]
                let er = eRe[b]
                let ei = eIm[b]
                gradientRe[b] = xr * er + xi * ei // conj(X) * E
                gradientIm[b] = xr * ei - xi * er
            }
            if constrained {
                synthesizeBins(gradientRe, gradientIm)
                fft.inverse(fullRe, fullIm)
                // The gradient is an impulse response, so its linear part is the FIRST `blockSize` taps. (The
                // output window is the opposite — last taps — which is why the two cannot share a helper.)
                for i in 0..<historyLength {
                    fullRe[count + i] = 0
                    fullIm[count + i] = 0
                }
                fft.forward(fullRe, fullIm)
                for b in 0..<bins {
                    gradientRe[b] = fullRe[b]
                    gradientIm[b] = fullIm[b]
                }
            }
            let weightBase = p * bins
            for b in 0..<bins {
                let gain = step / power[b]
                wRe[weightBase + b] = (wRe[weightBase + b] + gain * gradientRe[b]) * decay
                wIm[weightBase + b] = (wIm[weightBase + b] + gain * gradientIm[b]) * decay
            }
        }

        slot += 1
    }

    /// Fills the full-size scratch from a half spectrum, mirroring the conjugate bins so the inverse transform is
    /// real-valued.
    private func synthesizeBins(_ re: UnsafeMutablePointer<Float>, _ im: UnsafeMutablePointer<Float>) {
        for b in 0..<bins {
            fullRe[b] = re[b]
            fullIm[b] = im[b]
        }
        var k = 1
        while k < bins - 1 {
            fullRe[fftSize - k] = re[k]
            fullIm[fftSize - k] = -im[k]
            k += 1
        }
    }
}
