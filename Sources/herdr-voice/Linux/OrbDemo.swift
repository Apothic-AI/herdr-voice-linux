import Foundation
import HerdrVoiceCore

/// The `--orb-demo` affordances that have to live on this side of the seam.
///
/// `main.swift` drives the demo from the real audio path: it cycles the five moods every four seconds, hands the orb
/// the live mic level, and plays a synthesised "speech" burst for the speaking phase. The Linux audio backend can be
/// absent, and the orb is what the demo exists to show, so `main.swift` logs that and keeps going; this file supplies
/// the envelopes a working audio path would have produced.
///
/// With no capture and no playback every level is 0, so all five moods would draw as a still sphere. Once the audio
/// path has been silent for a couple of seconds the demo supplies its own levels — the syllabic shape a voice would
/// have produced — so the demo still shows the design it exists to show. A real level, the moment one appears,
/// immediately takes over again.
enum OrbDemo {
    static var isDemo: Bool { CommandLine.arguments.contains("--orb-demo") }

    private static let stateLock = NSLock()
    private static var silentFor = 0.0
    private static var synthesising = false
    private static var announced = false

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
