import Foundation

#if canImport(os)
import os
#endif

#if canImport(Glibc)
import Glibc
#endif

/// A small, non-allocating mutex.
///
/// `os_unfair_lock` is Darwin-only and Swift's `Mutex`/atomics need newer platforms than this package targets, so
/// the audio paths use this instead: os_unfair_lock on Apple platforms, an adaptive pthread mutex on Linux. Both
/// are safe from a real-time audio callback as long as the critical section stays short.
public final class UnfairLock {
    #if canImport(os)
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    public init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit { lock.deallocate() }

    /// Never blocks: returns false when someone else holds the lock.
    public func tryLock() -> Bool { os_unfair_lock_trylock(lock) }
    public func lock() { os_unfair_lock_lock(lock) }
    public func unlock() { os_unfair_lock_unlock(lock) }
    #else
    private var mutex = pthread_mutex_t()

    public init() {
        var attr = pthread_mutexattr_t()
        pthread_mutexattr_init(&attr)
        // A trylock that doesn't spin, and no priority inversion: the writer must never stall the audio thread.
        pthread_mutexattr_settype(&attr, Int32(PTHREAD_MUTEX_ERRORCHECK))
        pthread_mutex_init(&mutex, &attr)
        pthread_mutexattr_destroy(&attr)
    }

    deinit { pthread_mutex_destroy(&mutex) }

    /// Never blocks: returns false when someone else holds the lock.
    public func tryLock() -> Bool { pthread_mutex_trylock(&mutex) == 0 }
    public func lock() { pthread_mutex_lock(&mutex) }
    public func unlock() { pthread_mutex_unlock(&mutex) }
    #endif
}

/// A value behind a lock, with a scoped accessor. The portable stand-in for `OSAllocatedUnfairLock`.
public final class Locked<Value> {
    private let lock = UnfairLock()
    private var value: Value

    public init(_ value: Value) { self.value = value }

    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Non-blocking variant: nil when the lock was busy, so a real-time writer can drop the work instead of waiting.
public extension Locked {
    func tryWithLock<Result>(_ body: (inout Value) -> Result) -> Result? {
        guard lock.tryLock() else { return nil }
        defer { lock.unlock() }
        return body(&value)
    }
}
