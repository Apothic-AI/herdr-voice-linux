import Foundation
import HerdrVoiceCore

/// Global hotkeys on Linux, through X11 (XGrabKey on the root window — no window-manager binding, so it works in
/// every app the way Carbon hotkeys do on macOS).
///
/// Contract (identical on both platforms):
/// - `registerMute` binds the mute toggle (⌥⌘M on macOS, herdr-voice maps it to Ctrl+Alt+M on Linux);
/// - `setStopKey(active:)` grabs plain Esc only while the assistant is speaking, and releases it otherwise, so
///   every other app keeps its Esc the rest of the time.
///
/// TODO(linux-port): implement over X11. See docs/linux-port.md.
enum Hotkey {
    static let label = "Ctrl+Alt+M"

    static func registerMute(_ onPress: @escaping () -> Void) {
        log("⚠ global hotkeys are not implemented on Linux yet; click the orb to mute")
    }

    static func setStopKey(active: Bool, _ onPress: @escaping () -> Void) {}
}
