import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// One X11 connection on one dedicated thread, with a wake pipe and a timer.
///
/// Both users of Xlib here need the same three things: X calls that never run on the main thread (an Xlib round
/// trip on the main thread is a stalled orb animation), key and configure events delivered as they happen rather
/// than polled for, and a way for the main thread to ask the connection to do something (grab a key, watch a
/// window) without blocking on it. So the connection, the `poll(2)` that multiplexes it with a self-pipe, and the
/// tick all live here.
///
/// `onOpen` runs once on the loop thread with a live display; returning `false` there stops the loop. `onEvents`
/// is called when the connection has input (the caller drains it with `XPending`/`XNextEvent`), and `onTick` on
/// the interval, which `tickInterval` can change from any thread. `perform` queues work for the loop thread.
final class X11Loop {
    private let name: String
    private let lock = NSLock()
    private var commands: [(OpaquePointer) -> Void] = []
    private var interval: TimeInterval = 1
    private var stopping = false
    private var pipeFDs: (read: Int32, write: Int32) = (-1, -1)
    private let finished = DispatchSemaphore(value: 0)
    private var thread: Thread?

    /// Runs on the loop thread, once, right after the display opens.
    var onOpen: ((OpaquePointer) -> Bool)?
    /// Runs on the loop thread when the connection is readable.
    var onEvents: ((OpaquePointer) -> Void)?
    /// Runs on the loop thread on the tick.
    var onTick: ((OpaquePointer) -> Void)?
    /// Runs on the loop thread when X can't be reached at all.
    var onFailure: ((String) -> Void)?

    /// Whether the display is open. Written on the loop thread, read anywhere.
    private(set) var isOpen = false

    /// Seconds between ticks. Cheap to set from the main thread; the loop wakes up to honour it.
    var tickInterval: TimeInterval {
        get {
            lock.lock()
            defer { lock.unlock() }
            return interval
        }
        set {
            let clamped = max(newValue, 0.01)
            lock.lock()
            let changed = interval != clamped
            interval = clamped
            lock.unlock()
            if changed { wake() }
        }
    }

    init(name: String) {
        self.name = name
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return }
        for fd in fds {
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        pipeFDs = (fds[0], fds[1])
    }

    deinit { stop() }

    /// Starts the thread. Idempotent.
    func start() {
        lock.lock()
        let already = thread != nil
        lock.unlock()
        guard !already else { return }
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "herdr-voice.x11.\(name)"
        thread.qualityOfService = .userInitiated
        lock.lock()
        self.thread = thread
        lock.unlock()
        thread.start()
    }

    /// Asks the loop thread to finish, and waits briefly for the display to be closed.
    func stop() {
        lock.lock()
        let running = thread != nil
        if running { stopping = true }
        lock.unlock()
        guard running else { return }
        wake()
        _ = finished.wait(timeout: .now() + 2)
    }

    /// Runs `body` on the loop thread, as soon as it is free.
    func perform(_ body: @escaping (OpaquePointer) -> Void) {
        lock.lock()
        commands.append(body)
        lock.unlock()
        wake()
    }

    private func wake() {
        let fd = lock.locked { pipeFDs.write }
        guard fd >= 0 else { return }
        var byte: UInt8 = 1
        _ = withUnsafeBytes(of: &byte) { Glibc.write(fd, $0.baseAddress, 1) }
    }

    private func drainWakePipe() {
        let fd = lock.locked { pipeFDs.read }
        guard fd >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let got = buffer.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
            if got <= 0 { break }
        }
    }

    private func run() {
        defer { finished.signal() }
        let api = X11API.shared
        guard let api else {
            DispatchQueue.main.async { [onFailure] in onFailure?("libX11 is not installed") }
            return
        }
        guard let display = api.open(nil) else {
            DispatchQueue.main.async { [onFailure] in onFailure?("no X display (\(DisplayName.current))") }
            return
        }
        isOpen = true
        defer {
            isOpen = false
            _ = api.close(display)
        }
        guard onOpen?(display) ?? true else { return }

        let xfd = api.connectionNumber(display)
        let wakeFD = lock.locked { pipeFDs.read }
        var nextTick = Date()
        while true {
            lock.lock()
            let done = stopping
            let pendingCommands = commands
            commands.removeAll()

            lock.unlock()
            if done { break }
            for command in pendingCommands { command(display) }

            // Wake for the X connection, for a command from another thread, or when the next tick is due.
            var descriptors = [
                pollfd(fd: xfd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: wakeFD, events: Int16(POLLIN), revents: 0),
            ]
            let timeout = Int32(max(0, min(nextTick.timeIntervalSinceNow, 1)) * 1000)
            let ready = poll(&descriptors, 2, timeout)
            if ready < 0 && errno != EINTR { break }
            if descriptors[1].revents & Int16(POLLIN) != 0 { drainWakePipe() }
            if descriptors[0].revents & Int16(POLLIN) != 0 && api.pending(display) > 0 {
                onEvents?(display)
            }
            if Date() >= nextTick {
                nextTick = Date().addingTimeInterval(interval)
                onTick?(display)
            }
        }
    }
}

/// What `XOpenDisplay(nil)` resolves to, for a message that says which display wasn't there.
enum DisplayName {
    static var current: String {
        ProcessInfo.processInfo.environment["DISPLAY"].flatMap { $0.isEmpty ? nil : $0 } ?? "unset"
    }
}

/// `withLock` rather than `lock`/`unlock`: Foundation's `NSLocking` has no scoped accessor on this toolchain, and
/// a bare pair is where an early return quietly deadlocks.
private extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
