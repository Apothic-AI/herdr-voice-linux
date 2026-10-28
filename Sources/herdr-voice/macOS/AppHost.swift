import AppKit

/// AppKit's half of the app lifecycle. See Linux/AppHost.swift for the X11 implementation.
///
/// The only parts of `main.swift` that aren't shared are these three: how the process presents itself at launch,
/// which run loop owns the main thread, and how it quits.
enum AppHost {
    static func prepareForLaunch() {
        // Whatever was in front when we were launched: normally the terminal running Herdr.
        let launchedFrom = NSWorkspace.shared.frontmostApplication
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        // An accessory app can still be activated at launch; it then holds focus with no window to type into, so
        // keystrokes stop reaching the terminal (and the pinned orb hides). Hand focus straight back.
        DispatchQueue.main.async {
            guard NSApp.isActive, let previous = launchedFrom, previous.processIdentifier != getpid() else { return }
            NSApp.yieldActivation(to: previous)
            previous.activate()
        }
    }

    /// `NSApplication.run`: the Cocoa event loop, which is also where the orb's display link and timers fire.
    static func runMainLoop() -> Never {
        NSApplication.shared.run()
        exit(0)
    }

    static func terminate() -> Never {
        NSApp.terminate(nil)
        exit(0)
    }
}
