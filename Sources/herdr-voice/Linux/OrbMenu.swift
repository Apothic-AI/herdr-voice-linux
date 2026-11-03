import CCairo
import CX11
import Foundation
import HerdrVoiceCore

/// The orb's right-click menu.
///
/// macOS pops an `NSMenu`; this path has no GTK and the orb already owns an X connection and a Cairo surface, so the
/// menu is a second override-redirect window painted here: a rounded panel with checkmarks, entries that are greyed
/// out when the model has no key, separators where the caller asked for them, a hover highlight, and a final
/// "Quit herdr-voice" item. Entries come from the caller's `menuChoices()` closure, asked for afresh on every open,
/// so the checkmark and the key availability are current.
///
/// Input is taken with an X pointer grab, the way a popped-up menu does it: every click goes to this window, and a
/// click outside the panel dismisses it. The grab is released on close, so the terminal keeps the pointer.
final class OrbMenu {
    /// One drawable line: an entry, or a separator with no text.
    private enum Line {
        case entry(Entry)
        case separator
    }

    private struct Entry {
        let title: String
        let checked: Bool
        let enabled: Bool
        let action: (() -> Void)?
    }

    private enum Metrics {
        static let rowHeight = 22.0
        static let separatorHeight = 9.0
        static let paddingY = 6.0
        static let paddingX = 12.0
        static let checkColumn = 20.0
        static let minWidth = 168.0
        static let maxWidth = 360.0
        static let corner: Double = 7
        static let fontSize = 12.0
    }

    private let x: OrbX11
    private var window: OrbX11Window?
    private var lines: [Line] = []
    private var hover = -1
    private var panelWidth = 200.0
    private var panelHeight = 100.0
    private var originX: Int32 = 0
    private var originY: Int32 = 0

    private(set) var isOpen = false
    /// Set when something changed that the panel has to show; the frame thread repaints and clears it.
    private(set) var needsPaint = false

    init(x: OrbX11) {
        self.x = x
    }

    var windowID: XID? { window?.id }

    /// Opens at `point` (root coordinates, the click position the way a menu drops from the cursor).
    func open(at point: (x: Int32, y: Int32), choices: [Orb.MenuChoice], onQuit: @escaping () -> Void) {
        var built: [Line] = choices.map { choice in
            .entry(Entry(title: choice.title, checked: choice.checked, enabled: choice.enabled,
                         action: choice.action))
        }
        // The caller's separators live on the entries that asked for them; insert them after their entry so the
        // menu reads top to bottom exactly as it was described.
        var withSeparators: [Line] = []
        for (index, choice) in choices.enumerated() {
            withSeparators.append(built[index])
            if choice.separatorAfter { withSeparators.append(.separator) }
        }
        built = withSeparators
        if !choices.isEmpty { built.append(.separator) }
        built.append(.entry(Entry(title: "Quit herdr-voice", checked: false, enabled: true, action: onQuit)))
        lines = built
        hover = -1

        panelWidth = min(max(measureWidth(built), Metrics.minWidth), Metrics.maxWidth)
        panelHeight = Metrics.paddingY * 2 + built.reduce(0.0) { sum, line in
            sum + (isSeparator(line) ? Metrics.separatorHeight : Metrics.rowHeight)
        }

        // Keep it on screen: prefer down-right of the cursor, flip up when it would fall off the bottom.
        let area = x.workArea(refreshedAt: Orb.now())
        var px = Double(point.x)
        var py = Double(point.y)
        if px + panelWidth > area.maxX { px = area.maxX - panelWidth - 4 }
        if py + panelHeight > area.maxY { py = py - panelHeight }
        px = max(area.minX + 4, px)
        py = max(area.minY + 4, py)
        originX = Int32(px.rounded())
        originY = Int32(py.rounded())

        guard let panel = panel() else { return }
        panel.resize(width: Int32(panelWidth.rounded()), height: Int32(panelHeight.rounded()))
        panel.move(toX: originX, y: originY)
        panel.map()
        // Above the orb, which is already above everything managed.
        panel.raise()
        _ = panel.grabPointer()
        _ = panel.grabKeyboard()
        isOpen = true
        needsPaint = true
    }

    func dismiss() {
        guard isOpen else { return }
        isOpen = false
        hover = -1
        window?.ungrabKeyboard()
        window?.ungrabPointer()
        window?.unmap()
        needsPaint = false
    }

    // MARK: - painting

    func paint() {
        guard isOpen, let panel = window else { return }
        let lines = self.lines
        let hover = self.hover
        let width = panelWidth
        let height = panelHeight
        panel.render { context, _, _ in
            let canvas = Canvas(cr: context)
            canvas.clear()
            // The panel: a dark, slightly translucent card with a hairline edge, like a system context menu.
            canvas.roundedRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1, radius: Metrics.corner)
            canvas.setColor(OrbColor(r: 0.098, g: 0.102, b: 0.118, a: 0.97))
            canvas.fill()
            canvas.roundedRect(x: 0.5, y: 0.5, width: width - 1, height: height - 1, radius: Metrics.corner)
            canvas.setColor(OrbColor.white.withAlpha(0.16))
            cairo_set_line_width(context, 1)
            cairo_stroke(context)

            var y = Metrics.paddingY
            var index = 0
            for line in lines {
                switch line {
                case .separator:
                    canvas.rectangle(x: Metrics.paddingX - 4, y: y + Metrics.separatorHeight / 2,
                                     width: width - (Metrics.paddingX - 4) * 2, height: 1)
                    canvas.setColor(OrbColor.white.withAlpha(0.14))
                    canvas.fill()
                    y += Metrics.separatorHeight
                case .entry(let entry):
                    let rowTop = y
                    if index == hover && entry.enabled {
                        canvas.roundedRect(x: 4, y: rowTop + 1.5, width: width - 8,
                                           height: Metrics.rowHeight - 3, radius: 4)
                        canvas.setColor(OrbColor.white.withAlpha(0.11))
                        canvas.fill()
                    }
                    if entry.checked { checkmark(canvas, at: Metrics.paddingX, midY: rowTop + Metrics.rowHeight / 2,
                                                 color: OrbColor.white.withAlpha(0.92)) }
                    let textColor = entry.enabled ? OrbColor.white.withAlpha(0.92)
                                                  : OrbColor.white.withAlpha(0.34)
                    text(canvas, entry.title, x: Metrics.paddingX + Metrics.checkColumn,
                         baseline: rowTop + Metrics.rowHeight / 2 + Metrics.fontSize * 0.36, color: textColor)
                    y += Metrics.rowHeight
                }
                index += 1
            }
        }
        needsPaint = false
    }

    private func checkmark(_ canvas: Canvas, at x: Double, midY: Double, color: OrbColor) {
        cairo_move_to(canvas.cr, x + 3, midY)
        cairo_line_to(canvas.cr, x + 6.5, midY + 3.5)
        cairo_line_to(canvas.cr, x + 13, midY - 4)
        canvas.setColor(color)
        cairo_set_line_width(canvas.cr, 1.6)
        cairo_set_line_cap(canvas.cr, CAIRO_LINE_CAP_ROUND)
        cairo_stroke(canvas.cr)
    }

    private func text(_ canvas: Canvas, _ string: String, x: Double, baseline: Double, color: OrbColor) {
        selectFont(canvas.cr)
        canvas.setColor(color)
        cairo_move_to(canvas.cr, x, baseline)
        string.withCString { cairo_show_text(canvas.cr, $0) }
    }

    private func selectFont(_ cr: OpaquePointer) {
        // Cairo's "toy" font API: no fontconfig pattern plumbing, and DejaVu Sans is what every desktop ships.
        cairo_select_font_face(cr, "Sans", CAIRO_FONT_SLANT_NORMAL, CAIRO_FONT_WEIGHT_NORMAL)
        cairo_set_font_size(cr, Metrics.fontSize)
    }

    private func measureWidth(_ lines: [Line]) -> Double {
        guard let surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, 1, 1),
              let cr = cairo_create(surface)
        else { return Metrics.minWidth }
        defer {
            cairo_destroy(cr)
            cairo_surface_destroy(surface)
        }
        selectFont(cr)
        var widest = 0.0
        for line in lines {
            guard case .entry(let entry) = line else { continue }
            var extents = cairo_text_extents_t()
            entry.title.withCString { cairo_text_extents(cr, $0, &extents) }
            widest = max(widest, extents.x_advance)
        }
        return widest + Metrics.paddingX * 2 + Metrics.checkColumn + 8
    }

    // MARK: - input

    /// Routes one X event while the menu is open. Returns true when the event was consumed here.
    @discardableResult
    func handle(_ event: XEvent) -> Bool {
        guard isOpen, let panel = window else { return false }
        let any = orbEvent(event, as: XAnyEvent.self)
        switch any.type {
        case X11.expose, X11.mapNotify, X11.configureNotify:
            // Mapping a window clears its contents to the background, and an X server is free to drop a window's
            // pixels at any time; both arrive here, and both mean the panel has to be drawn again.
            needsPaint = true
            return true
        case X11.motionNotify:
            let motion = orbEvent(event, as: XMotionEvent.self)
            let localY = Double(motion.y_root - originY)
            let row = rowIndex(atY: localY)
            if row != hover {
                hover = row
                needsPaint = true
            }
            return true
        case X11.buttonPress:
            let button = orbEvent(event, as: XButtonEvent.self)
            // Every click is grabbed, so a press anywhere resolves the menu — inside it chooses, outside dismisses.
            let localY = Double(button.y_root - originY)
            let inside = button.x_root >= originX && button.x_root < originX + Int32(panelWidth)
                && button.y_root >= originY && button.y_root < originY + Int32(panelHeight)
            let chosen = inside ? entry(atY: localY) : nil
            dismiss()
            if let chosen { chosen() }
            _ = panel
            return true
        case X11.keyPress:
            var key = orbEvent(event, as: XKeyEvent.self)
            let keysym = withUnsafeMutablePointer(to: &key) { XLookupKeysym($0, 0) }
            if keysym == X11.escapeKeySym {
                dismiss()
            } else if keysym == X11.returnKeySym, let chosen = action(atRowIndex: hover) {
                // Return takes the highlighted entry, the way a keyboard-driven menu does.
                dismiss()
                chosen()
            }
            return true
        default:
            return false
        }
    }

    /// The action for the entry under `y` (in panel coordinates), or nil for a separator, a disabled entry, or empty
    /// space. Disabled entries are visible but do nothing, the way a greyed-out menu item behaves.
    private func entry(atY y: Double) -> (() -> Void)? {
        var cursor = Metrics.paddingY
        for line in lines {
            let height = isSeparator(line) ? Metrics.separatorHeight : Metrics.rowHeight
            if y >= cursor && y < cursor + height {
                guard case .entry(let entry) = line, entry.enabled else { return nil }
                return entry.action
            }
            cursor += height
        }
        return nil
    }

    private func rowIndex(atY y: Double) -> Int {
        var cursor = Metrics.paddingY
        for (index, line) in lines.enumerated() {
            let height = isSeparator(line) ? Metrics.separatorHeight : Metrics.rowHeight
            if y >= cursor && y < cursor + height {
                if case .entry(let entry) = line, entry.enabled { return index }
                return -1
            }
            cursor += height
        }
        return -1
    }

    private func rowTop(of index: Int) -> Double? {
        guard index >= 0, index < lines.count else { return nil }
        var cursor = Metrics.paddingY
        for (position, line) in lines.enumerated() {
            if position == index { return cursor }
            cursor += isSeparator(line) ? Metrics.separatorHeight : Metrics.rowHeight
        }
        return nil
    }

    private func action(atRowIndex index: Int) -> (() -> Void)? {
        guard index >= 0, index < lines.count, case .entry(let entry) = lines[index], entry.enabled else {
            return nil
        }
        return entry.action
    }

    private func isSeparator(_ line: Line) -> Bool {
        if case .separator = line { return true }
        return false
    }

    private func panel() -> OrbX11Window? {
        if let window { return window }
        window = OrbX11Window(x: x, name: "herdr-voice orb menu", width: 200, height: 100,
                              events: X11.exposureMask | X11.buttonPressMask | X11.buttonReleaseMask
                                  | X11.pointerMotionMask | X11.keyPressMask | X11.structureNotifyMask,
                              alpha: x.hasAlpha && x.hasCompositor)
        return window
    }
}
