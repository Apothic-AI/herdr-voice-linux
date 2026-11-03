import Foundation
import HerdrVoiceCore

#if canImport(Glibc)
import Glibc
#endif

/// `Window`, `Atom` and `KeySym` are all `unsigned long` in Xlib's ABI, so one type covers them.
typealias XWindowID = UInt
typealias XAtomID = UInt

/// Xlib's `XErrorHandler`: `int (*)(Display *, XErrorEvent *)`. Named once because it appears inside another
/// C function type, and nested `@convention(c)` attributes don't parse.
typealias XErrorHandlerFn = @convention(c) (OpaquePointer?, OpaquePointer?) -> Int32

/// Xlib reached through `dlopen` rather than a system-library target.
///
/// The port needs about twenty Xlib entry points, and they are all plain C functions with scalar arguments, so
/// loading them by name keeps this side of the port free of build-system changes: no module map, no linker flags,
/// no `Package.swift` edit. `nil` means "this box has no Xlib at all" (a Wayland-only session), which the tracker
/// and the hotkeys both treat as "no host, no keys" rather than a crash.
final class X11API {
    static let shared = X11API()

    let open: @convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?
    let close: @convention(c) (OpaquePointer?) -> Int32
    let defaultRootWindow: @convention(c) (OpaquePointer?) -> XWindowID
    let internAtom: @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32) -> XAtomID
    let getWindowProperty: @convention(c) (
        OpaquePointer?, XWindowID, XAtomID, Int, Int, Int32, XAtomID,
        UnsafeMutablePointer<XAtomID>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<UInt>?,
        UnsafeMutablePointer<UInt>?, UnsafeMutablePointer<UnsafeMutablePointer<CUnsignedChar>?>?
    ) -> Int32
    let free: @convention(c) (UnsafeMutableRawPointer?) -> Int32
    let translateCoordinates: @convention(c) (
        OpaquePointer?, XWindowID, XWindowID, Int32, Int32,
        UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<XWindowID>?
    ) -> Int32
    let getGeometry: @convention(c) (
        OpaquePointer?, XWindowID, UnsafeMutablePointer<XWindowID>?, UnsafeMutablePointer<Int32>?,
        UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
        UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?
    ) -> Int32
    let getWindowAttributes: @convention(c) (OpaquePointer?, XWindowID, UnsafeMutableRawPointer?) -> Int32
    let setErrorHandler: @convention(c) (XErrorHandlerFn?) -> UnsafeMutableRawPointer?
    let sync: @convention(c) (OpaquePointer?, Int32) -> Int32
    let grabKey: @convention(c) (OpaquePointer?, Int32, UInt32, XWindowID, Int32, Int32, Int32) -> Int32
    let ungrabKey: @convention(c) (OpaquePointer?, Int32, UInt32, XWindowID) -> Int32
    let selectInput: @convention(c) (OpaquePointer?, XWindowID, Int) -> Int32
    let pending: @convention(c) (OpaquePointer?) -> Int32
    let nextEvent: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Int32
    let connectionNumber: @convention(c) (OpaquePointer?) -> Int32
    let stringToKeysym: @convention(c) (UnsafePointer<CChar>?) -> UInt
    let keysymToKeycode: @convention(c) (OpaquePointer?, UInt) -> CUnsignedChar
    let flush: @convention(c) (OpaquePointer?) -> Int32

    private init?() {
        // libX11.so.6 is the SONAME every distro ships; the bare name is the -dev symlink.
        guard let handle = dlopen("libX11.so.6", RTLD_NOW) ?? dlopen("libX11.so", RTLD_NOW) else { return nil }

        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            guard let found = dlsym(handle, name) else { return nil }
            return unsafeBitCast(found, to: T.self)
        }

        guard let open = symbol("XOpenDisplay", (@convention(c) (UnsafePointer<CChar>?) -> OpaquePointer?).self),
              let close = symbol("XCloseDisplay", (@convention(c) (OpaquePointer?) -> Int32).self),
              let root = symbol("XDefaultRootWindow", (@convention(c) (OpaquePointer?) -> XWindowID).self),
              let intern = symbol("XInternAtom", (@convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32) -> XAtomID).self),
              let property = symbol("XGetWindowProperty", (@convention(c) (
                  OpaquePointer?, XWindowID, XAtomID, Int, Int, Int32, XAtomID,
                  UnsafeMutablePointer<XAtomID>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<UInt>?,
                  UnsafeMutablePointer<UInt>?, UnsafeMutablePointer<UnsafeMutablePointer<CUnsignedChar>?>?
              ) -> Int32).self),
              let freeData = symbol("XFree", (@convention(c) (UnsafeMutableRawPointer?) -> Int32).self),
              let translate = symbol("XTranslateCoordinates", (@convention(c) (
                  OpaquePointer?, XWindowID, XWindowID, Int32, Int32,
                  UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<XWindowID>?
              ) -> Int32).self),
              let geometry = symbol("XGetGeometry", (@convention(c) (
                  OpaquePointer?, XWindowID, UnsafeMutablePointer<XWindowID>?, UnsafeMutablePointer<Int32>?,
                  UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?,
                  UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?
              ) -> Int32).self),
              let attributes = symbol("XGetWindowAttributes", (@convention(c) (OpaquePointer?, XWindowID, UnsafeMutableRawPointer?) -> Int32).self),
              let errorHandler = symbol("XSetErrorHandler", (@convention(c) (XErrorHandlerFn?) -> UnsafeMutableRawPointer?).self),
              let sync = symbol("XSync", (@convention(c) (OpaquePointer?, Int32) -> Int32).self),
              let grab = symbol("XGrabKey", (@convention(c) (OpaquePointer?, Int32, UInt32, XWindowID, Int32, Int32, Int32) -> Int32).self),
              let ungrab = symbol("XUngrabKey", (@convention(c) (OpaquePointer?, Int32, UInt32, XWindowID) -> Int32).self),
              let selectInput = symbol("XSelectInput", (@convention(c) (OpaquePointer?, XWindowID, Int) -> Int32).self),
              let pending = symbol("XPending", (@convention(c) (OpaquePointer?) -> Int32).self),
              let nextEvent = symbol("XNextEvent", (@convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Int32).self),
              let connection = symbol("XConnectionNumber", (@convention(c) (OpaquePointer?) -> Int32).self),
              let keysymOfName = symbol("XStringToKeysym", (@convention(c) (UnsafePointer<CChar>?) -> UInt).self),
              let keycodeOfKeysym = symbol("XKeysymToKeycode", (@convention(c) (OpaquePointer?, UInt) -> CUnsignedChar).self),
              let flush = symbol("XFlush", (@convention(c) (OpaquePointer?) -> Int32).self)
        else { return nil }

        self.open = open
        self.close = close
        self.defaultRootWindow = root
        self.internAtom = intern
        self.getWindowProperty = property
        self.free = freeData
        self.translateCoordinates = translate
        self.getGeometry = geometry
        self.getWindowAttributes = attributes
        self.setErrorHandler = errorHandler
        self.sync = sync
        self.grabKey = grab
        self.ungrabKey = ungrab
        self.selectInput = selectInput
        self.pending = pending
        self.nextEvent = nextEvent
        self.connectionNumber = connection
        self.stringToKeysym = keysymOfName
        self.keysymToKeycode = keycodeOfKeysym
        self.flush = flush
        // Hand the error hook straight over: reaching back for `X11API.shared` from here would re-enter this
        // initialiser and deadlock the first thread that touches Xlib.
        X11Errors.install(errorHandler)
    }
}

/// The Xlib constants this port needs. They are `#define`s in `X11/X.h`, so they're spelled out here.
enum X11Constant {
    /// `AnyPropertyType`, `XA_*` and `None` — the fixed atom ids Xlib defines for everyone.
    static let anyPropertyType: XAtomID = 0
    static let xaAtom: XAtomID = 4
    static let xaCardinal: XAtomID = 6
    static let xaString: XAtomID = 31

    static let shiftMask: UInt32 = 1 << 0
    static let lockMask: UInt32 = 1 << 1
    static let controlMask: UInt32 = 1 << 2
    static let mod1Mask: UInt32 = 1 << 3   // Alt on every mainstream layout
    static let mod2Mask: UInt32 = 1 << 4   // NumLock
    static let mod3Mask: UInt32 = 1 << 5   // ScrollLock
    static let mod4Mask: UInt32 = 1 << 6   // Super/Windows
    static let mod5Mask: UInt32 = 1 << 7
    static let anyModifier: UInt32 = 1 << 15

    /// The modifier combinations a grab has to cover, because X treats a locked modifier as a different bind:
    /// without these, Ctrl+Alt+M would stop working the moment CapsLock or NumLock was on.
    static let lockCombinations: [UInt32] = [0, lockMask, mod2Mask, lockMask | mod2Mask, mod3Mask, lockMask | mod3Mask]

    static let keyPressMask = 1 << 0
    static let structureNotifyMask = 1 << 17
    static let propertyChangeMask = 1 << 22

    static let keyPress: Int32 = 2
    static let grabModeAsync: Int32 = 1
    /// `IsViewable`.
    static let isViewable: Int32 = 2
    static let xkEscape: UInt = 0xff1b
    /// `Iconic` in `WM_STATE`.
    static let iconicState: UInt32 = 3
}

/// Xlib reports protocol errors asynchronously through a process-wide handler. It is installed once, and each
/// deliberately-risky call brackets itself with `clear` / `codes` plus an `XSync`, so a grabbed-by-someone-else
/// key or a window that vanished mid-tick is a value to look at rather than a crash or a line of noise on stderr.
enum X11Errors {
    static let badWindow: UInt8 = 3
    static let badAccess: UInt8 = 10
    static let badMatch: UInt8 = 8

    private static let lock = NSLock()
    private static var records: [(display: OpaquePointer?, code: UInt8)] = []
    /// How many times each distinct failure has been seen, so it can be reported once and counted after that.
    private static var announced: [String: Int] = [:]
    private static var installed = false

    static func install(_ setHandler: (XErrorHandlerFn?) -> UnsafeMutableRawPointer?) {
        lock.lock()
        let first = !installed
        installed = true
        lock.unlock()
        guard first else { return }
        _ = setHandler(x11ErrorHandler as XErrorHandlerFn)
    }

    fileprivate static func record(display: OpaquePointer?, code: UInt8, request: UInt8, minor: UInt8) {
        let signature = "\(code)/\(request)/\(minor)"
        lock.lock()
        records.append((display, code))
        if records.count > 64 { records.removeFirst(records.count - 64) }
        let seen = (announced[signature] ?? 0) + 1
        announced[signature] = seen
        lock.unlock()
        // Once per distinct failure, then silence: a per-frame present error would otherwise bury every other line.
        // The default is worse than noisy — Xlib says nothing at all, which is how a rejected `XPutImage` became a
        // window that was mapped, `IsViewable` and entirely blank with no trace in any log.
        guard seen == 1 else { return }
        log("✖ X11 error \(name(code)) (\(code)) on request \(request)/\(minor): the server dropped it")
    }

    /// The X protocol error names from Xproto.h, spelled out so reporting one never re-enters Xlib.
    static func name(_ code: UInt8) -> String {
        switch code {
        case 1: "BadRequest"
        case 2: "BadValue"
        case 3: "BadWindow"
        case 4: "BadPixmap"
        case 5: "BadAtom"
        case 6: "BadCursor"
        case 7: "BadFont"
        case 8: "BadMatch"
        case 9: "BadDrawable"
        case 10: "BadAccess"
        case 11: "BadAlloc"
        case 12: "BadColor"
        case 13: "BadGC"
        case 14: "BadIDChoice"
        case 15: "BadName"
        case 16: "BadLength"
        case 17: "BadImplementation"
        default: "error \(code)"
        }
    }

    /// Every distinct failure seen so far, keyed `code/request/minor`, with how many times it happened.
    static var counts: [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return announced
    }

    /// Forgets errors so far, for the display whose next calls are being judged.
    static func clear(_ display: OpaquePointer?) {
        lock.lock()
        records.removeAll { $0.display == display }
        lock.unlock()
    }

    /// Drains the codes recorded for `display` since the last `clear`.
    static func codes(_ display: OpaquePointer?) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        let mine = records.filter { $0.display == display }.map(\.code)
        records.removeAll { $0.display == display }
        return mine
    }
}

/// `XErrorEvent` is `{int type; Display *display; XID resourceid; unsigned long serial; unsigned char error_code;
/// unsigned char request_code; unsigned char minor_code;}`. Only the three trailing bytes are wanted, and reading them at
/// their documented offsets avoids mirroring the whole struct in Swift just to throw it away.
private func x11ErrorHandler(_ display: OpaquePointer?, _ event: OpaquePointer?) -> Int32 {
    guard let event else { return 0 }
    let code = UnsafeRawPointer(event).load(fromByteOffset: 32, as: UInt8.self)
    let request = UnsafeRawPointer(event).load(fromByteOffset: 33, as: UInt8.self)
    let minor = UnsafeRawPointer(event).load(fromByteOffset: 34, as: UInt8.self)
    X11Errors.record(display: display, code: code, request: request, minor: minor)
    return 0 // Swallow it: Xlib's default handler prints to stderr and we already know what happened.
}

/// The atoms and windows this port reads, interned once per display.
struct X11Names {
    let clientList: XAtomID
    let clientListStacking: XAtomID
    let netWmName: XAtomID
    let wmName: XAtomID
    let netWmPid: XAtomID
    let frameExtents: XAtomID
    let netWmState: XAtomID
    let stateHidden: XAtomID
    let netWmDesktop: XAtomID
    let currentDesktop: XAtomID
    let activeWindow: XAtomID
    let wmState: XAtomID
    let utf8String: XAtomID
    let root: XWindowID

    init?(_ api: X11API, display: OpaquePointer) {
        func atom(_ name: String) -> XAtomID {
            name.withCString { api.internAtom(display, $0, 0) }
        }
        root = api.defaultRootWindow(display)
        guard root != 0 else { return nil }
        clientList = atom("_NET_CLIENT_LIST")
        clientListStacking = atom("_NET_CLIENT_LIST_STACKING")
        netWmName = atom("_NET_WM_NAME")
        wmName = atom("WM_NAME")
        netWmPid = atom("_NET_WM_PID")
        frameExtents = atom("_NET_FRAME_EXTENTS")
        netWmState = atom("_NET_WM_STATE")
        stateHidden = atom("_NET_WM_STATE_HIDDEN")
        netWmDesktop = atom("_NET_WM_DESKTOP")
        currentDesktop = atom("_NET_CURRENT_DESKTOP")
        activeWindow = atom("_NET_ACTIVE_WINDOW")
        wmState = atom("WM_STATE")
        utf8String = atom("UTF8_STRING")
    }
}

/// Reads one property as raw bytes, plus what X says about its encoding.
///
/// A property read is a round trip, so callers on a hot path are expected to ask for one property at a time and
/// cache what they learn; `length` caps it at 1024 32-bit words, far more than any of these properties carries.
///
/// The buffer is byte-for-byte what Xlib allocated, and for `format == 32` that is an array of C `long`s and not of
/// 32-bit words: X widens every element to the machine's word size, so an eight-byte stride is what reads
/// `_NET_CLIENT_LIST` correctly on LP64. Reading it at four bytes instead interleaves each window id with the
/// zero high half of its own `long`, which looks like twice as many windows, half of them invalid.
func x11Property(_ api: X11API, _ display: OpaquePointer, _ window: XWindowID, _ atom: XAtomID,
                 type: XAtomID = X11Constant.anyPropertyType) -> (format: Int32, bytes: [UInt8])? {
    var actualType: XAtomID = 0
    var format: Int32 = 0
    var count: UInt = 0
    var after: UInt = 0
    var data: UnsafeMutablePointer<CUnsignedChar>?
    let status = api.getWindowProperty(display, window, atom, 0, 1024, 0, type,
                                       &actualType, &format, &count, &after, &data)
    guard status == 0, let data else { return nil }
    defer { _ = api.free(data) }
    guard count > 0 else { return nil }
    let element: Int
    switch format {
    case 32: element = MemoryLayout<Int>.size
    case 16: element = MemoryLayout<Int16>.size
    default: element = 1
    }
    return (format, Array(UnsafeBufferPointer(start: data, count: Int(count) * element)))
}

extension X11API {
    /// A cardinals/atoms property, as integers. `format == 32` is the only width X uses for them, and Xlib widens
    /// those elements to `long`, so they are read at that stride and then narrowed.
    func x11Ints(_ display: OpaquePointer, _ window: XWindowID, _ atom: XAtomID) -> [UInt32]? {
        guard let (format, bytes) = x11Property(self, display, window, atom), format == 32 else { return nil }
        let stride = MemoryLayout<Int>.size
        return bytes.withUnsafeBytes { raw in
            (0..<(raw.count / stride)).map {
                UInt32(truncatingIfNeeded: raw.loadUnaligned(fromByteOffset: $0 * stride, as: UInt.self))
            }
        }
    }

    /// The window's title: `_NET_WM_NAME` (UTF-8) first, then the older `WM_NAME`, which some toolkits only set.
    func x11Title(_ display: OpaquePointer, _ window: XWindowID, names: X11Names) -> String? {
        for (atom, type) in [(names.netWmName, names.utf8String), (names.wmName, X11Constant.anyPropertyType)] {
            if let (format, bytes) = x11Property(self, display, window, atom, type: type), format == 8,
               let text = String(bytes: bytes, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    /// The window's rectangle in X11 screen coordinates (origin top-left), including the window manager's frame.
    ///
    /// X gives the client area's root-relative origin and the client size; `_NET_FRAME_EXTENTS` is the decoration
    /// the window manager drew around it, ordered left, right, top, bottom. Adding it in turns the client rectangle
    /// into the frame rectangle, so the orb lines up with the edge of the window rather than the inside of its
    /// client area. Windows that draw their own titlebar (GTK/GNOME's client-side decorations) have no extents and
    /// are already their own frame, which is why a missing property means zero and not "unknown".
    func x11FrameRect(_ display: OpaquePointer, _ window: XWindowID, names: X11Names) -> Rect? {
        var root: XWindowID = 0
        var x: Int32 = 0
        var y: Int32 = 0
        var width: UInt32 = 0
        var height: UInt32 = 0
        var border: UInt32 = 0
        var depth: UInt32 = 0
        guard getGeometry(display, window, &root, &x, &y, &width, &height, &border, &depth) != 0 else { return nil }
        var originX: Int32 = 0
        var originY: Int32 = 0
        var child: XWindowID = 0
        guard translateCoordinates(display, window, names.root, 0, 0, &originX, &originY, &child) != 0 else {
            return nil
        }
        let extents = x11Ints(display, window, names.frameExtents) ?? []
        let left = extents.count > 0 ? Double(extents[0]) : 0
        let right = extents.count > 1 ? Double(extents[1]) : 0
        let top = extents.count > 2 ? Double(extents[2]) : 0
        let bottom = extents.count > 3 ? Double(extents[3]) : 0
        return Rect(x: Double(originX) - left, y: Double(originY) - top,
                    width: Double(width) + left + right, height: Double(height) + top + bottom)
    }

    /// Whether the window manager is showing the window at all (`IsViewable`).
    ///
    /// This is the one signal that needs no cooperation from the window manager: a minimized window, a window on
    /// another desktop and a window whose tab was closed all stop being viewable, and X reports that whether or not
    /// EWMH properties were written. `XWindowAttributes` is 136 bytes here and `map_state` sits at byte 92 (checked
    /// with `offsetof`), so the struct is read into a buffer rather than mirrored in Swift: only one field is
    /// wanted, and a hand-written mirror of a header we don't own is the kind of thing that rots silently.
    func x11IsViewable(_ display: OpaquePointer, _ window: XWindowID) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 256)
        let status = buffer.withUnsafeMutableBytes { getWindowAttributes(display, window, $0.baseAddress) }
        guard status != 0 else { return false }
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 92, as: Int32.self) }
            == X11Constant.isViewable
    }

    /// The managed windows, in the window manager's screen order: `_NET_CLIENT_LIST` is bottom to top, and the
    /// stacking order is the front-to-back answer when a title can't be read.
    func x11ClientList(_ display: OpaquePointer, names: X11Names) -> [XWindowID] {
        guard let ids = x11Ints(display, names.root, names.clientList) else { return [] }
        return ids.map(XWindowID.init)
    }

    /// Front-most first: the stacking list reversed. Falls back to the creation-ordered list.
    func x11Stacking(_ display: OpaquePointer, names: X11Names) -> [XWindowID] {
        if let ids = x11Ints(display, names.root, names.clientListStacking) {
            return ids.map(XWindowID.init).reversed()
        }
        return x11ClientList(display, names: names).reversed()
    }

    /// The window that currently has input focus, as the window manager reports it.
    func x11ActiveWindow(_ display: OpaquePointer, names: X11Names) -> XWindowID? {
        guard let ids = x11Ints(display, names.root, names.activeWindow), let first = ids.first else { return nil }
        return XWindowID(first)
    }

    func x11CurrentDesktop(_ display: OpaquePointer, names: X11Names) -> UInt32? {
        x11Ints(display, names.root, names.currentDesktop)?.first
    }
}
