import CoreFoundation
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// The X11 half of the app lifecycle: a bare CFRunLoop instead of NSApplication.
///
/// herdr-voice on Linux is not a GTK/GNOME app. The orb is its own override-redirect X11 window and the session is
/// driven by Foundation's sockets and timers, so a plain CFRunLoop is all the main thread needs. The orb and the
/// window tracker wait on their own threads and hand results back with `DispatchQueue.main.async`; CFRunLoopRun
/// drains that queue on Linux, the same way NSApplication.run does on macOS (verified against RunLoop timers,
/// main-queue asyncAfter and cross-thread dispatch).
enum AppHost {
    /// Nothing to prepare: there is no activation policy, and the process never takes focus — the orb is an
    /// override-redirect window that the window manager doesn't manage, so keystrokes keep reaching the terminal.
    static func prepareForLaunch() {}

    static func runMainLoop() -> Never {
        CFRunLoopRun()
        exit(0)
    }

    static func terminate() -> Never {
        exit(0)
    }
}
