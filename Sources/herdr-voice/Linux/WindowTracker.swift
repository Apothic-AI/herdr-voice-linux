import Foundation
import HerdrVoiceCore

/// Finds the terminal window showing Herdr on Linux, and reports where the orb should sit.
///
/// On macOS this walks the process tree to the terminal app and reads `CGWindowList`. On Linux the same question is
/// answered over X11: which managed windows exist (`_NET_CLIENT_LIST`), whose `_NET_WM_NAME`/`WM_NAME` mentions
/// herdr or whose owning process is a terminal descended from `herdr`, and where that window is
/// (`_NET_FRAME_EXTENTS` + translate coordinates, which is the geometry the window manager actually gave it).
///
/// Contract (identical on both platforms): `start(onChange:)` calls back on the main thread only when the answer
/// changes, with the window rectangle in the platform's own screen coordinates (AppKit: bottom-left origin;
/// X11: top-left) and `nil` when there is no window to follow.
///
/// TODO(linux-port): implement over X11. See docs/linux-port.md.
final class WindowTracker {
    typealias Result = (hasHost: Bool, frame: Rect?)

    private var timer: DispatchSourceTimer?

    func start(onChange: @escaping (_ hasHost: Bool, _ frame: Rect?) -> Void) {
        log("⚠ window tracking is not implemented on Linux yet; the orb stays in the screen corner")
    }
}
