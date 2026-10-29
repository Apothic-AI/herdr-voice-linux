import Foundation

#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A rectangle in screen coordinates, portable across platforms.
///
/// CoreGraphics only exists on Apple platforms, and the window-pinning decisions that use rectangles are pure
/// logic worth testing everywhere, so the type lives here. The origin convention is the platform's: AppKit
/// reports bottom-left, X11 top-left. Each tracker converts into its own convention before handing a rectangle
/// to the orb, so nothing downstream has to care.
public struct Rect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= minX && px <= maxX && py >= minY && py <= maxY
    }

    public func insetBy(_ d: Double) -> Rect {
        Rect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d)
    }
}

#if canImport(CoreGraphics)
public extension Rect {
    init(_ r: CGRect) { self.init(x: r.minX, y: r.minY, width: r.width, height: r.height) }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
#endif
