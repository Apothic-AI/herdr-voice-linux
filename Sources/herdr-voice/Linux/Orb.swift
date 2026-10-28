import CCairo
import CX11
import Foundation
import HerdrVoiceCore

/// The floating orb on Linux.
///
/// The macOS orb is an AppKit `NSPanel` of `CAGradientLayer`s. The Linux port keeps the same picture and the same
/// contract, drawn by Cairo into an override-redirect X11 window so it floats above managed windows and never takes
/// focus: no window manager frame, no taskbar entry, no key events stolen from the terminal.
///
/// Contract (identical on both platforms):
/// - `init(onClick:menuChoices:onQuit:)` puts the orb on screen;
/// - `run(_:)` starts the frame callback and returns, the frame closure is asked for a `Frame` on every tick;
/// - `follow(_:)` pins it to a window rectangle (nil hides it), `showInScreenCorner()` puts it in the corner;
/// - left click mutes, right click opens the model menu.
///
/// Threading: everything X11 and everything that draws happens on one dedicated frame thread, so a repaint never
/// sits between the voice session and its socket, and the main thread only ever hands over a small snapshot of state
/// under a lock. The frame callback itself is invoked on the main thread, as the macOS display link does, because
/// what it reads is the session's state.
final class Orb {
    typealias Mood = HerdrVoiceCore.Mood

    /// One frame's inputs: the mood, raw 0...1 loudness of mic and playback, and whether anything is working.
    struct Frame {
        let mood: Mood
        let mic: Float
        let voice: Float
        let thinking: Bool
    }

    /// One entry in the right-click menu above Quit (the AI models).
    struct MenuChoice {
        let title: String
        let checked: Bool
        let enabled: Bool
        /// Draw a separator line after this entry.
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

    static let size: Double = OrbPaint.size
    private static let sphereInset: Double = size * 0.18

    /// Where the orb wants to be. `follow(nil)` parks it in `.hidden`; nothing else can.
    private enum Placement {
        case corner
        case host(Rect)
        case hidden
    }

    /// The snapshot the frame thread reads once per frame.
    private struct Inputs {
        var mood: Mood = .listening
        var mic: Float = 0
        var voice: Float = 0
        var thinking = false
    }

    private let onClick: () -> Void
    private let menuChoices: () -> [MenuChoice]
    private let onQuit: () -> Void

    // Shared with the frame thread.
    private let lock = NSLock()
    private var inputs = Inputs()
    private var placement: Placement = .corner
    private var frameBody: (() -> Frame)?
    private var frameRequestOutstanding = false
    private let ready = DispatchSemaphore(value: 0)

    // Owned by the frame thread.
    private var thread: Thread?
    private var x11: OrbX11?
    private var window: OrbX11Window?
    private var menu: OrbMenu?
    private var animation = OrbAnimation()
    private var origin: (x: Int32, y: Int32)?
    private var mapped = false
    private var raiseWanted = false
    private var idle = false
    private var lastMood: Mood = .listening
    private var lastThinking = false
    private var dumpKeys: Set<String> = []
    private var dumpPendingKey: String?
    private var dumpDue = 0.0
    private var dumpCurrentKey: String?
    private let dumpDirectory = ProcessInfo.processInfo.environment["HERDR_ORB_DUMP"]
    /// `HERDR_ORB_DEBUG=1` reports the achieved frame rate and how long a frame costs, which is how the idle and
    /// active budgets in the porting notes were measured.
    private let debugFrames = ProcessInfo.processInfo.environment["HERDR_ORB_DEBUG"] != nil
    private var frameCount = 0
    private var frameCost = 0.0
    private var lastWait: (fd: Int32, result: Int32, revents: Int16) = (0, 0, 0)

    /// `onClick` for a plain click (mute); `menuChoices` is asked for fresh entries each time the right-click menu
    /// opens (so the checkmark and key availability are current); `onQuit` for its Quit item.
    init(onClick: @escaping () -> Void, menuChoices: @escaping () -> [MenuChoice] = { [] },
         onQuit: @escaping () -> Void = { AppHost.terminate() }) {
        self.onClick = onClick
        self.menuChoices = menuChoices
        self.onQuit = onQuit
        // Xlib's per-connection locking, before this process makes its first X call: the frame thread owns the
        // connection, and any library that opens the display later must not race it.
        XInitThreads()
        let thread = Thread { [weak self] in self?.startFrameThread() }
        thread.name = "herdr-voice-orb"
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
        // The window is created and mapped before init returns, the way the macOS panel is ordered front in init.
        _ = ready.wait(timeout: .now() + 5)
    }

    /// Starts the frame callback: the closure is asked for a `Frame` on every tick, and `update` is applied for each
    /// one. Returns immediately; the orb animates on its own thread.
    func run(_ frame: @escaping () -> Frame) {
        lock.lock()
        frameBody = frame
        lock.unlock()
        // With a stubbed audio backend the demo's own start fails and exits; keep this branch's demo on screen.
        OrbDemo.armExitBridge()
    }

    /// Sits just inside the bottom-left of `window` (X11 coordinates, top-left origin), or hides when nil.
    func follow(_ window: Rect?) {
        lock.lock()
        if let window {
            placement = .host(window)
        } else {
            placement = .hidden
        }
        lock.unlock()
    }

    /// Fallback when there is no Herdr window to follow: the screen's bottom-left corner, always visible.
    func showInScreenCorner() {
        lock.lock()
        placement = .corner
        lock.unlock()
    }

    /// Called every frame with the current mood, raw 0...1 loudness of the mic and of the assistant's playback, and
    /// whether anything is working (voice model processing, a tool call, or a coding agent). The frame thread picks
    /// the values up on its next tick.
    func update(_ mood: Mood, mic: Float, voice: Float, thinking: Bool) {
        lock.lock()
        inputs = Inputs(mood: mood, mic: mic, voice: voice, thinking: thinking)
        lock.unlock()
    }

    // MARK: - frame thread

    private func startFrameThread() {
        guard let x = OrbX11() else {
            log("✖ orb: no X display is reachable; the orb is not available")
            ready.signal()
            return
        }
        x11 = x
        let alpha = x.hasAlpha && x.hasCompositor
        guard let window = OrbX11Window(x: x, name: "herdr-voice orb", width: Int32(Orb.size),
                                        height: Int32(Orb.size),
                                        events: X11.exposureMask | X11.buttonPressMask | X11.buttonReleaseMask
                                            | X11.pointerMotionMask | X11.structureNotifyMask,
                                        alpha: alpha)
        else {
            log("✖ orb: could not create its window")
            ready.signal()
            return
        }
        self.window = window
        menu = OrbMenu(x: x)
        if alpha {
            // The window id is printed so a test can check this exact window with `xwininfo -id` instead of guessing at
            // it by class name, which matches unrelated windows that happen to share a title.
            log("◎ orb: 96x96 override-redirect window 0x\(String(window.id, radix: 16)) on a 32-bit ARGB visual, composited")
        } else {
            log("⚠ orb: no compositor or no ARGB visual here, so the orb is drawn opaque with its own shadow")
        }
        // Watch what the window manager raises above managed windows; the orb puts itself back on top of them.
        XSelectInput(x.display, x.root, X11.substructureNotifyMask)
        applyPlacement(force: true)
        OrbDemo.orbOnScreen = true
        ready.signal()

        var last = Orb.now()
        var lastWatchdog = last
        var lastDebugLog = last
        while true {
            let frameStart = Orb.now()
            pumpEvents()
            requestFrame()
            let now = frameStart
            let dt = min(now - last, 0.1)
            last = now
            let snapshot = currentInputs()
            lastMood = snapshot.mood
            lastThinking = snapshot.thinking
            var mic = snapshot.mic
            var voice = snapshot.voice
            if OrbDemo.isDemo {
                (mic, voice) = OrbDemo.levels(mood: snapshot.mood, mic: mic, voice: voice, dt: dt,
                                              time: animation.elapsed)
            }
            animation.step(dt: dt, mood: snapshot.mood, mic: mic, voice: voice, thinking: snapshot.thinking)
            applyPlacement()
            if wantsVisible {
                let drawStart = Orb.now()
                draw(now: now)
                frameCost = Orb.now() - drawStart
                if raiseWanted, menu?.isOpen != true {
                    raiseWanted = false
                    window.raise()
                }
            }
            if now - lastWatchdog >= 1 {
                lastWatchdog = now
                reassert()
            }
            if animation.idle != idle {
                idle = animation.idle
                log(idle ? "◎ orb: idle, 30 fps" : "◎ orb: active, 60 fps")
            }
            if debugFrames {
                frameCount += 1
                if now - lastDebugLog >= 1 {
                    let summary = eventCounts.sorted { $0.value > $1.value }.prefix(3)
                        .map { "t\($0.key)=\($0.value)" }.joined(separator: " ")
                    log("◎ orb debug: \(frameCount) fps, \(Int(frameCost * 1_000_000)) µs/frame, poll=\(lastWait.result) [\(summary)]")
                    eventCounts.removeAll()
                    frameCount = 0
                    lastDebugLog = now
                }
            }
            // Paced on a deadline rather than by the last wake: a click (or anything else the server sends) is handled
            // as it arrives without ever drawing the next frame early, so the rate stays at 60 fps active / 30 idle.
            let interval = wantsVisible ? (animation.idle ? 1.0 / 30 : 1.0 / 60) : 0.1
            let deadline = frameStart + interval
            while true {
                let remaining = deadline - Orb.now()
                if remaining <= 0 { break }
                let waited = x.waitForEvents(timeout: remaining)
                if debugFrames { lastWait = waited }
                pumpEvents()
                if let menu, menu.isOpen, menu.needsPaint { menu.paint() }
            }
        }
    }

    private func currentInputs() -> Inputs {
        lock.lock()
        defer { lock.unlock() }
        return inputs
    }

    private var currentPlacement: Placement {
        lock.lock()
        defer { lock.unlock() }
        return placement
    }

    private var wantsVisible: Bool {
        if case .hidden = currentPlacement { return false }
        return true
    }

    /// Asks the main thread for one frame, coalescing: at most one request is in flight, so a busy main thread can
    /// never build a queue of stale frames.
    private func requestFrame() {
        lock.lock()
        let body = frameBody
        let alreadyAsking = frameRequestOutstanding
        if body != nil && !alreadyAsking { frameRequestOutstanding = true }
        lock.unlock()
        guard let body, !alreadyAsking else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let frame = body()
            self.lock.lock()
            self.inputs = Inputs(mood: frame.mood, mic: frame.mic, voice: frame.voice, thinking: frame.thinking)
            self.frameRequestOutstanding = false
            self.lock.unlock()
        }
    }

    // MARK: - placing it

    /// Bottom-left of the host window plus the 4 px inset, or 20 px inside the screen's bottom-left corner.
    /// `nil` means the orb should be hidden.
    private func targetOrigin(_ x: OrbX11) -> (x: Int32, y: Int32)? {
        let area = x.workArea(refreshedAt: Orb.now())
        let size = Orb.size
        switch currentPlacement {
        case .hidden:
            return nil
        case .corner:
            return (Int32((area.minX + 20).rounded()), Int32((area.maxY - size - 20).rounded()))
        case .host(let rect):
            // X11 rectangles grow downwards, so the bottom-left of the window is (minX, maxY).
            let px = rect.minX + 4
            let py = rect.maxY - size - 4
            // Keep it on screen even when the host window is partly off it.
            let clampedX = min(max(px, area.minX + 4), area.maxX - size - 4)
            let clampedY = min(max(py, area.minY + 4), area.maxY - size - 4)
            return (Int32(clampedX.rounded()), Int32(clampedY.rounded()))
        }
    }

    private func applyPlacement(force: Bool = false) {
        guard let x = x11, let window else { return }
        guard let target = targetOrigin(x) else {
            if mapped {
                window.unmap()
                mapped = false
            }
            return
        }
        if force || origin == nil || origin! != target {
            window.move(toX: target.x, y: target.y)
            origin = target
        }
        if !mapped {
            window.map()
            mapped = true
        }
    }

    /// Once a second: if the orb should be showing but isn't mapped, or has been pushed below a window that was
    /// raised over it, put it back. Cheap: two property reads when nothing is wrong.
    private func reassert() {
        guard let x = x11, let window, wantsVisible else { return }
        let mapped = window.isViewable
        var isTopmost = true
        if mapped {
            var ours: Set<XID> = []
            if let menuID = menu?.windowID, menu?.isOpen == true { ours.insert(menuID) }
            isTopmost = window.isTopmost(in: x, above: ours)
        }
        guard !mapped || !isTopmost else { return }
        if !mapped {
            // Nothing else reported it going away (the UnmapNotify path covers the ordinary case), so say so here.
            log("◎ the orb had been hidden; showing it again")
            origin = nil
            applyPlacement(force: true)
        } else {
            // Another window was stacked over the orb: put it back without logging, because a desktop raising
            // windows is ordinary and the message is about the orb disappearing, not about stacking order.
            window.raise()
        }
    }

    // MARK: - drawing

    private func draw(now: Double) {
        guard let window else { return }
        let look = animation.look
        let opaque = !window.hasAlpha
        let image = window.render { context, width, _ in
            OrbPaint.draw(context, size: width, look: look, opaqueBackdrop: opaque)
        }
        guard let image else { return }
        maybeDump(image: image, now: now)
    }

    /// `HERDR_ORB_DUMP=<dir>` writes one PNG per distinct state, a moment after the state settles, straight from the
    /// Cairo surface the window just showed — the same pixels, with their alpha, without asking the screen for them.
    private func maybeDump(image: OpaquePointer, now: Double) {
        guard let directory = dumpDirectory else { return }
        let key = lastMood.orbStateName + (lastThinking ? "-thinking" : "")
        if key != dumpCurrentKey {
            dumpCurrentKey = key
            dumpPendingKey = key
            dumpDue = now + 1.6
        }
        guard let pending = dumpPendingKey, now >= dumpDue, !dumpKeys.contains(pending) else { return }
        dumpKeys.insert(pending)
        dumpPendingKey = nil
        _ = try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = (directory as NSString).appendingPathComponent("orb-\(pending).png")
        cairo_surface_flush(image)
        _ = cairo_surface_write_to_png(image, path)
        log("◎ orb: wrote \(path)")
    }

    // MARK: - input

    private func pumpEvents() {
        guard let x = x11 else { return }
        while XPending(x.display) > 0 {
            var event = XEvent()
            XNextEvent(x.display, &event)
            let any = orbEvent(event, as: XAnyEvent.self)
            if debugFrames {
                eventCounts[any.type, default: 0] += 1
            }
            handle(event)
        }
    }

    private var eventCounts: [Int32: Int] = [:]

    private func handle(_ event: XEvent) {
        guard let x = x11, let window else { return }
        if let menu, menu.isOpen {
            if menu.handle(event) {
                if menu.needsPaint { menu.paint() }
                return
            }
        }
        let any = orbEvent(event, as: XAnyEvent.self)
        switch any.type {
        case X11.buttonPress:
            guard any.window == window.id else { return }
            let press = orbEvent(event, as: XButtonEvent.self)
            let control = press.state & X11.controlMask != 0
            if press.button == X11.button3 || (press.button == X11.button1 && control) {
                openMenu(at: (press.x_root, press.y_root))
            } else if press.button == X11.button1 {
                log("◉ orb clicked: toggling mute")
                performOnMain { [onClick] in onClick() }
            }
        case X11.expose:
            // A frame is painted every tick anyway; nothing to do beyond letting the loop continue.
            break
        case X11.mapNotify:
            if any.window == window.id { mapped = true } else { raiseWanted = true }
        case X11.unmapNotify:
            // Only an unmap the orb didn't ask for is news: `follow(nil)` and the hidden placement take it down on
            // purpose, while anything else means something hid the orb and it has to come back.
            if any.window == window.id, mapped {
                mapped = false
                log("◎ the orb had been hidden; showing it again")
            }
        case X11.configureNotify:
            let configure = orbEvent(event, as: XConfigureEvent.self)
            // `above == None` means that window was stacked on top of everything: the orb belongs over it.
            if configure.window != window.id, configure.window != menu?.windowID, configure.above == 0 {
                raiseWanted = true
            }
        default:
            break
        }
    }

    /// Right-click (or ctrl-click): ask for the current entries, show the menu at the pointer, and arrange for the
    /// chosen action to run on the main thread, where the session state it touches lives.
    private func openMenu(at point: (x: Int32, y: Int32)) {
        guard let menu else { return }
        let fresh = freshChoices()
        log("◉ orb menu: opening with \(fresh.count) entries")
        let entries = fresh.map { choice in
            MenuChoice(title: choice.title, checked: choice.checked, enabled: choice.enabled,
                       separatorAfter: choice.separatorAfter,
                       action: { [weak self] in self?.run(choice) })
        }
        guard let window else { return }
        menu.open(at: point, choices: entries, onQuit: { [weak self] in
            guard let self else { return }
            log("◉ orb menu: Quit herdr-voice")
            performOnMain { self.onQuit() }
        })
        menu.paint()
        _ = window
    }

    private func run(_ choice: MenuChoice) {
        log("◉ orb menu: \(choice.title)")
        performOnMain(choice.action)
    }

    /// The entries come from the app, which owns the session state they describe, so they are collected on the main
    /// thread; a menu opening is a user action, so a brief wait is fine, and a stuck main thread degrades to an
    /// empty-but-usable menu rather than a frozen orb.
    private func freshChoices() -> [MenuChoice] {
        if Thread.isMainThread { return menuChoices() }
        let semaphore = DispatchSemaphore(value: 0)
        var result: [MenuChoice] = []
        DispatchQueue.main.async { [menuChoices] in
            result = menuChoices()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 1) == .timedOut {
            log("⚠ orb: asking for the menu entries timed out")
        }
        return result
    }

    private func performOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread {
            body()
        } else {
            DispatchQueue.main.async(execute: body)
        }
    }

    /// Seconds on a monotonic clock: a wall-clock jump must not make the animation leap or stall.
    static func now() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }
}
