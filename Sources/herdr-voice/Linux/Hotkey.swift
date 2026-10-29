import Foundation
import HerdrVoiceCore

/// Global hotkeys on Linux, through X11 (XGrabKey on the root window — no window-manager binding, so it works in
/// every app the way Carbon hotkeys do on macOS).
///
/// Contract (identical on both platforms):
/// - `registerMute` binds the mute toggle (⌥⌘M on macOS, herdr-voice maps it to Ctrl+Alt+M on Linux, or whatever
///   `HERDR_VOICE_HOTKEY_MODS` + `HERDR_VOICE_HOTKEY_KEY` name);
/// - `setStopKey(active:)` grabs plain Esc only while the assistant is speaking, and releases it otherwise, so
///   every other app keeps its Esc the rest of the time.
///
/// The grabs live on their own X connection with their own thread (`X11Loop`), because a passive grab decides what
/// the whole display does with that key press: if this process exits or its connection dies, X releases the grabs
/// and the keys go back to every app. Presses are handed to the main queue, so the handlers run where the macOS
/// ones run — in `toggleMute`/`stopSpeech`, not on an X thread.
enum Hotkey {
    /// What to call the mute binding in messages. Read from the environment, so it names the key that is bound
    /// rather than the one this file happens to prefer.
    static let label = binding().label

    private static let server = X11Hotkeys()

    static func registerMute(_ onPress: @escaping () -> Void) {
        server.registerMute(onPress)
    }

    /// Grabs plain Esc while `active`, releases it otherwise. Cheap to call every frame.
    static func setStopKey(active: Bool, _ onPress: @escaping () -> Void) {
        server.setStopKey(active: active, onPress)
    }

    /// The binding the environment asks for. `ctrl+alt` and `m` are the Linux default: ⌥⌘M is taken by the
    /// window manager on most desktops, and Ctrl+Alt+M is free on GNOME, KDE and XFCE alike.
    static func binding() -> (label: String, modifiers: UInt32, keyName: String) {
        let env = ProcessInfo.processInfo.environment
        let mods = env["HERDR_VOICE_HOTKEY_MODS"] ?? "ctrl+alt"
        let key = env["HERDR_VOICE_HOTKEY_KEY"] ?? "m"
        let parsed = modifiers(from: mods)
        let names = mods.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).capitalized }
        return ((names + [key.uppercased()]).joined(separator: "+"), parsed, key)
    }

    /// X11's `ShiftMask | ControlMask | Mod1Mask | …`, from names people would type.
    static func modifiers(from text: String) -> UInt32 {
        var mask: UInt32 = 0
        for part in text.lowercased().split(separator: "+") {
            switch part.trimmingCharacters(in: .whitespaces) {
            case "ctrl", "control": mask |= X11Constant.controlMask
            case "alt", "option", "mod1": mask |= X11Constant.mod1Mask
            case "shift": mask |= X11Constant.shiftMask
            case "super", "cmd", "command", "meta", "win", "mod4": mask |= X11Constant.mod4Mask
            case "mod2": mask |= X11Constant.mod2Mask
            case "mod3": mask |= X11Constant.mod3Mask
            case "mod5": mask |= X11Constant.mod5Mask
            default: break
            }
        }
        return mask
    }
}

/// The X side of the hotkeys: one connection, one thread, one event loop.
private final class X11Hotkeys {
    private let loop = X11Loop(name: "hotkeys")
    private let debug = ProcessInfo.processInfo.environment["HERDR_VOICE_DEBUG_KEYS"] == "1"
    private var started = false
    private var warnedStop = false
    private var warnedMute = false

    // Loop-thread state.
    private var api: X11API?
    private var root: XWindowID = 0
    private var muteKeycode: Int32?
    private var escKeycode: Int32?
    private var muteGrabbed = false
    private var escGrabbed = false
    private var muteHandler: (() -> Void)?
    private var stopHandler: (() -> Void)?

    func registerMute(_ onPress: @escaping () -> Void) {
        muteHandler = onPress
        start()
        grabMute()
    }

    func setStopKey(active: Bool, _ onPress: @escaping () -> Void) {
        stopHandler = onPress
        start()
        loop.perform { [weak self] display in
            guard let self else { return }
            if active { self.grabEsc(display) } else { self.releaseEsc(display) }
        }
    }

    private func start() {
        guard !started else { return }
        started = true
        loop.onOpen = { [weak self] display in self?.open(display) ?? false }
        loop.onEvents = { [weak self] display in self?.drain(display) }
        loop.onFailure = { reason in
            log("⚠ could not register \(Hotkey.label); click the orb to mute (\(reason))")
        }
        // Nothing here is polled: grabs are event driven, and this tick only exists to notice a dead connection.
        loop.tickInterval = 60
        loop.start()
    }

    /// On the loop thread: one connection that receives the grabbed keys, from the root window.
    private func open(_ display: OpaquePointer) -> Bool {
        guard let api = X11API.shared else { return false }
        self.api = api
        root = api.defaultRootWindow(display)
        guard root != 0 else { return false }
        // Passive grabs report the press to the grabbing client, but the root still has to be asked for the
        // keyboard events that arrive while nothing else has the focus.
        _ = api.selectInput(display, root, X11Constant.keyPressMask)
        return true
    }

    /// Grabs Ctrl+Alt+M (or the configured binding) in every modifier combination that includes a lock, so it
    /// keeps working with CapsLock or NumLock on, and reports a conflict instead of pretending it worked.
    private func grabMute() {
        guard let binding = Optional(Hotkey.binding()) else { return }
        loop.perform { [weak self] display in
            guard let self, let api = self.api else { return }
            guard !self.muteGrabbed else { return }
            let keysym = binding.keyName.withCString { api.stringToKeysym($0) }
            guard keysym != 0 else {
                self.warnMute("\(binding.keyName) is not a keysym name")
                return
            }
            let keycode = Int32(api.keysymToKeycode(display, keysym))
            guard keycode != 0 else {
                self.warnMute("this keyboard has no \(binding.keyName) key")
                return
            }
            self.muteKeycode = keycode
            var conflicted = false
            for lock in X11Constant.lockCombinations {
                X11Errors.clear(display)
                _ = api.grabKey(display, keycode, binding.modifiers | lock, self.root, 0,
                                X11Constant.grabModeAsync, X11Constant.grabModeAsync)
                _ = api.sync(display, 0)
                if X11Errors.codes(display).contains(X11Errors.badAccess) { conflicted = true }
            }
            if conflicted {
                // Someone else owns the binding (a window manager shortcut, usually). Release the combinations
                // that did go through and say so, rather than swallowing the key from the other app.
                for lock in X11Constant.lockCombinations {
                    _ = api.ungrabKey(display, keycode, binding.modifiers | lock, self.root)
                }
                _ = api.sync(display, 0)
                self.muteKeycode = nil
                self.warnMute(nil)
                return
            }
            self.muteGrabbed = true
            self.debugLog("\(binding.label) grabbed")
        }
    }

    private func releaseMute() {
        loop.perform { [weak self] display in
            guard let self, let api = self.api, let keycode = self.muteKeycode, self.muteGrabbed else { return }
            for lock in X11Constant.lockCombinations {
                _ = api.ungrabKey(display, keycode, Hotkey.binding().modifiers | lock, self.root)
            }
            _ = api.sync(display, 0)
            self.muteGrabbed = false
            self.debugLog("\(Hotkey.label) released")
        }
    }

    /// Esc is grabbed on every modifier combination (`AnyModifier`): the assistant is speaking, so a bare Esc with
    /// a stray NumLock bit still has to stop it. Every other app keeps Esc the rest of the time, because the grab
    /// is released as soon as the speech ends.
    private func grabEsc(_ display: OpaquePointer) {
        guard let api = self.api, !escGrabbed else { return }
        X11Errors.clear(display)
        let keycode = Int32(api.keysymToKeycode(display, X11Constant.xkEscape))
        guard keycode != 0 else { return }
        _ = api.grabKey(display, keycode, X11Constant.anyModifier, root, 0,
                        X11Constant.grabModeAsync, X11Constant.grabModeAsync)
        _ = api.sync(display, 0)
        if X11Errors.codes(display).contains(X11Errors.badAccess) {
            if !warnedStop {
                warnedStop = true
                log("⚠ could not grab Esc; say \"stop\" or talk over the voice instead")
            }
            return
        }
        escKeycode = keycode
        escGrabbed = true
        debugLog("Esc grabbed")
    }

    private func releaseEsc(_ display: OpaquePointer) {
        guard let api = self.api, escGrabbed, let keycode = escKeycode else { return }
        _ = api.ungrabKey(display, keycode, X11Constant.anyModifier, root)
        _ = api.sync(display, 0)
        escGrabbed = false
        debugLog("Esc released")
    }

    /// Drains key presses. A grabbed press lands here whichever app has the focus, which is the whole point.
    private func drain(_ display: OpaquePointer) {
        guard let api else { return }
        var event = [UInt64](repeating: 0, count: 32)
        while api.pending(display) > 0 {
            let status = event.withUnsafeMutableBytes { api.nextEvent(display, $0.baseAddress) }
            guard status == 0 else { break }
            let (type, keycode, state) = event.withUnsafeBytes {
                ($0.loadUnaligned(fromByteOffset: 0, as: Int32.self),
                 $0.loadUnaligned(fromByteOffset: 84, as: UInt32.self),
                 $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self))
            }
            guard type == X11Constant.keyPress else { continue }
            // A lock bit is not part of the binding: the grab covers those combinations, the match ignores them.
            let bare = state & ~(X11Constant.lockMask | X11Constant.mod2Mask | X11Constant.mod3Mask)
            if escGrabbed, Int32(keycode) == escKeycode {
                fire(stopHandler, "Esc")
            } else if muteGrabbed, Int32(keycode) == muteKeycode, bare == Hotkey.binding().modifiers {
                fire(muteHandler, Hotkey.label)
            }
        }
    }

    private func fire(_ handler: (() -> Void)?, _ what: String) {
        guard let handler else { return }
        debugLog("\(what) pressed")
        DispatchQueue.main.async(execute: handler)
    }

    private func warnMute(_ detail: String?) {
        guard !warnedMute else { return }
        warnedMute = true
        if let detail {
            log("⚠ could not register \(Hotkey.label); click the orb to mute (\(detail))")
        } else {
            log("⚠ could not register \(Hotkey.label); click the orb to mute")
        }
    }

    private func debugLog(_ line: String) {
        guard debug else { return }
        log("⌨  " + line)
    }
}
