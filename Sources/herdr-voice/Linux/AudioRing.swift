import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Single-producer/single-consumer float ring for the real-time audio path.
///
/// PortAudio's callbacks run on their own threads; the writer is one of them and the reader is either the mic
/// worker or (for the playback reference) another callback. A lock is not an option in a callback, and a
/// `tryLock` that drops audio is worse than no lock at all, so the two sides share only two monotonically
/// increasing 64-bit indices and never wait for each other.
///
/// Ordering: x86-64 is strongly ordered, so an aligned 8-byte load or store is atomic and producer stores reach
/// the consumer in program order. Where the architecture does not promise that, `fence()` falls back to a short
/// mutex round-trip, which is correct on any machine and only costs anything off x86.
final class AudioSampleRing {
    let capacity: Int

    private let storage: UnsafeMutablePointer<Float>
    /// Total samples produced (writer only).
    private let produced: UnsafeMutablePointer<Int64>
    /// Total samples consumed (reader only).
    private let consumed: UnsafeMutablePointer<Int64>

    /// Samples the writer had to throw away because the reader fell behind. Advisory, read from other threads.
    let overflows = UnsafeMutablePointer<Int64>.allocate(capacity: 1)

    #if !arch(x86_64) && !arch(i386)
    private let fenceLock = UnfairLock()
    #endif

    init(capacity: Int) {
        self.capacity = max(64, capacity)
        storage = .allocate(capacity: self.capacity)
        storage.initialize(repeating: 0, count: self.capacity)
        produced = .allocate(capacity: 1)
        consumed = .allocate(capacity: 1)
        produced.initialize(to: 0)
        consumed.initialize(to: 0)
        overflows.initialize(to: 0)
    }

    deinit {
        storage.deallocate()
        produced.deallocate()
        consumed.deallocate()
        overflows.deallocate()
    }

    @inline(__always) private func fence() {
        #if arch(x86_64) || arch(i386)
        // Strongly ordered: nothing to emit.
        #else
        fenceLock.lock()
        fenceLock.unlock()
        #endif
    }

    private var writeIndex: Int64 { produced.pointee }
    private var readIndex: Int64 { consumed.pointee }

    var available: Int {
        Int(writeIndex - readIndex)
    }

    /// Producer side. Copies what fits and counts the rest as an overflow; never blocks.
    @discardableResult
    func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let write = writeIndex
        let free = capacity - Int(write - readIndex)
        let accepted = min(count, max(0, free))
        var slot = Int(write % Int64(capacity))
        for i in 0..<accepted {
            storage[slot] = source[i]
            slot += 1
            if slot == capacity { slot = 0 }
        }
        if accepted < count { overflows.pointee += Int64(count - accepted) }
        fence()
        produced.pointee = write + Int64(accepted)
        return accepted
    }

    /// Reader side: copy up to `count` samples without consuming them.
    @discardableResult
    func peek(_ destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let read = readIndex
        let have = min(count, Int(writeIndex - read))
        guard have > 0 else { return 0 }
        var slot = Int(read % Int64(capacity))
        for i in 0..<have {
            destination[i] = storage[slot]
            slot += 1
            if slot == capacity { slot = 0 }
        }
        return have
    }

    /// Reader side: drop `count` samples previously peeked.
    func skip(_ count: Int) {
        guard count > 0 else { return }
        let read = readIndex
        let dropped = min(count, Int(writeIndex - read))
        fence()
        consumed.pointee = read + Int64(dropped)
    }

    /// Reader side: copy up to `count` samples and consume them.
    @discardableResult
    func read(_ destination: UnsafeMutablePointer<Float>, count: Int) -> Int {
        let copied = peek(destination, count: count)
        skip(copied)
        return copied
    }

    /// Reader side: the `count` samples ending `lag` samples behind the live edge.
    ///
    /// The echo canceller needs the reference signal as it was heard a fixed delay ago, not the newest audio, so
    /// this window is taken from behind the writer instead of from the read cursor. Reading it advances the
    /// cursor to just before the window, which keeps the ring from filling with audio nobody will ask for again.
    @discardableResult
    func copyLatest(_ destination: UnsafeMutablePointer<Float>, count: Int, lag: Int) -> Bool {
        let write = writeIndex
        let end = write - Int64(max(0, lag))
        let start = end - Int64(count)
        guard count > 0, start >= readIndex, end <= write else { return false }
        var slot = Int(((start % Int64(capacity)) + Int64(capacity)) % Int64(capacity))
        for i in 0..<count {
            destination[i] = storage[slot]
            slot += 1
            if slot == capacity { slot = 0 }
        }
        fence()
        consumed.pointee = max(readIndex, start)
        return true
    }

    /// Both sides must be stopped. Used when a stream is (re)started or playback is flushed.
    func reset() {
        fence()
        consumed.pointee = 0
        produced.pointee = 0
        overflows.pointee = 0
    }
}

/// Small DSP helpers that both the capture and playback paths use.
enum AudioDSP {
    @inline(__always)
    static func rms(_ samples: UnsafePointer<Float>, _ count: Int) -> Float {
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count {
            let value = samples[i]
            sum += value * value
        }
        return (sum / Float(count)).squareRoot()
    }

    @inline(__always)
    static func peak(_ samples: UnsafePointer<Float>, _ count: Int) -> Float {
        var peak: Float = 0
        for i in 0..<count {
            let value = abs(samples[i])
            if value > peak { peak = value }
        }
        return peak
    }

    /// Base64 of little-endian PCM16, which is what every provider wire in this app carries.
    static func pcm16Base64(_ samples: UnsafePointer<Float>, _ count: Int) -> String {
        var data = Data(count: count * 2)
        data.withUnsafeMutableBytes { raw in
            guard let out = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<count {
                let clamped = max(-1, min(1, samples[i]))
                // 32767 rather than 32768: symmetric, and +1.0 must not wrap to -32768.
                let value = Int16((clamped * 32767).rounded())
                let bits = UInt16(bitPattern: value)
                out[i * 2] = UInt8(bits & 0xFF)
                out[i * 2 + 1] = UInt8(bits >> 8)
            }
        }
        return data.base64EncodedString()
    }
}
