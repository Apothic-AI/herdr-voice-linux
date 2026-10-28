import Foundation
import HerdrVoiceCore

/// Mic capture and playback on Linux.
///
/// This is the seam the macOS implementation fills with AVAudioEngine plus Apple voice processing. On Linux the
/// same contract is satisfied over the platform's audio server, and the echo canceller is the platform's own
/// (PipeWire/PulseAudio `module-echo-cancel`) rather than a per-app voice-processing unit.
///
/// Contract (identical on both platforms):
/// - `start()` brings capture and playback up or throws;
/// - `onMic` is called off the main thread with base64 PCM16 24 kHz mono, every ~20 ms, with the chunk's rms;
/// - `play(base64:item:)` queues assistant audio and reports start/stop through `onSpeakingChanged` on main;
/// - `interrupt()` stops playback and returns how much of the current item was heard;
/// - `micLevel`/`outLevel` are the levels the orb draws.
///
/// TODO(linux-port): implement over PortAudio/PipeWire. See the porting contract in docs/linux-port.md.
final class Audio {
    static let rate = 24000.0
    static let chunkSeconds = 0.02

    let echoCancel: Bool
    var onMic: ((String, Float) -> Void)?
    var onSpeakingChanged: ((Bool) -> Void)?
    private(set) var micLevel: Float = 0
    private(set) var outLevel: Float = 0

    private var playback = PlaybackLedger()

    init(echoCancel: Bool = ProcessInfo.processInfo.environment["HERDR_VOICE_ECHO_CANCEL"] != "0") {
        self.echoCancel = echoCancel
    }

    struct Unavailable: Error, CustomStringConvertible {
        let what: String
        var description: String { what }
    }

    func start() throws {
        throw Unavailable(what: "Linux audio capture is not implemented yet")
    }

    func setMuted(_ muted: Bool) {}

    func play(base64: String, item: String) {}

    var isSpeaking: Bool { playback.isSpeaking }

    func interrupt() -> (item: String, heardMs: Int)? {
        let heard = playback.interrupt(sampleRate: Int(Audio.rate))
        if heard != nil { onSpeakingChanged?(false) }
        outLevel = 0
        return heard
    }
}
