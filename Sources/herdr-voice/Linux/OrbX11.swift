import CCairo
import CX11
import Foundation
import HerdrVoiceCore
#if canImport(Glibc)
import Glibc
#endif

/// The handful of X11 constants the orb uses.
///
/// Xlib spells these as function-like or bare macros, and the clang importer only carries the bare ones across, so
/// they are written out here with the C name each one stands for. Keeping them in one place means the window code
/// reads the way the Xlib manual does.
enum X11 {
    // XSetWindowAttributes value mask (X.h): which fields of the struct are in use.
    static let cwBackPixel: UInt = 1 << 1
    static let cwBorderPixel: UInt = 1 << 3
    static let cwOverrideRedirect: UInt = 1 << 9
    static let cwEventMask: UInt = 1 << 11
    static let cwColormap: UInt = 1 << 13

    // Event masks (X.h).
    static let keyPressMask: Int = 1 << 0
    static let buttonPressMask: Int = 1 << 2
    static let buttonReleaseMask: Int = 1 << 3
    static let enterWindowMask: Int = 1 << 4
    static let leaveWindowMask: Int = 1 << 5
    static let pointerMotionMask: Int = 1 << 6
    static let exposureMask: Int = 1 << 15
    static let structureNotifyMask: Int = 1 << 17
    static let substructureNotifyMask: Int = 1 << 19

    // XGetVisualInfo mask (Xutil.h).
    static let visualScreenMask: Int = 0x2
    static let visualDepthMask: Int = 0x4
    static let visualClassMask: Int = 0x8

    // Event types (X.h).
    static let keyPress: Int32 = 2
    static let buttonPress: Int32 = 4
    static let buttonRelease: Int32 = 5
    static let motionNotify: Int32 = 6
    static let expose: Int32 = 12
    static let destroyNotify: Int32 = 17
    static let unmapNotify: Int32 = 18
    static let mapNotify: Int32 = 19
    static let configureNotify: Int32 = 22
    static let mappingNotify: Int32 = 34

    static let inputOutput: UInt32 = 1
    /// TrueColor: the only visual class with a straightforward ARGB mapping.
    static let trueColor: Int32 = 4
    static let allocNone: Int32 = 0
    static let grabModeAsync: Int32 = 1

    static let button1: UInt32 = 1
    static let button3: UInt32 = 3
    static let controlMask: UInt32 = 1 << 2

    static let escapeKeySym: UInt = 0xff1b
    static let returnKeySym: UInt = 0xff0d
    static let currentTime: UInt = 0
}

/// One X connection, shared by the orb window and its popup menu.
///
/// The connection belongs to the orb's frame thread: nothing else touches it, so Xlib's per-connection locking
/// (enabled by `XInitThreads`) is never contended. The main thread only ever hands work over through `Orb`'s state.
///
/// The alpha visual is picked the way a compositing toolkit does it: every depth-32 TrueColor visual on the screen
/// is asked for its XRender format, and the first one that is the standard ARGB32 format wins — that is the format
/// Cairo and Mutter both understand, so what `cairo_image_surface` produces lands on screen unchanged. When the
/// screen offers none, or no compositor is running to blend it, the window falls back to an opaque one and draws its
/// own shadow rather than pretend to be translucent.
final class OrbX11 {
    let display: OpaquePointer
    let screen: Int32
    let root: XID
    /// The ARGB32 visual, when the screen has one and a compositor is running to composite it.
    let alphaVisual: UnsafeMutablePointer<Visual>?
    let alphaColormap: XID
    private let defaultDepth: Int32
    private let defaultVisual: UnsafeMutablePointer<Visual>?
    private let defaultColormap: XID

    var hasAlpha: Bool { alphaVisual != nil }

    init?() {
        guard let display = XOpenDisplay(nil) else { return nil }
        self.display = display
        screen = XDefaultScreen(display)
        root = XDefaultRootWindow(display)
        defaultDepth = XDefaultDepth(display, screen)
        defaultVisual = XDefaultVisual(display, screen)
        defaultColormap = XDefaultColormap(display, screen)
        if let visual = OrbX11.findAlphaVisual(display, screen: screen) {
            alphaVisual = visual
            alphaColormap = XCreateColormap(display, root, visual, X11.allocNone)
        } else {
            alphaVisual = nil
            alphaColormap = 0
        }
    }

    deinit { XCloseDisplay(display) }

    /// The visual a window of `depth` should use, with the colormap that goes with it.
    func visual(forAlpha: Bool) -> (visual: UnsafeMutablePointer<Visual>?, colormap: XID, depth: Int32) {
        if forAlpha, let visual = alphaVisual {
            return (visual, alphaColormap, 32)
        }
        return (defaultVisual, defaultColormap, defaultDepth)
    }

    private static func findAlphaVisual(_ display: OpaquePointer, screen: Int32) -> UnsafeMutablePointer<Visual>? {
        var template = XVisualInfo()
        template.screen = screen
        template.depth = 32
        var count: Int32 = 0
        // Screen and depth only: adding VisualClassMask would also filter on `template.class`, which is zero
        // (StaticGray) until set, and the query would come back empty. The class is checked per visual below.
        let mask = X11.visualScreenMask | X11.visualDepthMask
        guard let infos = XGetVisualInfo(display, mask, &template, &count), count > 0 else { return nil }
        defer { XFree(infos) }
        let argb32 = XRenderFindStandardFormat(display, Int32(X11.standardARGB32))
        var fallback: UnsafeMutablePointer<Visual>?
        for index in 0..<Int(count) {
            let info = infos[index]
            guard info.class == X11.trueColor, let visual = info.visual else { continue }
            guard let format = XRenderFindVisualFormat(display, visual), format.pointee.type == X11.pictTypeDirect
            else { continue }
            guard format.pointee.direct.alphaMask != 0 else { continue }
            if format == argb32 { return visual }
            if fallback == nil { fallback = visual }
        }
        return fallback
    }

    /// Whether a compositing manager owns `_NET_WM_CM_S<n>`. Without one an ARGB window's alpha is not blended
    /// against what's behind it, so a translucent orb would render as a black square; the orb checks this before
    /// choosing the alpha visual.
    var hasCompositor: Bool {
        let name = "_NET_WM_CM_S\(screen)"
        let atom = XInternAtom(display, name, 0)
        guard atom != 0 else { return false }
        return XGetSelectionOwner(display, atom) != 0
    }

    func atom(_ name: String) -> Atom { XInternAtom(display, name, 0) }

    /// Interned atoms, because `XInternAtom` is a round trip and the orb asks for the same few every second.
    private var atomCache: [String: Atom] = [:]

    func cachedAtom(_ name: String) -> Atom {
        if let known = atomCache[name] { return known }
        let atom = atom(name)
        atomCache[name] = atom
        return atom
    }

    private var cachedWorkArea: Rect?
    private var workAreaReadAt = 0.0

    /// The window manager's work area (what macOS reports as `visibleFrame`), or the whole screen when the WM
    /// doesn't publish one. Panels and docks are inside the difference.
    ///
    /// Cached for a second: reading it is two round trips, and placing the orb asks for it on every frame.
    func workArea(refreshedAt now: Double) -> Rect {
        if now - workAreaReadAt < 1, let cached = cachedWorkArea { return cached }
        workAreaReadAt = now
        let area = readWorkArea()
        cachedWorkArea = area
        return area
    }

    private func readWorkArea() -> Rect {
        let full = Rect(x: 0, y: 0, width: Double(XDisplayWidth(display, screen)),
                        height: Double(XDisplayHeight(display, screen)))
        let atom = cachedAtom("_NET_WORKAREA")
        guard atom != 0 else { return full }
        var actualType: Atom = 0
        var actualFormat: Int32 = 0
        var items: UInt = 0
        var bytesAfter: UInt = 0
        var property: UnsafeMutablePointer<UInt8>?
        let status = XGetWindowProperty(display, root, atom, 0, 4, 0, XA_CARDINAL, &actualType, &actualFormat,
                                        &items, &bytesAfter, &property)
        guard status == 0, let data = property else { return full }
        defer { XFree(data) }
        guard actualFormat == 32, items >= 4 else { return full }
        // Xlib hands format-32 properties back as an array of C longs.
        let values = data.withMemoryRebound(to: Int.self, capacity: 4) { Array(UnsafeBufferPointer(start: $0, count: 4)) }
        guard values[2] > 0, values[3] > 0 else { return full }
        return Rect(x: Double(values[0]), y: Double(values[1]), width: Double(values[2]), height: Double(values[3]))
    }

    /// Reads the children of `window`, bottom to top — the stacking order the server actually has.
    func children(of window: XID) -> [XID] {
        var rootReturn: XID = 0
        var parentReturn: XID = 0
        var childrenReturn: UnsafeMutablePointer<XID>?
        var count: UInt32 = 0
        guard XQueryTree(display, window, &rootReturn, &parentReturn, &childrenReturn, &count) != 0,
              let children = childrenReturn
        else { return [] }
        defer { XFree(children) }
        return Array(UnsafeBufferPointer(start: children, count: Int(count)))
    }

    /// Blocks until an X event arrives or `timeout` elapses. The orb's frame pacing runs off this, so clicks are
    /// answered immediately even while it is idling at 30 fps, and no thread ever spins.
    @discardableResult
    func waitForEvents(timeout: Double) -> (fd: Int32, result: Int32, revents: Int16) {
        let descriptor = XConnectionNumber(display)
        var fd = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let millis = Int32(max(0, min(timeout * 1000, 1000)).rounded())
        let result = poll(&fd, 1, millis)
        return (descriptor, result, fd.revents)
    }

    func flush() { XFlush(display) }
}

extension X11 {
    /// `PictTypeDirect` and `PictStandardARGB32` from Xrender.h.
    static let pictTypeDirect: Int32 = 1
    static let standardARGB32 = 0
}

/// One override-redirect X11 window with an ARGB (or, as a fallback, opaque) Cairo surface.
///
/// `override_redirect` is what makes this an orb rather than an app window: the window manager never sees it, so it
/// takes no focus, gets no frame and no taskbar entry, and is not reparented. It draws through a Cairo image surface
/// and blits that to the window with `CAIRO_OPERATOR_SOURCE`, which keeps the alpha channel exact (the server's
/// RENDER path would otherwise composite the alpha away) and gives the same pixels to a screenshot dump.
final class OrbX11Window {
    let id: XID
    let hasAlpha: Bool
    let depth: Int32
    private let x: OrbX11
    private let visual: UnsafeMutablePointer<Visual>?
    /// The pixels are drawn by Cairo on an image surface and then handed to the server with `XPutImage`.
    ///
    /// The obvious alternative — a Cairo xlib surface on the window — makes Cairo upload each frame through MIT-SHM,
    /// and every upload's `ShmCompletion` event wakes the frame thread, which draws again: a self-feeding loop that
    /// measured 1 300 fps. `XPutImage` is a plain copy, generates no events, and keeps the alpha channel exact.
    private var gc: GC?
    private var ximage: UnsafeMutablePointer<XImage>?
    private var image: OpaquePointer?
    private var imageWidth: Int32 = 0
    private var imageHeight: Int32 = 0
    private(set) var width: Int32
    private(set) var height: Int32
    private(set) var mapped = false

    /// Creates the window but leaves it unmapped, so callers can size and place it before anything is shown.
    init?(x: OrbX11, name: String, width: Int32, height: Int32, events: Int, alpha: Bool) {
        self.x = x
        self.width = width
        self.height = height
        let chosen = x.visual(forAlpha: alpha)
        visual = chosen.visual
        depth = chosen.depth
        hasAlpha = alpha && x.alphaVisual != nil
        var attributes = XSetWindowAttributes()
        attributes.override_redirect = 1
        attributes.background_pixel = 0
        attributes.border_pixel = 0
        attributes.colormap = chosen.colormap
        attributes.event_mask = events
        let mask = X11.cwOverrideRedirect | X11.cwBackPixel | X11.cwBorderPixel | X11.cwEventMask | X11.cwColormap
        id = XCreateWindow(x.display, x.root, 0, 0, UInt32(width), UInt32(height), 0, depth, X11.inputOutput,
                           visual, mask, &attributes)
        guard id != 0 else { return nil }
        setName(name)
        setClassHint(name)
    }

    deinit {
        cairo_surface_destroy(image)
        if let ximage { ximage.pointee.f.destroy_image(ximage) }
        if let gc { XFreeGC(x.display, gc) }
        XDestroyWindow(x.display, id)
    }

    private func setName(_ name: String) {
        // Both, so `xwininfo -root -tree` and xdotool find it by name, and a UTF-8-aware client reads the same one.
        name.withCString { XStoreName(x.display, id, $0) }
        let utf8 = x.atom("UTF8_STRING")
        let wmName = x.atom("_NET_WM_NAME")
        guard utf8 != 0, wmName != 0 else { return }
        var bytes = Array(name.utf8)
        XChangeProperty(x.display, id, wmName, utf8, 8, 0, &bytes, Int32(bytes.count))
    }

    private func setClassHint(_ name: String) {
        let hint = x.atom("WM_CLASS")
        let klass = name.replacingOccurrences(of: " ", with: "-")
        var bytes = Array("herdr-voice".utf8) + [0] + Array(klass.utf8) + [0]
        XChangeProperty(x.display, id, hint, XA_STRING, 8, 0, &bytes, Int32(bytes.count))
    }

    private func makeSurfaces() {
        if image == nil || imageWidth != width || imageHeight != height {
            cairo_surface_destroy(image)
            image = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, width, height)
            imageWidth = width
            imageHeight = height
        }
        if gc == nil { gc = XCreateGC(x.display, id, 0, nil) }
        if ximage == nil {
            // 32 bits per pixel in every case: the ARGB32 image surface's own layout, and what a depth-24 visual on
            // this server reads as well (the padding byte is ignored).
            ximage = XCreateImage(x.display, visual, UInt32(depth), 2 /* ZPixmap */, 0, nil, UInt32(width),
                                  UInt32(height), 32, 0)
        }
    }

    /// Paints one frame: `body` draws into a Cairo context over an ARGB32 image surface, then the pixels are put on
    /// the window with `XPutImage`. Returns that image surface so a caller can also write it out as a PNG.
    @discardableResult
    func render(_ body: (OpaquePointer, Double, Double) -> Void) -> OpaquePointer? {
        makeSurfaces()
        guard let image = image, let canvas = cairo_create(image), let gc, let ximage,
              let destination = ximage.pointee.data
        else { return nil }
        body(canvas, Double(width), Double(height))
        cairo_destroy(canvas)
        cairo_surface_flush(image)
        guard let source = cairo_image_surface_get_data(image) else { return nil }
        let sourceStride = Int(cairo_image_surface_get_stride(image))
        let destinationStride = Int(ximage.pointee.bytes_per_line)
        if sourceStride == destinationStride {
            memcpy(destination, source, sourceStride * Int(height))
        } else {
            let rowBytes = min(sourceStride, destinationStride)
            for row in 0..<Int(height) {
                memcpy(destination + row * destinationStride, source + row * sourceStride, rowBytes)
            }
        }
        XPutImage(x.display, id, gc, ximage, 0, 0, 0, 0, UInt32(width), UInt32(height))
        XFlush(x.display)
        return image
    }

    func dumpPNG(to path: String) {
        guard let image else { return }
        cairo_surface_flush(image)
        _ = cairo_surface_write_to_png(image, path)
    }

    /// The ARGB32 surface the last frame was drawn on, for writing a PNG straight from the pixels the window showed.
    var renderSurface: OpaquePointer? { image }

    /// The server's own answer to "is this window on screen", which is what the watchdog must not guess at.
    var isViewable: Bool {
        var attributes = XWindowAttributes()
        guard XGetWindowAttributes(x.display, id, &attributes) != 0 else { return false }
        return attributes.map_state == 2 // IsViewable
    }

    func resize(width newWidth: Int32, height newHeight: Int32) {
        guard newWidth != width || newHeight != height else { return }
        width = newWidth
        height = newHeight
        XResizeWindow(x.display, id, UInt32(newWidth), UInt32(newHeight))
        // The image and the XImage both carry the old size; both are rebuilt on the next frame.
        cairo_surface_destroy(image)
        image = nil
        imageWidth = 0
        imageHeight = 0
        if let ximage { ximage.pointee.f.destroy_image(ximage) }
        ximage = nil
    }

    func move(toX px: Int32, y py: Int32) {
        XMoveWindow(x.display, id, px, py)
    }

    func map() {
        XMapRaised(x.display, id)
        mapped = true
    }

    func unmap() {
        if mapped { XUnmapWindow(x.display, id) }
        mapped = false
    }

    func raise() { XRaiseWindow(x.display, id) }

    func grabPointer() -> Bool {
        let mask = X11.buttonPressMask | X11.buttonReleaseMask | X11.pointerMotionMask
        let status = XGrabPointer(x.display, id, 0, UInt32(mask), X11.grabModeAsync, X11.grabModeAsync, 0, 0,
                                  X11.currentTime)
        return status == 0 // GrabSuccess
    }

    func ungrabPointer() { XUngrabPointer(x.display, X11.currentTime) }

    func grabKeyboard() -> Bool {
        XGrabKeyboard(x.display, id, 1, X11.grabModeAsync, X11.grabModeAsync, X11.currentTime) == 0
    }

    /// True when this window is the top of the server's stacking order, ignoring windows listed in `ours` that may
    /// legitimately sit over it (the orb's own popup menu).
    func isTopmost(in x: OrbX11, above ours: Set<XID> = []) -> Bool {
        let stack = x.children(of: x.root)
        guard let top = stack.last else { return true }
        return top == id || ours.contains(top)
    }

    func ungrabKeyboard() { XUngrabKeyboard(x.display, X11.currentTime) }
}

// MARK: - event decoding

/// Xlib's `XEvent` is a union, which Swift imports without field access. Reinterpreting the event as the member its
/// `type` names is the documented layout guarantee Xlib makes, and keeps the call sites reading like the C code.
func orbEvent<T>(_ event: XEvent, as type: T.Type) -> T {
    withUnsafePointer(to: event) { pointer in
        pointer.withMemoryRebound(to: type, capacity: 1) { $0.pointee }
    }
}
