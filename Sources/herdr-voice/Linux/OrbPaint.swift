import CCairo
import Foundation
import HerdrVoiceCore

/// A colour the orb paints with: straight (not premultiplied) components, which is what Cairo and Core Animation
/// both take at the call site.
struct OrbColor {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    static let white = OrbColor(r: 1, g: 1, b: 1)
    static let black = OrbColor(r: 0, g: 0, b: 0)

    func withAlpha(_ alpha: Double) -> OrbColor { OrbColor(r: r, g: g, b: b, a: alpha) }

    /// Blends toward black, the way `NSColor.blended(withFraction:of: .black)` does — the base sphere in the macOS
    /// orb is the mood's second colour at 35% and 75% black.
    func darkened(_ fraction: Double) -> OrbColor {
        OrbColor(r: r * (1 - fraction), g: g * (1 - fraction), b: b * (1 - fraction), a: a)
    }

    /// Blends toward white, for the core's highlight colour.
    func lightened(_ fraction: Double) -> OrbColor {
        OrbColor(r: r + (1 - r) * fraction, g: g + (1 - g) * fraction, b: b + (1 - b) * fraction, a: a)
    }

    /// Straight linear interpolation, for cross-fading one mood's palette into the next.
    func mixed(_ other: OrbColor, _ t: Double) -> OrbColor {
        let k = min(max(t, 0), 1)
        return OrbColor(r: r + (other.r - r) * k, g: g + (other.g - g) * k, b: b + (other.b - b) * k,
                        a: a + (other.a - a) * k)
    }

    func premultipliedAlpha() -> Double { a }
}

extension Mood {
    /// The five moods' palettes, in the same order and for the same jobs as the macOS orb: the first colour is the
    /// accent (glow, blobs, core), the second the sphere's base, the third the second blob.
    ///
    /// The values are the Apple system colours the macOS version names, by their published sRGB values, so the two
    /// platforms look like the same orb rather than two interpretations of it.
    var orbPalette: [OrbColor] {
        switch self {
        case .muted:
            [OrbColor(r: 0.557, g: 0.557, b: 0.576), // systemGray
             OrbColor(r: 0.333, g: 0.333, b: 0.333), // darkGray
             OrbColor(r: 0.667, g: 0.667, b: 0.667)] // lightGray
        case .listening:
            [OrbColor(r: 0.188, g: 0.690, b: 0.780), // systemTeal
             OrbColor(r: 0.039, g: 0.518, b: 1.000), // systemBlue
             OrbColor(r: 0.196, g: 0.678, b: 0.902)] // systemCyan
        case .speaking:
            [OrbColor(r: 1.000, g: 0.176, b: 0.333), // systemPink
             OrbColor(r: 0.686, g: 0.322, b: 0.871), // systemPurple
             OrbColor(r: 0.345, g: 0.337, b: 0.839)] // systemIndigo
        case .working:
            [OrbColor(r: 1.000, g: 0.839, b: 0.039), // systemYellow
             OrbColor(r: 1.000, g: 0.584, b: 0.000), // systemOrange
             OrbColor(r: 1.000, g: 0.231, b: 0.188)] // systemRed
        case .offline:
            [OrbColor(r: 1.000, g: 0.231, b: 0.188), // systemRed
             OrbColor.black,
             OrbColor(r: 1.000, g: 0.176, b: 0.333)] // systemPink
        }
    }

    /// How lively the blob paths are with no voice at all.
    var orbIdleSpeed: Double {
        switch self {
        case .muted, .offline: 0.15
        case .listening: 0.45
        case .speaking: 0.6
        case .working: 0.9
        }
    }

    var orbDimmed: Bool { self == .muted }
}

/// What one frame of the orb looks like: the inputs the drawing code needs, after the smoothing the macOS layers do
/// with Core Animation's implicit animations.
struct OrbLook {
    var palette: [OrbColor]
    var mic: Double
    var voice: Double
    var time: Double
    /// 0...1: how far the thinking bubble has popped in.
    var bubble: Double
    var mutedGlow = false
}

/// The orb's animation state: the same maths as the macOS version's layer properties, stepped once per frame.
///
/// Kept apart from the window so it can be reasoned about (and dumped to a PNG) without a display. The numbers are
/// the macOS ones restated in terms of a 96 pt canvas, so the two platforms animate alike down to the blob paths.
struct OrbAnimation {
    /// Per-blob motion: two incommensurate frequencies per axis, so paths never visibly repeat.
    private struct Path {
        let fx: (Double, Double)
        let fy: (Double, Double)
        let phase: Double
        let colorIndex: Int
    }

    private static let paths: [Path] = [
        Path(fx: (0.71, 0.23), fy: (0.53, 0.37), phase: 0.0, colorIndex: 0),
        Path(fx: (0.47, 0.31), fy: (0.83, 0.19), phase: 2.1, colorIndex: 1),
        Path(fx: (0.61, 0.17), fy: (0.41, 0.29), phase: 4.2, colorIndex: 2),
        Path(fx: (0.89, 0.13), fy: (0.67, 0.43), phase: 1.3, colorIndex: 0),
    ]

    static var blobPaths: [(fx: (Double, Double), fy: (Double, Double), phase: Double, colorIndex: Int)] {
        paths.map { ($0.fx, $0.fy, $0.phase, $0.colorIndex) }
    }

    private var time = 0.0
    private var micEnergy = 0.0
    private var voiceEnergy = 0.0
    private var bubble = 0.0
    private var palette: [OrbColor] = Mood.listening.orbPalette
    private var mood: Mood = .listening
    /// 30 fps is plenty for drifting; full rate while someone is talking or something is working.
    private(set) var idle = false

    /// One frame's inputs, straight from the app: the mood, raw 0...1 loudness of mic and playback, whether
    /// anything is working.
    mutating func step(dt: Double, mood newMood: Mood, mic: Float, voice: Float, thinking: Bool) {
        if newMood != mood {
            mood = newMood
        }
        let clamped = min(max(dt, 0), 0.1)
        micEnergy = OrbAnimation.smooth(micEnergy, toward: mic)
        voiceEnergy = OrbAnimation.smooth(voiceEnergy, toward: voice)
        let energy = max(micEnergy, voiceEnergy)
        time += clamped * (mood.orbIdleSpeed + micEnergy * 2.2 + voiceEnergy * 1.4)

        // Cross-fade to the new mood's palette over roughly the 0.6 s the macOS version asks Core Animation for.
        let target = mood.orbPalette
        let fade = 1 - exp(-clamped / 0.16)
        palette = palette.enumerated().map { index, colour in
            guard index < target.count else { return colour }
            return colour.mixed(target[index], fade)
        }

        // The bubble pops in faster than it fades out, like the two animation durations on macOS.
        let wanted = (thinking && mood != .offline) ? 1.0 : 0.0
        let tau = wanted > bubble ? 0.055 : 0.11
        bubble += (wanted - bubble) * (1 - exp(-clamped / tau))

        idle = mic < 0.01 && voice < 0.001 && !thinking
        _ = energy
    }

    /// Fourth root lifts quiet speech; fast attack / slow release feels like breath, not flicker. Identical to the
    /// macOS version so both orbs react the same way to the same level.
    private static func smooth(_ current: Double, toward level: Float) -> Double {
        let target = pow(min(max(Double(level) * 6, 0), 1), 0.25)
        return current + (target - current) * (target > current ? 0.35 : 0.05)
    }

    var look: OrbLook {
        OrbLook(palette: palette, mic: micEnergy, voice: voiceEnergy, time: time, bubble: bubble,
                mutedGlow: mood.orbDimmed)
    }

    /// The animation clock, in the mood's own speed: what the demo's envelopes advance against.
    var elapsed: Double { time }
}

/// A thin, readable façade over the Cairo calls the orb makes. Cairo's C API is fine for one drawing; this keeps
/// the drawing code about the picture instead of about pointer arguments.
struct Canvas {
    let cr: OpaquePointer

    func save() { cairo_save(cr) }
    func restore() { cairo_restore(cr) }
    func translate(_ x: Double, _ y: Double) { cairo_translate(cr, x, y) }
    func scale(_ x: Double, _ y: Double) { cairo_scale(cr, x, y) }
    func rotate(_ radians: Double) { cairo_rotate(cr, radians) }
    func clip() { cairo_clip(cr) }
    func setOperator(_ op: cairo_operator_t) { cairo_set_operator(cr, op) }
    func setColor(_ color: OrbColor) {
        cairo_set_source_rgba(cr, color.r, color.g, color.b, color.a)
    }

    /// Empties the surface to fully transparent, whatever was there before.
    func clear() {
        save()
        setOperator(CAIRO_OPERATOR_CLEAR)
        cairo_paint(cr)
        restore()
    }

    func circle(cx: Double, cy: Double, radius: Double) {
        cairo_new_sub_path(cr)
        cairo_arc(cr, cx, cy, radius, 0, 2 * Double.pi)
        cairo_close_path(cr)
    }

    func roundedRect(x: Double, y: Double, width: Double, height: Double, radius: Double) {
        let r = min(radius, min(width, height) / 2)
        cairo_new_sub_path(cr)
        cairo_arc(cr, x + width - r, y + r, r, -Double.pi / 2, 0)
        cairo_arc(cr, x + width - r, y + height - r, r, 0, Double.pi / 2)
        cairo_arc(cr, x + r, y + height - r, r, Double.pi / 2, Double.pi)
        cairo_arc(cr, x + r, y + r, r, Double.pi, 3 * Double.pi / 2)
        cairo_close_path(cr)
    }

    func rectangle(x: Double, y: Double, width: Double, height: Double) {
        cairo_rectangle(cr, x, y, width, height)
    }

    /// A radial gradient from `inner` at the centre to `outer` at `radius`, in the current user space.
    func radial(cx: Double, cy: Double, radius: Double, from inner: OrbColor, to outer: OrbColor) {
        guard let pattern = cairo_pattern_create_radial(cx, cy, 0, cx, cy, max(radius, 0.001)) else { return }
        cairo_pattern_add_color_stop_rgba(pattern, 0, inner.r, inner.g, inner.b, inner.a)
        cairo_pattern_add_color_stop_rgba(pattern, 1, outer.r, outer.g, outer.b, outer.a)
        cairo_set_source(cr, pattern)
        cairo_pattern_destroy(pattern)
    }

    /// A vertical gradient, used for the opaque fallback's tile.
    func linearVertical(y0: Double, y1: Double, from top: OrbColor, to bottom: OrbColor) {
        guard let pattern = cairo_pattern_create_linear(0, y0, 0, y1) else { return }
        cairo_pattern_add_color_stop_rgba(pattern, 0, top.r, top.g, top.b, top.a)
        cairo_pattern_add_color_stop_rgba(pattern, 1, bottom.r, bottom.g, bottom.b, bottom.a)
        cairo_set_source(cr, pattern)
        cairo_pattern_destroy(pattern)
    }

    func paint(alpha: Double = 1) {
        if alpha >= 0.999 { cairo_paint(cr) } else { cairo_paint_with_alpha(cr, min(max(alpha, 0), 1)) }
    }

    func fill() { cairo_fill(cr) }

    func fillAndStroke(fill fillColor: OrbColor, stroke strokeColor: OrbColor, width: Double) {
        setColor(fillColor)
        cairo_fill_preserve(cr)
        setColor(strokeColor)
        cairo_set_line_width(cr, width)
        cairo_stroke(cr)
    }
}

/// The orb's picture, drawn with Cairo.
///
/// The layout is the macOS layer tree measured out again on a Cairo canvas: a soft radial glow, a rounded sphere that
/// breathes with the voice, four colour blobs drifting on out-of-phase paths and composited with Cairo's SCREEN
/// operator (the same maths as Core Animation's `screenBlendMode`), a pulsing core that follows the assistant's
/// voice, a specular highlight so it reads as a sphere rather than a disc, and the thinking bubble.
///
/// Core Animation's origin is bottom-left and Cairo's is top-left, so the whole picture is drawn under a single
/// vertical flip: every coordinate below is the macOS one.
enum OrbPaint {
    static let size: Double = 96

    static func draw(_ context: OpaquePointer, size s: Double, look: OrbLook, opaqueBackdrop: Bool) {
        let canvas = Canvas(cr: context)
        canvas.clear()
        canvas.save()
        canvas.translate(0, s)
        canvas.scale(1, -1)

        if opaqueBackdrop { backdrop(canvas, size: s, look: look) }

        glow(canvas, size: s, look: look)
        sphere(canvas, size: s, look: look)
        bubble(canvas, size: s, look: look)

        canvas.restore()
    }

    /// Without a compositor an ARGB window's alpha is not blended, so the orb draws an opaque tile and its own soft
    /// shadow instead of pretending to float. The sphere still sits in the same place on the same canvas.
    private static func backdrop(_ canvas: Canvas, size s: Double, look: OrbLook) {
        let corner = s * 0.15
        canvas.roundedRect(x: 0, y: 0, width: s, height: s, radius: corner)
        canvas.linearVertical(y0: s, y1: 0,
                              from: OrbColor(r: 0.078, g: 0.086, b: 0.102),
                              to: OrbColor(r: 0.043, g: 0.047, b: 0.059))
        canvas.fill()
        // A soft dark ring under the sphere: the shadow the macOS panel gets from the window server.
        let inset = s * 0.18
        let d = s - inset * 2
        canvas.radial(cx: s / 2, cy: s / 2, radius: d * 0.5 + s * 0.2,
                      from: OrbColor(r: 0, g: 0, b: 0, a: 0.55), to: OrbColor(r: 0, g: 0, b: 0, a: 0))
        canvas.paint()
        _ = look
    }

    private static func glow(_ canvas: Canvas, size s: Double, look: OrbLook) {
        let energy = max(look.mic, look.voice)
        let breathe = 0.03 * sin(look.time * 1.1)
        let glowScale = 0.72 + look.mic * 0.3 + look.voice * 0.18 + breathe
        let alpha = look.mutedGlow ? 0.25 : 0.6 + energy * 0.4
        let p = look.palette
        canvas.save()
        canvas.translate(s / 2, s / 2)
        canvas.scale(glowScale, glowScale)
        canvas.translate(-s / 2, -s / 2)
        canvas.radial(cx: s / 2, cy: s / 2, radius: s / 2,
                      from: p[0].withAlpha(0.5), to: p[1].withAlpha(0))
        canvas.paint(alpha: alpha)
        canvas.restore()
    }

    private static func sphere(_ canvas: Canvas, size s: Double, look: OrbLook) {
        let inset = s * 0.18
        let d = s - inset * 2
        let energy = max(look.mic, look.voice)
        let time = look.time
        let p = look.palette
        let breathe = 0.03 * sin(time * 1.1)
        let sphereScale = 1 + breathe + energy * 0.12

        canvas.save()
        canvas.translate(s / 2, s / 2)
        canvas.scale(sphereScale, sphereScale)
        canvas.translate(-s / 2, -s / 2)

        // The sphere is a circle of diameter d, and everything inside it is clipped to it (macOS: cornerRadius d/2
        // plus masksToBounds).
        canvas.circle(cx: s / 2, cy: s / 2, radius: d / 2)
        canvas.clip()

        canvas.radial(cx: s / 2, cy: s / 2, radius: d / 2 * 1.41421356,
                      from: p[1].darkened(0.35), to: p[1].darkened(0.75))
        canvas.paint()

        blobs(canvas, size: s, look: look)

        // The assistant's voice glows from the core, fluttering slightly so it reads as speech rather than a lamp.
        let flutter = 1 + 0.06 * sin(time * 7)
        let coreScale = (0.55 + look.voice * 0.75) * flutter
        let coreAlpha = min(look.voice * 1.1, 0.95)
        if coreAlpha > 0.001 {
            canvas.save()
            canvas.translate(s / 2, s / 2)
            canvas.scale(coreScale, coreScale)
            canvas.radial(cx: 0, cy: 0, radius: d * 0.3,
                          from: p[0].lightened(0.7), to: p[0].withAlpha(0))
            canvas.setOperator(CAIRO_OPERATOR_SCREEN)
            canvas.paint(alpha: coreAlpha)
            canvas.restore()
        }

        // Soft specular spot so it reads as a sphere, not a flat disc: upper-left, as on macOS.
        let hw = d * 0.45, hh = d * 0.4
        canvas.save()
        canvas.translate(inset + d * 0.12 + hw / 2, inset + d * 0.5 + hh / 2)
        canvas.scale(hw / 2, hh / 2)
        canvas.radial(cx: 0, cy: 0, radius: 1,
                      from: OrbColor.white.withAlpha(0.45), to: OrbColor.white.withAlpha(0))
        canvas.paint()
        canvas.restore()

        canvas.restore()
    }

    private static func blobs(_ canvas: Canvas, size s: Double, look: OrbLook) {
        let inset = s * 0.18
        let d = s - inset * 2
        let energy = max(look.mic, look.voice)
        let blobSize = d * 0.75
        // The developer's voice pushes the blobs toward the rim; the assistant's pulls them in around the core.
        let reach = d * (0.2 + look.mic * 0.16 - look.voice * 0.06)
        let centre = s / 2
        for (index, path) in OrbAnimation.blobPaths.enumerated() {
            let t = look.time + path.phase
            let x = sin(t * path.fx.0) + 0.5 * sin(t * path.fx.1 + 1.7)
            let y = cos(t * path.fy.0) + 0.5 * cos(t * path.fy.1 + 0.9)
            let wobble = 0.08 * sin(t * 1.3 + Double(index))
            let scale = 0.85 + energy * 0.3 + wobble
            let colour = look.palette[path.colorIndex]
            canvas.save()
            canvas.translate(centre + x * reach / 1.5, centre + y * reach / 1.5)
            // Uneven x/y scale plus slow rotation makes each blob stretch like liquid.
            canvas.rotate(t * 0.4 + Double(index))
            canvas.scale(scale * (1 + 0.12 * sin(t * 0.9)), scale * (1 - 0.12 * sin(t * 0.9)))
            // The falloff reaches zero at the blob's own width, so no straight edge of the layer shows through:
            // the blobs read as soft spots, as they do in docs/orb-states.png.
            canvas.radial(cx: 0, cy: 0, radius: blobSize / 2,
                          from: colour.withAlpha(0.7), to: colour.withAlpha(0))
            canvas.setOperator(CAIRO_OPERATOR_SCREEN)
            canvas.rectangle(x: -blobSize / 2, y: -blobSize / 2, width: blobSize, height: blobSize)
            canvas.fill()
            canvas.restore()
        }
    }

    /// The thinking bubble: about a fifth of the orb, overlapping the sphere's lower-right edge, with a small tail
    /// circle toward it and three dots pulsing in turn.
    private static func bubble(_ canvas: Canvas, size s: Double, look: OrbLook) {
        guard look.bubble > 0.004 else { return }
        let inset = s * 0.18
        let w = s / 5
        let h = w * 0.66
        let fade = look.bubble
        let right = s - inset
        let x = right - w * 0.45
        let y = inset - h * 0.55
        let pop = 0.6 + 0.4 * fade

        canvas.save()
        // Pop about its own centre, like the layer's scale transform.
        canvas.translate(x + w / 2, y + (h + 5) / 2)
        canvas.scale(pop, pop)
        canvas.translate(-(x + w / 2), -(y + (h + 5) / 2))

        let fill = OrbColor(r: 0.1, g: 0.1, b: 0.1, a: 0.82 * fade)
        let edge = OrbColor.white.withAlpha(0.35 * fade)
        // Tail first: the body is drawn over it and hides the seam, as the layer order does on macOS.
        canvas.circle(cx: x + w * 0.12 + 2, cy: y + h + 0.5 + 2, radius: 2)
        canvas.fillAndStroke(fill: fill, stroke: edge, width: 0.5)
        canvas.roundedRect(x: x, y: y, width: w, height: h, radius: h / 2)
        canvas.fillAndStroke(fill: fill, stroke: edge, width: 0.5)

        let dot = h * 0.26
        let gap = dot * 0.75
        let startX = x + (w - (dot * 3 + gap * 2)) / 2
        for index in 0..<3 {
            // CAKeyframeAnimation at 1.1 s with a 0.18 s stagger: opacity 0.3 → 1 → 0.3 and a small bob upward.
            let u = fractional((look.time - Double(index) * 0.18) / 1.1)
            let tri = 1 - abs(2 * u - 1)
            canvas.circle(cx: startX + Double(index) * (dot + gap) + dot / 2,
                          cy: y + (h - dot) / 2 + dot / 2 + dot * 0.45 * tri, radius: dot / 2)
            canvas.setColor(OrbColor.white.withAlpha((0.3 + 0.7 * tri) * fade))
            canvas.fill()
        }
        canvas.restore()
    }

    private static func fractional(_ value: Double) -> Double {
        let f = value - floor(value)
        return f < 0 ? f + 1 : f
    }
}
