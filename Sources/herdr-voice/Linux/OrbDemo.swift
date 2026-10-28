import CoreFoundation
import Foundation
import HerdrVoiceCore

/// The `--orb-demo` affordances that have to live on this side of the seam.
///
/// `main.swift` drives the demo from the real audio path: it cycles the five moods every four seconds, hands the orb
/// the live mic level, and plays a synthesised "speech" burst for the speaking phase. The Linux audio backend is
/// still a stub on this branch, so two things would otherwise go wrong, and both are handled here rather than in
/// `main.swift`:
///
/// 1. `Audio.start()` throws, and the demo's `catch` exits the process a moment after the orb was created. By then
///    the orb's frame thread is already running, so in demo mode the exit is bridged and the process keeps showing
///    the orb instead of dying with the audio backend. Nothing else is affected: the bridge is armed only for
///    `--orb-demo`, and only after the orb is on screen.
/// 2. With no capture and no playback every level is 0, so all five moods would draw as a still sphere. Once the
///    audio path has been silent for a couple of seconds the demo supplies its own envelopes — the syllabic shape a
///    voice would have produced — so the demo still shows the design it exists to show. A real level, the moment one
///    appears, immediately takes over again.
enum OrbDemo {
    static var isDemo: Bool { CommandLine.arguments.contains("--orb-demo") }

    /// Set by `Orb` once its window is mapped: only then is there something worth keeping alive.
    private static let stateLock = NSLock()
    private static var orbIsOnScreen = false
    private static var bridgeArmed = false
    private static var silentFor = 0.0
    private static var synthesising = false
    private static var announced = false

    static var orbOnScreen: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return orbIsOnScreen
        }
        set {
            stateLock.lock()
            orbIsOnScreen = newValue
            stateLock.unlock()
        }
    }

    /// Keeps a `--orb-demo` process running when the demo's own `Audio.start()` fails.
    ///
    /// `main.swift`'s demo branch logs the failure and calls `exit(1)`; the orb is already animating at that point,
    /// and a stubbed audio backend is not a reason to show nothing at all. The handler is a bridge for exactly that
    /// exit, gated on the demo flag and on the orb having reached the screen, so the real app path is untouched.
    static func armExitBridge() {
        guard isDemo else { return }
        stateLock.lock()
        let already = bridgeArmed
        bridgeArmed = true
        stateLock.unlock()
        guard !already else { return }
        atexit {
            guard OrbDemo.isDemo, OrbDemo.orbOnScreen else { return }
            log("⚠ orb demo: the Linux audio backend is not available; keeping the orb on screen with synthesised levels")
            // Drained rather than slept: the orb's click and menu actions are dispatched to the main queue.
            CFRunLoopRun()
        }
    }

    /// Replaces silent demo levels with the envelopes a working audio path would have produced.
    ///
    /// A real capture is never exactly 0.0 for two seconds, so an actual level — now or later — wins immediately and
    /// silences the synthesis for good.
    static func levels(mood: Mood, mic: Float, voice: Float, dt: Double, time: Double) -> (mic: Float, voice: Float) {
        stateLock.lock()
        if mic > 0 || voice > 0 {
            silentFor = 0
            if synthesising { synthesising = false }
            stateLock.unlock()
            return (mic, voice)
        }
        silentFor += dt
        if silentFor > 2, !synthesising {
            synthesising = true
            if !announced {
                announced = true
                log("⚠ orb demo: no audio levels from the Linux backend; synthesising the mic and the speaking phase")
            }
        }
        let synthesise = synthesising
        stateLock.unlock()
        guard synthesise else { return (mic, voice) }

        switch mood {
        case .listening:
            return (Float(envelope(time, syllables: 2.2) * 0.9), 0)
        case .speaking:
            // ~3.6 syllables a second with gaps between them: a voice, not a hum.
            return (0.02, Float(envelope(time, syllables: 3.6)))
        case .working:
            return (0.04, 0)
        case .muted, .offline:
            return (0, 0)
        }
    }

    /// A speech-like amplitude: a raised sine at the syllable rate, slowly drifting in strength.
    private static func envelope(_ time: Double, syllables: Double) -> Double {
        let carrier = max(sin(time * Double.pi * syllables), 0)
        let drift = 0.75 + 0.25 * sin(time * 1.7)
        return pow(carrier, 1.5) * drift
    }
}

extension Mood {
    /// The name the demo's screenshot dumps use, matching the labels in `docs/orb-states.png`.
    var orbStateName: String {
        switch self {
        case .muted: "muted"
        case .listening: "listening"
        case .speaking: "speaking"
        case .working: "working"
        case .offline: "offline"
        }
    }
}
