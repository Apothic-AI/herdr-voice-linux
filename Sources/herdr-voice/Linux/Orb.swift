import Foundation
import HerdrVoiceCore

/// The floating orb on Linux.
///
/// The macOS orb is an AppKit `NSPanel` of `CAGradientLayer`s. The Linux port keeps the same picture and the same
/// contract, drawn by Cairo into an override-redirect X11 window so it floats above managed windows and never
/// takes focus.
///
/// Contract (identical on both platforms):
/// - `init(onClick:menuChoices:onQuit:)` puts the orb on screen;
/// - `run(_:)` starts the frame callback and returns, the frame closure is asked for a `Frame` on every tick;
/// - `follow(_:)` pins it to a window rectangle (nil hides it), `showInScreenCorner()` puts it in the corner;
/// - left click mutes, right click opens the model menu.
///
/// TODO(linux-port): implement. See docs/linux-port.md.
final class Orb {
    typealias Mood = HerdrVoiceCore.Mood

    struct Frame {
        let mood: Mood
        let mic: Float
        let voice: Float
        let thinking: Bool
    }

    struct MenuChoice {
        let title: String
        let checked: Bool
        let enabled: Bool
        var separatorAfter = false
        let action: () -> Void

        init(title: String, checked: Bool, enabled: Bool, separatorAfter: Bool = false,
             action: @escaping () -> Void) {
            self.title = title
            self.checked = checked
            self.enabled = enabled
            self.separatorAfter = separatorAfter
            self.action = action
        }
    }

    private let onClick: () -> Void
    private let menuChoices: () -> [MenuChoice]
    private let onQuit: () -> Void

    init(onClick: @escaping () -> Void, menuChoices: @escaping () -> [MenuChoice] = { [] },
         onQuit: @escaping () -> Void = { AppHost.terminate() }) {
        self.onClick = onClick
        self.menuChoices = menuChoices
        self.onQuit = onQuit
    }

    func follow(_ window: Rect?) {}
    func showInScreenCorner() {}
    func run(_ frame: @escaping () -> Frame) {}
    func update(_ mood: Mood, mic: Float, voice: Float, thinking: Bool) {}
}
