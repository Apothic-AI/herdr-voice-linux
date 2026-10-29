import Foundation
import HerdrVoiceCore

/// Finds the terminal window showing Herdr on Linux, and reports where the orb should sit.
///
/// On macOS this walks the process tree to the terminal app and reads `CGWindowList`. On Linux the same question is
/// answered over X11: which managed windows exist (`_NET_CLIENT_LIST`), whose `_NET_WM_PID` is a terminal in our own
/// ancestry (or whose `_NET_WM_NAME`/`WM_NAME` mentions herdr, as a fallback for a terminal that doesn't set the
/// pid), and where that window is (`_NET_FRAME_EXTENTS` + translate coordinates, which is the rectangle the window
/// manager actually gave it).
///
/// Contract (identical on both platforms): `start(onChange:)` calls back on the main thread only when the answer
/// changes, with the window rectangle in the platform's own screen coordinates (AppKit: bottom-left origin;
/// X11: top-left) and `nil` when there is no window to follow.
///
/// The Xlib connection has a thread and a loop of its own (`X11Loop`), so a window query never runs on the main
/// thread, and the connection is *event driven*: `StructureNotify`/`PropertyChange` on the windows it follows wake
/// it the instant the window manager moves, restores or hides one, instead of waiting for the next poll. The poll
/// stays as a watchdog, at the same two rates as macOS — 10 Hz while the terminal owns the focus or has just moved,
/// 1 Hz otherwise — because a window manager is not obliged to report a shape it was told about.
final class WindowTracker {
    typealias Result = (hasHost: Bool, frame: Rect?)

    private let loop = X11Loop(name: "window-tracker")
    private let debug = ProcessInfo.processInfo.environment["HERDR_VOICE_DEBUG_WINDOW"] == "1"
    private var started = false
    private var onChange: ((Bool, Rect?) -> Void)?

    // Everything below is touched only on the loop thread.
    private var api: X11API?
    private var names: X11Names?
    private var hosts = Set<Int32>()
    private var candidates: [XWindowID] = []
    private var watched = Set<XWindowID>()
    private var pidCache: [XWindowID: Int32] = [:]
    private var titleCache: [XWindowID: String] = [:]
    private var lastDiscovery = Date.distantPast
    private var lastPublished: (Bool, Rect?)?
    private var lastFrame: Rect?
    private var lastFrameAnnouncement = ""
    private var lastCadenceAnnouncement = ""

    /// `onChange` runs on main, only when the result changes. The frame is in X11 screen coordinates.
    func start(onChange: @escaping (_ hasHost: Bool, _ frame: Rect?) -> Void) {
        guard !started else { return }
        started = true
        self.onChange = onChange

        loop.onOpen = { [weak self] display in self?.open(display) ?? false }
        loop.onEvents = { [weak self] display in self?.drain(display) }
        loop.onTick = { [weak self] display in self?.refresh(display) }
        loop.onFailure = { [weak self] reason in
            guard let self else { return }
            log("⚠ window tracking is off: \(reason); the orb stays in the screen corner")
            self.publish(hasHost: false, frame: nil)
            self.announce("no X display (\(reason))")
        }
        // The watchdog starts slow: whether the terminal is in front is only known once X answers.
        loop.tickInterval = 1
        loop.start()
    }

    /// On the loop thread, once the display is open: intern the atoms and start listening for the window manager
    /// telling us that the managed windows changed.
    private func open(_ display: OpaquePointer) -> Bool {
        guard let api = X11API.shared, let names = X11Names(api, display: display) else {
            log("⚠ window tracking is off: the X display has no window-manager properties")
            publish(hasHost: false, frame: nil)
            return false
        }
        self.api = api
        self.names = names
        _ = api.selectInput(display, names.root,
                            X11Constant.propertyChangeMask | X11Constant.structureNotifyMask)
        discover(display)
        refresh(display)
        return true
    }

    private func publish(hasHost: Bool, frame: Rect?) {
        if let last = lastPublished, last.0 == hasHost, last.1 == frame { return }
        lastPublished = (hasHost, frame)
        guard let onChange else { return }
        DispatchQueue.main.async { onChange(hasHost, frame) }
    }

    /// Debug logging for `HERDR_VOICE_DEBUG_WINDOW=1`, rate limited to actual changes.
    private func announce(_ line: String, cadence: Bool = false) {
        guard debug else { return }
        // Two independent streams: a cadence change between two identical frames must not re-log the frame.
        if cadence {
            guard lastCadenceAnnouncement != line else { return }
            lastCadenceAnnouncement = line
        } else {
            guard lastFrameAnnouncement != line else { return }
            lastFrameAnnouncement = line
        }
        log("🪟 " + line)
    }

    /// Rebuilds the host pids and the list of windows worth following. Every 2 s, and whenever the set of managed
    /// windows changes, which is cheap: one property read plus one per window not seen before.
    private func discover(_ display: OpaquePointer) {
        guard let api, let names else { return }
        lastDiscovery = Date()
        // Clients attach and detach, and herdr can be started from a different terminal than the last one.
        hosts = X11Hosts.hostPIDs()
        let clients = api.x11ClientList(display, names: names)
        let alive = Set(clients)
        pidCache = pidCache.filter { alive.contains($0.key) }
        titleCache = titleCache.filter { alive.contains($0.key) }

        var found: [XWindowID] = []
        for window in clients {
            // Re-read every time: the owner of a window can change (a terminal server restarted behind the same
            // window id), and a stale pid quietly drops the window out of the host set for the rest of the session.
            let pid = api.x11Ints(display, window, names.netWmPid)
                .flatMap(\.first).map { Int32(bitPattern: $0) }
            pidCache[window] = pid
            // Titles are read once per window and refreshed here, not on every tick: the orb's position must not
            // depend on a property the window only changes when someone switches tabs.
            if pid.map(hosts.contains) == true {
                titleCache[window] = api.x11Title(display, window, names: names)
                found.append(window)
                continue
            }
            titleCache[window] = api.x11Title(display, window, names: names)
            if let title = titleCache[window], title.localizedCaseInsensitiveContains("herdr") {
                found.append(window)
            }
        }
        // Front-most first, so both of WindowPin's rules (a herdr title, else the terminal's front window) pick
        // what the user is actually looking at when a terminal has several windows.
        let stacking = api.x11Stacking(display, names: names)
        let ranked = stacking.filter { found.contains($0) } + found.filter { !stacking.contains($0) }
        candidates = ranked
        watch(display, ranked)
    }

    /// Subscribes to the windows being followed, and unsubscribes from the ones that dropped out. A foreign window
    /// may be watched for structure changes; that is how a move or a minimize reaches us without a poll.
    private func watch(_ display: OpaquePointer, _ windows: [XWindowID]) {
        guard let api else { return }
        let mask = X11Constant.structureNotifyMask | X11Constant.propertyChangeMask
        for window in windows where !watched.contains(window) {
            _ = api.selectInput(display, window, mask)
            watched.insert(window)
        }
        let dropped = watched.subtracting(windows)
        for window in dropped {
            // A destroyed window can't be unsubscribed from; selecting no events is the harmless equivalent.
            _ = api.selectInput(display, window, 0)
            watched.remove(window)
        }
    }

    /// The tracked windows as WindowPin sees them, on-screen ones first.
    private func windows(_ display: OpaquePointer) -> [WindowPin.Window] {
        guard let api, let names else { return [] }
        let desktop = api.x11CurrentDesktop(display, names: names)
        var shown: [WindowPin.Window] = []
        var all: [WindowPin.Window] = []
        for window in candidates {
            // A window that vanished between the client list and here is simply not a candidate this tick.
            guard let frame = api.x11FrameRect(display, window, names: names) else { continue }
            let entry = WindowPin.Window(number: Int(window), pid: pidCache[window] ?? 0, layer: 0,
                                         name: titleCache[window], frame: frame,
                                         isOnScreen: isOnScreen(api, display, window, names: names, desktop: desktop))
            all.append(entry)
            if entry.isOnScreen { shown.append(entry) }
        }
        return WindowPin.merge(onScreen: shown, cached: all)
    }

    /// Whether the window manager is showing the window at all: viewable, not minimized, and on the desktop being
    /// looked at. The signals are read together because they disagree: `IsViewable` is X's own answer (a minimized
    /// or withdrawn window stops being viewable), `_NET_WM_STATE_HIDDEN` is what EWMH window managers write and
    /// `WM_STATE: Iconic` is the ICCCM equivalent — mutter sets all three.
    private func isOnScreen(_ api: X11API, _ display: OpaquePointer, _ window: XWindowID,
                            names: X11Names, desktop: UInt32?) -> Bool {
        guard api.x11IsViewable(display, window) else { return false }
        if api.x11Ints(display, window, names.netWmState)?.contains(UInt32(names.stateHidden)) == true {
            return false
        }
        if api.x11Ints(display, window, names.wmState)?.first == X11Constant.iconicState { return false }
        // 0xFFFFFFFF is "on every desktop", which is on screen wherever the user is.
        if let desktop, let on = api.x11Ints(display, window, names.netWmDesktop)?.first, on != UInt32.max,
           on != desktop {
            return false
        }
        return true
    }

    /// One tick: read the windows being followed, publish what changed, and pick the rate for the next one.
    private func refresh(_ display: OpaquePointer) {
        if Date().timeIntervalSince(lastDiscovery) >= 2 { discover(display) }
        guard !candidates.isEmpty else {
            publish(hasHost: false, frame: nil)
            announce("no host window; the orb goes to the screen corner")
            return
        }
        let target = WindowPin.target(windows: windows(display), hosts: hosts)
        let moved = target?.frame != lastFrame
        lastFrame = target?.frame
        publish(hasHost: true, frame: target?.frame)
        if let target {
            announce("host window \(String(format: "0x%lx", UInt(target.number))) \"\(target.name ?? "?")\" "
                     + "frame \(format(target.frame))")
        } else {
            announce("host window exists but is hidden; the orb hides")
        }
        tune(display, moving: moved)
    }

    /// 10 Hz while the terminal has the focus or the window is moving under it (it can be dragged), 1 Hz otherwise:
    /// a window can't be dragged without being in front, but it can still be minimized, restored or switched away
    /// from, and that is what the slow rate is for.
    private func tune(_ display: OpaquePointer, moving: Bool) {
        guard let api, let names else { return }
        let front = api.x11ActiveWindow(display, names: names).map(candidates.contains) ?? false
        let wanted: TimeInterval = front || moving ? 0.1 : 1
        guard loop.tickInterval != wanted else { return }
        loop.tickInterval = wanted
        announce("cadence \(wanted == 0.1 ? "100ms" : "1000ms") (terminal \(front ? "in front" : "behind"))",
                 cadence: true)
    }

    /// Drains pending X events. They are read as raw bytes: every event starts with its type and ends its common
    /// part with the window it happened to, which is all the tracker needs to know something must be re-read.
    private func drain(_ display: OpaquePointer) {
        guard let api, let names else { return }
        // sizeof(XEvent) is 192 bytes on 64-bit Xlib; 32 eight-byte words is comfortably more.
        var event = [UInt64](repeating: 0, count: 32)
        var rediscover = false
        var touched = false
        while api.pending(display) > 0 {
            let status = event.withUnsafeMutableBytes { api.nextEvent(display, $0.baseAddress) }
            guard status == 0 else { break }
            let (type, window) = event.withUnsafeBytes {
                ($0.loadUnaligned(fromByteOffset: 0, as: Int32.self),
                 $0.loadUnaligned(fromByteOffset: 32, as: XWindowID.self))
            }
            switch type {
            case 17, 18, 19, 21, 22, 28: // DestroyNotify, Unmap, Map, Reparent, Configure, Property
                touched = true
                if window == names.root || type == 17 { rediscover = true }
            default:
                break
            }
        }
        guard touched else { return }
        if rediscover { discover(display) }
        refresh(display)
    }

    private func format(_ rect: Rect) -> String {
        "\(Int(rect.x.rounded())),\(Int(rect.y.rounded())) \(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }
}
