#if os(Linux)
import CGtk4
import Foundation
import VestalCore

// MARK: - Clock faces
//
// The drawing of `analog` and `flip` nodes and the marks of a `ring`, from
// the numbers in VestalCore's ClockFaces.swift (angles, geometry, the tiles
// that change), line for line the macOS UI's (VestalMac/Render/RenderClockFaces.swift).
// Everything is drawn with cairo, text with Pango through cairo.
//
// Nothing runs while the dashboard is hidden: the sweeping hand and a fold
// use the widget's frame clock (it stops with the window), and the stepping
// hand's timer exists only between the widget's `map` and `unmap`.

/// What a clock face keeps: its animation sources, and a fold in progress.
final class FaceState {
    var tick: guint = 0
    var timer: guint = 0
    /// A fold: when it started (monotonic microseconds) and the characters the
    /// changed tiles showed before.
    var foldStart: gint64 = 0
    var before: [Int: String] = [:]

    func stop(_ widget: WidgetPtr?) {
        if tick != 0, let widget { gtk_widget_remove_tick_callback(widget, tick) }
        tick = 0
        if timer != 0 { g_source_remove(timer) }
        timer = 0
    }
}

extension NodeView {
    // MARK: Starting

    /// An analog face redraws itself: every frame for a sweeping hand, every
    /// second (or five) otherwise, only while mapped.
    func startAnalog(_ analog: RenderNode.Analog) {
        let state = FaceState()
        faceState = state
        let mode = LinuxDashboard.reducedMotion && analog.seconds == "sweep" ? "step" : analog.seconds
        guard RenderClock.override == nil else { return }
        onWidgetSignal(widget, "map") { [weak self, weak state] in
            guard let self, let state else { return }
            state.stop(self.widget)
            if mode == "sweep" {
                let tick: GtkTickCallback = { widget, _, _ in
                    gtk_widget_queue_draw(widget)
                    return 1 // G_SOURCE_CONTINUE
                }
                state.tick = gtk_widget_add_tick_callback(self.widget, tick, nil, nil)
            } else {
                let seconds: guint = mode == "step" ? 1 : 5
                let widget = self.widget
                let body: () -> Void = { if let widget { gtk_widget_queue_draw(widget) } }
                let thunk: GSourceFunc = { data in
                    Box<() -> Void>.from(data)()
                    return 1
                }
                state.timer = g_timeout_add_seconds_full(G_PRIORITY_DEFAULT, seconds, thunk, Box(body).retained(), releaseBox)
            }
        }
        onWidgetSignal(widget, "unmap") { [weak self, weak state] in
            guard let self, let state else { return }
            state.stop(self.widget)
        }
    }

    /// A flip face folds the tiles that changed since the node of the same id
    /// was last built (the context remembers them: a patch builds a new view).
    func startFlip(_ flip: RenderNode.Flip) {
        let state = FaceState()
        faceState = state
        let characters = FlipLayout.characters(flip.layout)
        let previous = context.flipMemory[node.id]
        context.flipMemory[node.id] = characters
        guard let previous, flip.animate, !LinuxDashboard.reducedMotion else { return }
        let changed = FlipLayout.changedTiles(old: previous, new: characters)
        guard !changed.isEmpty else { return }
        for index in changed { state.before[index] = previous[index] }
        state.foldStart = g_get_monotonic_time()
        // The frame clock runs only while the widget is mapped; a fold begun
        // hidden is simply over when it is shown.
        let tick: GtkTickCallback = { widget, _, data in
            let state = Unmanaged<FaceState>.fromOpaque(data!).takeUnretainedValue()
            gtk_widget_queue_draw(widget)
            let elapsed = Double(g_get_monotonic_time() - state.foldStart) / 1000
            if elapsed >= FlipTiming.halfMilliseconds * 2 {
                state.before = [:]
                state.tick = 0
                return 0 // removed; the destroy notify releases `state`
            }
            return 1
        }
        state.tick = gtk_widget_add_tick_callback(widget, tick, Unmanaged.passRetained(state).toOpaque(), releaseBox)
    }

    // MARK: Analog

    // MARK: Matrix

    func drawMatrix(_ snapshot: OpaquePointer, _ matrix: RenderNode.Matrix, _ box: Rect) {
        guard box.width > 0, box.height > 0 else { return }
        let theme = context.theme
        let layout = matrix.layout
        let lit = theme.color(matrix.color)
        let off = matrix.offColor.map { theme.color($0) } ?? RGBA(r: 1, g: 1, b: 1, a: 0.065)
        var rect = box.graphene
        let cr = gtk_snapshot_append_cairo(snapshot, &rect)
        defer { cairo_destroy(cr) }
        cairo_translate(cr, box.x + (box.width - layout.width) / 2, box.y + (box.height - layout.height) / 2)
        for cell in layout.cells {
            switch cell.kind {
            case .dot:
                cairo_arc(cr, cell.x, cell.y, cell.radius, 0, 2 * .pi)
            case .rect:
                roundedPath(cr, Rect(x: cell.x, y: cell.y, width: cell.width, height: cell.height), radius: cell.radius)
            case .polygon:
                var i = 0
                while i + 1 < cell.points.count {
                    if i == 0 { cairo_move_to(cr, cell.points[i], cell.points[i + 1]) } else { cairo_line_to(cr, cell.points[i], cell.points[i + 1]) }
                    i += 2
                }
                cairo_close_path(cr)
            }
            setSource(cr, cell.lit ? lit : off)
            cairo_fill(cr)
        }
    }

    // MARK: Moon

    func drawMoon(_ snapshot: OpaquePointer, _ moon: RenderNode.Moon, _ box: Rect) {
        let side = min(box.width, box.height)
        guard side > 0 else { return }
        let theme = context.theme
        var rect = box.graphene
        let cr = gtk_snapshot_append_cairo(snapshot, &rect)
        defer { cairo_destroy(cr) }
        let x = box.x + (box.width - side) / 2, y = box.y + (box.height - side) / 2
        let r = MoonGeometry.radius(size: side)
        cairo_arc(cr, x + side / 2, y + side / 2, r, 0, 2 * .pi)
        setSource(cr, moon.trackColor.map { theme.color($0) } ?? RGBA(r: 1, g: 1, b: 1, a: 0.08))
        cairo_fill(cr)
        let points = MoonGeometry.litOutline(phase: moon.phase, size: side)
        guard let first = points.first else { return }
        cairo_move_to(cr, x + first.x, y + first.y)
        for p in points.dropFirst() { cairo_line_to(cr, x + p.x, y + p.y) }
        cairo_close_path(cr)
        setSource(cr, theme.color(moon.color))
        cairo_fill(cr)
    }

    func drawAnalog(_ snapshot: OpaquePointer, _ analog: RenderNode.Analog, _ box: Rect) {
        guard box.width > 0, box.height > 0 else { return }
        let theme = context.theme
        let g = analog.geometry
        let mode = LinuxDashboard.reducedMotion && analog.seconds == "sweep" ? "step" : analog.seconds
        let time = AnalogMath.time(RenderClock.now(), zone: analog.zone)
        let angles = AnalogMath.angles(time, mode: mode)
        let quiet = analog.ticks == "none"
        var rect = box.graphene
        let cr = gtk_snapshot_append_cairo(snapshot, &rect)
        defer { cairo_destroy(cr) }
        cairo_translate(cr, box.x + (box.width - g.size) / 2, box.y + (box.height - g.size) / 2)
        let c = g.center
        func point(_ radius: Double, _ degrees: Double) -> (x: Double, y: Double) {
            AnalogMath.point(center: c, radius: radius, degrees: degrees)
        }
        let ink = theme.color(analog.color)

        cairo_arc(cr, c, c, g.faceRadius, 0, 2 * .pi)
        let dayFace = theme.color(analog.faceColor, default: "text@0.035")
        setSource(cr, AnalogMath.isDay(hour: time.hour) ? dayFace : (analog.nightFaceColor.map { theme.color($0) } ?? dayFace))
        cairo_fill_preserve(cr)
        setSource(cr, theme.color(analog.color + (quiet ? "@0.18" : "@0.2")))
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)

        if g.dotRadius > 0 {
            cairo_arc(cr, c, g.dotY, g.dotRadius, 0, 2 * .pi)
            setSource(cr, ink.withAlpha(0.75))
            cairo_fill(cr)
        }
        for mark in g.dotMarks {
            let p = point(g.tickDotOrbit, mark.degrees)
            cairo_arc(cr, p.x, p.y, mark.major ? g.tickDotMajorRadius : g.tickDotRadius, 0, 2 * .pi)
            setSource(cr, ink.withAlpha(0.6))
            cairo_fill(cr)
        }
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        for tick in g.ticks {
            let length = tick.major ? g.hourTickLength : g.minuteTickLength
            let a = point(g.tickOuter - length, tick.degrees), b = point(g.tickOuter, tick.degrees)
            cairo_move_to(cr, a.x, a.y)
            cairo_line_to(cr, b.x, b.y)
            setSource(cr, ink.withAlpha(tick.major ? 0.85 : 0.32))
            cairo_set_line_width(cr, tick.major ? g.hourTickWidth : g.minuteTickWidth)
            cairo_stroke(cr)
        }
        if g.numeralSize > 0 {
            for hour in 1...12 {
                let p = point(g.numeralRadius, Double(hour) * 30)
                faceText(cr, "\(hour)", role: "sans", size: g.numeralSize, weight: 300, color: ink, x: p.x, y: p.y)
            }
        }
        if let window = g.window {
            let frame = Rect(x: window.x, y: window.y, width: window.width, height: window.height)
            roundedPath(cr, frame, radius: 3)
            setSource(cr, RGBA(r: 0, g: 0, b: 0, a: 0.35))
            cairo_fill_preserve(cr)
            setSource(cr, ink.withAlpha(0.22))
            cairo_set_line_width(cr, 1)
            cairo_stroke(cr)
            faceText(cr, "\(time.day)", role: "mono", size: window.fontSize, weight: 500, color: ink,
                     x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        }
        func hand(_ hand: AnalogGeometry.Hand, _ degrees: Double, _ color: RGBA) {
            let a = point(-hand.tail, degrees), b = point(hand.length, degrees)
            cairo_move_to(cr, a.x, a.y)
            cairo_line_to(cr, b.x, b.y)
            setSource(cr, color)
            cairo_set_line_width(cr, hand.width)
            cairo_stroke(cr)
        }
        hand(g.hour, angles.hour, ink)
        hand(g.minute, angles.minute, ink)
        if let second = g.second {
            let color = theme.color(analog.secondsColor)
            hand(second, angles.second, color)
            let weight = point(-g.secondDotOffset, angles.second)
            cairo_arc(cr, weight.x, weight.y, g.secondDotRadius, 0, 2 * .pi)
            setSource(cr, color)
            cairo_fill(cr)
        }
        cairo_arc(cr, c, c, g.pivotRadius, 0, 2 * .pi)
        setSource(cr, theme.color(analog.pivotColor))
        cairo_fill(cr)
        if g.pivotHole > 0 {
            cairo_arc(cr, c, c, g.pivotHole, 0, 2 * .pi)
            setSource(cr, theme.color("bg"))
            cairo_fill(cr)
        }
    }

    // MARK: Flip

    func drawFlip(_ snapshot: OpaquePointer, _ flip: RenderNode.Flip, _ box: Rect) {
        guard box.width > 0, box.height > 0 else { return }
        let theme = context.theme
        let layout = flip.layout
        let scale = flip.size / 90
        let top = theme.color(flip.tile), bottom = theme.color(flip.tileBottom), ink = theme.color(flip.color)
        let squares = FlipLayout.colonSquares(height: layout.height, scale: scale)
        let state = faceState
        let elapsed: Double? = (state?.before.isEmpty ?? true) ? nil : Double(g_get_monotonic_time() - (state?.foldStart ?? 0)) / 1000
        var rect = box.graphene
        let cr = gtk_snapshot_append_cairo(snapshot, &rect)
        defer { cairo_destroy(cr) }
        cairo_translate(cr, box.x + (box.width - layout.width) / 2, box.y + (box.height - layout.height) / 2)
        for item in layout.items {
            switch item.kind {
            case .space:
                break
            case .colon:
                for y in squares.y {
                    roundedPath(cr, Rect(x: item.x + (item.width - squares.side) / 2, y: y, width: squares.side, height: squares.side),
                                radius: 2 * scale)
                    setSource(cr, ink.withAlpha(0.75))
                    cairo_fill(cr)
                }
            case .tile:
                let frame = Rect(x: item.x, y: item.y, width: item.width, height: item.height)
                let fontSize = item.big ? flip.size : flip.smallSize
                let radius = (item.big ? 8 : 5) * scale
                let old = elapsed == nil ? nil : state?.before[item.index]
                let angles = elapsed.flatMap { FlipTiming.angles(elapsed: $0) }
                // Under the flaps: the new top half, and the old bottom half
                // until the fold ends.
                drawHalf(cr, frame, radius, upper: true, character: item.character, size: fontSize, color: top, ink: ink, scale: 1)
                drawHalf(cr, frame, radius, upper: false, character: (angles != nil ? old : nil) ?? item.character,
                         size: fontSize, color: bottom, ink: ink, scale: 1)
                if let angles, let old {
                    if angles.top < 90 {
                        drawHalf(cr, frame, radius, upper: true, character: old, size: fontSize, color: top, ink: ink,
                                 scale: cos(angles.top * .pi / 180))
                    } else {
                        drawHalf(cr, frame, radius, upper: false, character: item.character, size: fontSize, color: bottom, ink: ink,
                                 scale: cos(angles.bottom * .pi / 180))
                    }
                }
                // The seam and the notches at its ends.
                setSource(cr, RGBA(r: 0, g: 0, b: 0, a: 0.6))
                cairo_rectangle(cr, frame.x, frame.y + frame.height / 2 - 0.5, frame.width, 1)
                cairo_fill(cr)
                let notchWidth = (item.big ? 3.0 : 2.0) * scale, notchHeight = (item.big ? 8.0 : 5.0) * scale
                for x in [frame.x, frame.x + frame.width - notchWidth] {
                    roundedPath(cr, Rect(x: x, y: frame.y + frame.height / 2 - notchHeight / 2, width: notchWidth, height: notchHeight), radius: 1)
                    setSource(cr, RGBA(r: 0, g: 0, b: 0, a: 0.55))
                    cairo_fill(cr)
                }
            }
        }
    }

    /// One half of a tile showing `character`, squashed towards the seam by
    /// `scale` (1: flat on, 0: edge on).
    private func drawHalf(_ cr: OpaquePointer?, _ frame: Rect, _ radius: Double, upper: Bool, character: String, size: Double,
                          color: RGBA, ink: RGBA, scale: Double) {
        guard scale > 0.001 else { return }
        let seam = frame.y + frame.height / 2
        cairo_save(cr)
        cairo_translate(cr, 0, seam)
        cairo_scale(cr, 1, scale)
        cairo_translate(cr, 0, -seam)
        if upper {
            cairo_rectangle(cr, frame.x, frame.y, frame.width, frame.height / 2)
        } else {
            cairo_rectangle(cr, frame.x, seam, frame.width, frame.height / 2)
        }
        cairo_clip(cr)
        roundedPath(cr, frame, radius: radius)
        setSource(cr, color)
        cairo_fill(cr)
        faceText(cr, character, role: "sans", size: size, weight: 600, color: ink, x: frame.x + frame.width / 2, y: seam)
        cairo_restore(cr)
    }

    // MARK: Ring marks

    /// The marks, labels and end dot of a ring, over its arc.
    func drawRingMarks(_ cr: OpaquePointer?, _ ring: RenderNode.Ring, _ g: RingGeometry, cx: Double, cy: Double) {
        let theme = context.theme
        let ink = theme.color("text")
        if ring.ticks > 0 {
            cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
            for index in 0..<ring.ticks {
                let major = g.isMajor(index)
                let radii = g.tickRadii(major: major)
                let angle = g.angle(at: g.tickFraction(index))
                let a = RingGeometry.offset(radius: radii.inner, angle: angle), b = RingGeometry.offset(radius: radii.outer, angle: angle)
                cairo_move_to(cr, cx + a.x, cy + a.y)
                cairo_line_to(cr, cx + b.x, cy + b.y)
                setSource(cr, ink.withAlpha(major ? 0.5 : 0.2))
                cairo_set_line_width(cr, major ? 1.5 : 1)
                cairo_stroke(cr)
            }
        }
        for (index, label) in ring.labels.enumerated() where !label.isEmpty {
            let p = RingGeometry.offset(radius: g.labelRadius, angle: g.angle(at: g.labelFraction(index, of: ring.labels.count)))
            faceText(cr, label, role: "mono", size: 10, weight: 400, color: theme.color("dim"), x: cx + p.x, y: cy + p.y)
        }
        if ring.dot {
            let p = RingGeometry.offset(radius: g.radius, angle: g.angle(at: min(max(ring.value, 0), 1)))
            cairo_arc(cr, cx + p.x, cy + p.y, max(ring.thickness, 2) * 1.1, 0, 2 * .pi)
            setSource(cr, theme.color(ring.dotColor, default: "text"))
            cairo_fill(cr)
        }
    }

    // MARK: Helpers

    /// `text` centered on (x, y), in a font role, through Pango on cairo.
    private func faceText(_ cr: OpaquePointer?, _ text: String, role: String, size: Double, weight: Int, color: RGBA, x: Double, y: Double) {
        guard let layout = pango_cairo_create_layout(cr) else { return }
        let desc = pango_font_description_new()
        pango_font_description_set_family(desc, context.theme.family(role: role))
        pango_font_description_set_absolute_size(desc, size * Double(PANGO_SCALE))
        pango_font_description_set_weight(desc, PangoWeight(rawValue: .init(clamping: context.theme.weight(weight))))
        pango_layout_set_font_description(layout, desc)
        pango_font_description_free(desc)
        pango_layout_set_text(layout, text, -1)
        var width: Int32 = 0, height: Int32 = 0
        pango_layout_get_pixel_size(layout, &width, &height)
        cairo_move_to(cr, x - Double(width) / 2, y - Double(height) / 2)
        setSource(cr, color)
        pango_cairo_show_layout(cr, layout)
        g_object_unref(UnsafeMutableRawPointer(layout))
    }

    /// A rounded rectangle as the current path.
    private func roundedPath(_ cr: OpaquePointer?, _ r: Rect, radius: Double) {
        let rad = max(0, min(radius, r.width / 2, r.height / 2))
        cairo_new_sub_path(cr)
        cairo_arc(cr, r.x + r.width - rad, r.y + rad, rad, -.pi / 2, 0)
        cairo_arc(cr, r.x + r.width - rad, r.y + r.height - rad, rad, 0, .pi / 2)
        cairo_arc(cr, r.x + rad, r.y + r.height - rad, rad, .pi / 2, .pi)
        cairo_arc(cr, r.x + rad, r.y + rad, rad, .pi, 3 * .pi / 2)
        cairo_close_path(cr)
    }
}
#endif
