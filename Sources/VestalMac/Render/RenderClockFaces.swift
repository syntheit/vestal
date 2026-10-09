#if os(macOS)
import AppKit
import SwiftUI
import VestalCore

// MARK: - Clock faces
//
// The drawing of `analog` and `flip` nodes, after VestalLinux/NodeClockFaces.swift
// and web/renderer/clock.js, from the numbers in VestalCore's ClockFaces.swift
// (angles, geometry, the tiles that change). The hands and the fold animate
// here, and only while the dashboard is shown: `RenderPulse` says so, and a
// hidden dashboard draws a still face with no timeline running at all. A
// sweeping hand turns in Core Animation (`AnalogHands`); a fold draws on
// the display's frames while it lasts.

/// Whether the dashboard is on screen, for drawings that animate themselves.
@MainActor
final class RenderPulse: ObservableObject {
    static let shared = RenderPulse()
    @Published var running = false
}

// MARK: - Analog

struct AnalogDrawing: View {
    let analog: RenderNode.Analog
    let style: RenderStyle

    @ObservedObject private var pulse = RenderPulse.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let mode = reduceMotion && analog.seconds == "sweep" ? "step" : analog.seconds
        if !pulse.running || RenderClock.override != nil {
            face(at: RenderClock.now(), mode: mode)
        } else if mode == "sweep" {
            // The face changes with the minute at most (day and night, the
            // date); the hands turn in Core Animation, so no frame of the
            // sweep is drawn here.
            TimelineView(.everyMinute) { context in face(at: context.date, mode: mode, hands: false) }
                .overlay(AnalogHands(analog: analog, style: style).allowsHitTesting(false))
        } else {
            // A second hand steps once a second; without one, the minute
            // hand needs no more than a look every few seconds.
            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: mode == "step" ? 1 : 5)) { context in
                face(at: context.date, mode: mode)
            }
        }
    }

    /// The face at `date`; without `hands`, only what lies under them.
    private func face(at date: Date, mode: String, hands: Bool = true) -> some View {
        let geometry = analog.geometry
        let time = AnalogMath.time(date, zone: analog.zone)
        let angles = AnalogMath.angles(time, mode: mode)
        let ink = style.color(analog.color)
        let dayFace = style.color(analog.faceColor, default: "text@0.035")
        let faceColor = AnalogMath.isDay(hour: time.hour) ? dayFace : (analog.nightFaceColor.map { style.color($0) } ?? dayFace)
        let secondsColor = style.color(analog.secondsColor)
        let pivotColor = style.color(analog.pivotColor)
        let hole = style.color("bg")
        let quiet = analog.ticks == "none"
        return Canvas { context, size in
            var context = context
            let g = geometry
            context.translateBy(x: (size.width - g.size) / 2, y: (size.height - g.size) / 2)
            let c = g.center
            func point(_ radius: Double, _ degrees: Double) -> CGPoint {
                let p = AnalogMath.point(center: c, radius: radius, degrees: degrees)
                return CGPoint(x: p.x, y: p.y)
            }
            let circle = Path(ellipseIn: CGRect(x: c - g.faceRadius, y: c - g.faceRadius, width: g.faceRadius * 2, height: g.faceRadius * 2))
            context.fill(circle, with: .color(faceColor))
            context.stroke(circle, with: .color(style.color(analog.color + "@" + (quiet ? "0.18" : "0.2"))), lineWidth: 1)
            if g.dotRadius > 0 {
                context.fill(Path(ellipseIn: CGRect(x: c - g.dotRadius, y: g.dotY - g.dotRadius, width: g.dotRadius * 2, height: g.dotRadius * 2)),
                             with: .color(style.color(analog.color + "@0.75")))
            }
            for mark in g.dotMarks {
                let p = point(g.tickDotOrbit, mark.degrees)
                let r = mark.major ? g.tickDotMajorRadius : g.tickDotRadius
                context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                             with: .color(style.color(analog.color + "@0.6")))
            }
            for tick in g.ticks {
                let length = tick.major ? g.hourTickLength : g.minuteTickLength
                var path = Path()
                path.move(to: point(g.tickOuter - length, tick.degrees))
                path.addLine(to: point(g.tickOuter, tick.degrees))
                context.stroke(path, with: .color(style.color(analog.color + (tick.major ? "@0.85" : "@0.32"))),
                               style: StrokeStyle(lineWidth: tick.major ? g.hourTickWidth : g.minuteTickWidth, lineCap: .round))
            }
            if g.numeralSize > 0 {
                for hour in 1...12 {
                    let text = context.resolve(Text("\(hour)").font(style.font(role: "sans", size: g.numeralSize, weight: 300))
                        .foregroundStyle(ink))
                    context.draw(text, at: point(g.numeralRadius, Double(hour) * 30), anchor: .center)
                }
            }
            if let window = g.window {
                let rect = CGRect(x: window.x, y: window.y, width: window.width, height: window.height)
                let box = RoundedRectangle(cornerRadius: 3).path(in: rect)
                context.fill(box, with: .color(.black.opacity(0.35)))
                context.stroke(box, with: .color(style.color(analog.color + "@0.22")), lineWidth: 1)
                let text = context.resolve(Text("\(time.day)").font(style.font(role: "mono", size: window.fontSize, weight: 500))
                    .foregroundStyle(ink))
                context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            }
            guard hands else { return }
            func hand(_ hand: AnalogGeometry.Hand, _ degrees: Double, _ color: Color) {
                var path = Path()
                path.move(to: point(-hand.tail, degrees))
                path.addLine(to: point(hand.length, degrees))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: hand.width, lineCap: .round))
            }
            hand(g.hour, angles.hour, ink)
            hand(g.minute, angles.minute, ink)
            if let second = g.second {
                hand(second, angles.second, secondsColor)
                let weight = point(-g.secondDotOffset, angles.second)
                context.fill(Path(ellipseIn: CGRect(x: weight.x - g.secondDotRadius, y: weight.y - g.secondDotRadius,
                                                    width: g.secondDotRadius * 2, height: g.secondDotRadius * 2)),
                             with: .color(secondsColor))
            }
            context.fill(Path(ellipseIn: CGRect(x: c - g.pivotRadius, y: c - g.pivotRadius, width: g.pivotRadius * 2, height: g.pivotRadius * 2)),
                         with: .color(pivotColor))
            if g.pivotHole > 0 {
                context.fill(Path(ellipseIn: CGRect(x: c - g.pivotHole, y: c - g.pivotHole, width: g.pivotHole * 2, height: g.pivotHole * 2)),
                             with: .color(hole))
            }
        }
    }
}

// MARK: - Sweeping hands

/// The hands of a sweeping face and the pivot over them, as Core Animation
/// layers that turn by themselves: the render server moves them, and the
/// app draws nothing per frame. Each hand turns at its steady rate from
/// its angle at the moment it was set; the angles are set again when the
/// view appears (every show makes a new one) and on every minute, so a
/// clock change or a sleep doesn't leave them behind. The drawing is
/// `AnalogDrawing`'s, from the same geometry.
struct AnalogHands: NSViewRepresentable {
    let analog: RenderNode.Analog
    let style: RenderStyle

    func makeNSView(context: Context) -> AnalogHandsView { AnalogHandsView() }

    func updateNSView(_ view: AnalogHandsView, context: Context) {
        view.configure(analog: analog, style: style)
    }

    static func dismantleNSView(_ view: AnalogHandsView, coordinator: ()) {
        view.stop()
    }
}

final class AnalogHandsView: NSView {
    /// At the pivot: the hands point to twelve in it (y up) and turn about it.
    private let pivot = CALayer()
    private let hour = CAShapeLayer()
    private let minute = CAShapeLayer()
    private let second = CALayer()
    private let secondLine = CAShapeLayer()
    private let secondDot = CAShapeLayer()
    private let cap = CAShapeLayer()
    private let hole = CAShapeLayer()
    private var zone: String?
    private var hasSecond = false
    private var drawn: (analog: RenderNode.Analog, theme: RenderTheme)?
    private var minuteTimer: Timer?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        second.addSublayer(secondLine)
        second.addSublayer(secondDot)
        for part in [hour, minute, second, cap, hole] { pivot.addSublayer(part) }
        layer?.addSublayer(pivot)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(analog: RenderNode.Analog, style: RenderStyle) {
        if let drawn, drawn.analog == analog, drawn.theme == style.theme { return }
        drawn = (analog, style.theme)
        zone = analog.zone
        let g = analog.geometry
        func cg(_ spec: String?) -> CGColor {
            let c = style.rgba(spec)
            return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        }
        func line(_ layer: CAShapeLayer, _ hand: AnalogGeometry.Hand, _ color: CGColor) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: -hand.tail))
            path.addLine(to: CGPoint(x: 0, y: hand.length))
            layer.path = path
            layer.strokeColor = color
            layer.fillColor = nil
            layer.lineWidth = hand.width
            layer.lineCap = .round
        }
        func disc(_ layer: CAShapeLayer, y: Double, radius: Double, _ color: CGColor) {
            layer.path = CGPath(ellipseIn: CGRect(x: -radius, y: y - radius, width: radius * 2, height: radius * 2), transform: nil)
            layer.fillColor = color
            layer.strokeColor = nil
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line(hour, g.hour, cg(analog.color))
        line(minute, g.minute, cg(analog.color))
        hasSecond = g.second != nil
        second.isHidden = !hasSecond
        if let hand = g.second {
            line(secondLine, hand, cg(analog.secondsColor))
            disc(secondDot, y: -g.secondDotOffset, radius: g.secondDotRadius, cg(analog.secondsColor))
        }
        disc(cap, y: 0, radius: g.pivotRadius, cg(analog.pivotColor))
        hole.isHidden = g.pivotHole <= 0
        disc(hole, y: 0, radius: g.pivotHole, cg("bg"))
        CATransaction.commit()
        sync()
    }

    override func layout() {
        super.layout()
        // The face is centered in the node's box, so the pivot is its middle.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pivot.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for part in [hour, minute, secondLine, secondDot, cap, hole] { part.contentsScale = scale }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        viewDidChangeBackingProperties()
        sync()
        // On every minute, just after it turns.
        let now = Date().timeIntervalSinceReferenceDate
        let next = Date(timeIntervalSinceReferenceDate: (now / 60).rounded(.down) * 60 + 60.05)
        let timer = Timer(fire: next, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    func stop() {
        minuteTimer?.invalidate()
        minuteTimer = nil
    }

    /// Each hand at its angle now, turning a full circle in its period.
    private func sync() {
        guard drawn != nil else { return }
        let angles = AnalogMath.angles(AnalogMath.time(Date(), zone: zone), mode: "sweep")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        turn(hour, from: angles.hour, period: 12 * 3600)
        turn(minute, from: angles.minute, period: 3600)
        if hasSecond { turn(second, from: angles.second, period: 60) }
        CATransaction.commit()
    }

    private func turn(_ layer: CALayer, from degrees: Double, period: Double) {
        // Clockwise is a negative angle with y up.
        let start = -degrees * .pi / 180
        layer.transform = CATransform3DMakeRotation(start, 0, 0, 1)
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = start
        spin.toValue = start - 2 * .pi
        spin.duration = period
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        layer.add(spin, forKey: "sweep")
    }
}

// MARK: - Flip

/// Split-flap tiles. A tile whose character changes between two models folds:
/// its top half falls over to the seam, then the new bottom half rises
/// (FlipTiming). The fold is tracked here, per node view, because a model
/// holds only the present text.
struct FlipDrawing: View {
    let flip: RenderNode.Flip
    let style: RenderStyle

    @ObservedObject private var pulse = RenderPulse.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var state = FlipState()

    /// What the view remembers between models (no `@State`: its macro is not
    /// in every toolchain).
    @MainActor
    final class FlipState: ObservableObject {
        struct Fold {
            var started: Date
            /// The characters before the change, for the tiles that fold.
            var before: [Int: String]
        }

        var shown: [String] = []
        @Published var fold: Fold?
    }

    var body: some View {
        let layout = flip.layout
        let characters = FlipLayout.characters(layout)
        Group {
            if let fold = state.fold {
                TimelineView(.animation) { context in
                    canvas(layout, elapsed: context.date.timeIntervalSince(fold.started) * 1000, before: fold.before)
                }
            } else {
                canvas(layout, elapsed: nil, before: [:])
            }
        }
        .onAppear { state.shown = characters }
        .onChange(of: characters) { _, new in
            let changed = FlipLayout.changedTiles(old: state.shown, new: new)
            if !changed.isEmpty, flip.animate, !reduceMotion, pulse.running {
                var before: [Int: String] = [:]
                for index in changed { before[index] = state.shown[index] }
                let started = Date()
                state.fold = FlipState.Fold(started: started, before: before)
                // Done after both halves; the timeline stops with the fold.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 * FlipTiming.halfMilliseconds / 1000 + 0.05) {
                    if state.fold?.started == started { state.fold = nil }
                }
            }
            state.shown = new
        }
    }

    private func canvas(_ layout: FlipLayout.Result, elapsed: Double?, before: [Int: String]) -> some View {
        let top = style.color(flip.tile), bottom = style.color(flip.tileBottom)
        let ink = style.color(flip.color)
        let squares = FlipLayout.colonSquares(height: layout.height, scale: flip.size / 90)
        return Canvas { context, size in
            var context = context
            context.translateBy(x: (size.width - layout.width) / 2, y: (size.height - layout.height) / 2)
            for item in layout.items {
                switch item.kind {
                case .space: break
                case .colon:
                    for y in squares.y {
                        let rect = CGRect(x: item.x + (item.width - squares.side) / 2, y: y, width: squares.side, height: squares.side)
                        context.fill(RoundedRectangle(cornerRadius: 2 * flip.size / 90).path(in: rect), with: .color(ink.opacity(0.75)))
                    }
                case .tile:
                    let rect = CGRect(x: item.x, y: item.y, width: item.width, height: item.height)
                    let fontSize = item.big ? flip.size : flip.smallSize
                    let radius = item.big ? 8 * flip.size / 90 : 5 * flip.size / 90
                    let old = elapsed.flatMap { _ in before[item.index] }
                    let angles = elapsed.flatMap { FlipTiming.angles(elapsed: $0) }
                    // Under the flaps: the new top half, and the old bottom half
                    // until the fold ends.
                    drawHalf(&context, rect, radius, upper: true, character: item.character, size: fontSize, color: top, ink: ink, scale: 1)
                    drawHalf(&context, rect, radius, upper: false, character: (angles != nil ? old : nil) ?? item.character,
                             size: fontSize, color: bottom, ink: ink, scale: 1)
                    if let angles, let old {
                        if angles.top < 90 {
                            drawHalf(&context, rect, radius, upper: true, character: old, size: fontSize, color: top, ink: ink,
                                     scale: cos(angles.top * .pi / 180))
                        } else {
                            drawHalf(&context, rect, radius, upper: false, character: item.character, size: fontSize, color: bottom, ink: ink,
                                     scale: cos(angles.bottom * .pi / 180))
                        }
                    }
                    // The seam and the notches at its ends.
                    context.fill(Path(CGRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1)), with: .color(.black.opacity(0.6)))
                    let notchWidth = item.big ? 3.0 * flip.size / 90 : 2.0 * flip.size / 90
                    let notchHeight = item.big ? 8.0 * flip.size / 90 : 5.0 * flip.size / 90
                    for x in [rect.minX, rect.maxX - notchWidth] {
                        context.fill(RoundedRectangle(cornerRadius: 1).path(in: CGRect(x: x, y: rect.midY - notchHeight / 2, width: notchWidth, height: notchHeight)),
                                     with: .color(.black.opacity(0.55)))
                    }
                }
            }
        }
    }

    /// One half of a tile showing `character`, squashed towards the seam by
    /// `scale` (1: flat on, 0: edge on).
    private func drawHalf(_ context: inout GraphicsContext, _ rect: CGRect, _ radius: Double, upper: Bool, character: String,
                          size: Double, color: Color, ink: Color, scale: Double) {
        guard scale > 0.001 else { return }
        var layer = context
        layer.translateBy(x: 0, y: rect.midY)
        layer.scaleBy(x: 1, y: scale)
        layer.translateBy(x: 0, y: -rect.midY)
        let half = upper
            ? CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
            : CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        let shape = upper
            ? UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: radius)
            : UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: radius, bottomTrailingRadius: radius, topTrailingRadius: 0)
        let path = shape.path(in: half)
        layer.fill(path, with: .color(color))
        layer.clip(to: path)
        let text = layer.resolve(Text(character).font(style.font(role: "sans", size: size, weight: 600)).foregroundStyle(ink))
        layer.draw(text, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
    }
}

// MARK: - Ring marks

/// The marks, labels and end dot of a `ring` node, drawn over its arc.
enum RingMarks {
    static func draw(_ context: inout GraphicsContext, ring: RenderNode.Ring, geometry g: RingGeometry, center: CGPoint, style: RenderStyle) {
        let ink = style.color("text")
        if ring.ticks > 0 {
            for index in 0..<ring.ticks {
                let major = g.isMajor(index)
                let radii = g.tickRadii(major: major)
                let angle = g.angle(at: g.tickFraction(index))
                let a = RingGeometry.offset(radius: radii.inner, angle: angle), b = RingGeometry.offset(radius: radii.outer, angle: angle)
                var path = Path()
                path.move(to: CGPoint(x: center.x + a.x, y: center.y + a.y))
                path.addLine(to: CGPoint(x: center.x + b.x, y: center.y + b.y))
                context.stroke(path, with: .color(ink.opacity(major ? 0.5 : 0.2)), lineWidth: major ? 1.5 : 1)
            }
        }
        for (index, label) in ring.labels.enumerated() where !label.isEmpty {
            let p = RingGeometry.offset(radius: g.labelRadius, angle: g.angle(at: g.labelFraction(index, of: ring.labels.count)))
            let text = context.resolve(Text(label).font(style.font(role: "mono", size: 10, weight: 400)).foregroundStyle(style.color("dim")))
            context.draw(text, at: CGPoint(x: center.x + p.x, y: center.y + p.y), anchor: .center)
        }
        if ring.dot {
            let p = RingGeometry.offset(radius: g.radius, angle: g.angle(at: min(max(ring.value, 0), 1)))
            let r = max(ring.thickness, 2) * 1.1
            context.fill(Path(ellipseIn: CGRect(x: center.x + p.x - r, y: center.y + p.y - r, width: r * 2, height: r * 2)),
                         with: .color(style.color(ring.dotColor, default: "text")))
        }
    }
}
// MARK: - Moon

/// The disc in `trackColor` with the lit part over it, from MoonGeometry's
/// outline (the same points as the other UIs).
struct MoonDrawing: View {
    let moon: RenderNode.Moon
    let style: RenderStyle

    var body: some View {
        let lit = style.color(moon.color)
        let track = moon.trackColor.map { style.color($0) } ?? Color(white: 1, opacity: 0.08)
        Canvas { context, size in
            let side = Double(min(size.width, size.height))
            guard side > 0 else { return }
            let r = CGFloat(MoonGeometry.radius(size: side)), c = CGFloat(side / 2)
            context.fill(Path(ellipseIn: CGRect(x: c - r, y: c - r, width: 2 * r, height: 2 * r)), with: .color(track))
            let points = MoonGeometry.litOutline(phase: moon.phase, size: side)
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: CGPoint(x: first.x, y: first.y))
            for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            path.closeSubpath()
            context.fill(path, with: .color(lit))
        }
    }
}

// MARK: - Matrix

/// Every cell of the panel from MatrixGeometry: the unlit ones in `offColor`
/// (a faint wash), the lit ones in `color`.
struct MatrixDrawing: View {
    let matrix: RenderNode.Matrix
    let style: RenderStyle

    var body: some View {
        let lit = style.color(matrix.color)
        let off = matrix.offColor.map { style.color($0) } ?? Color(white: 1, opacity: 0.065)
        let layout = matrix.layout
        Canvas { context, size in
            context.translateBy(x: (size.width - layout.width) / 2, y: (size.height - layout.height) / 2)
            for cell in layout.cells {
                let color = cell.lit ? lit : off
                switch cell.kind {
                case .dot:
                    context.fill(Path(ellipseIn: CGRect(x: cell.x - cell.radius, y: cell.y - cell.radius,
                                                        width: cell.radius * 2, height: cell.radius * 2)), with: .color(color))
                case .rect:
                    context.fill(RoundedRectangle(cornerRadius: cell.radius)
                        .path(in: CGRect(x: cell.x, y: cell.y, width: cell.width, height: cell.height)), with: .color(color))
                case .polygon:
                    var path = Path()
                    var i = 0
                    while i + 1 < cell.points.count {
                        let p = CGPoint(x: cell.points[i], y: cell.points[i + 1])
                        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        i += 2
                    }
                    path.closeSubpath()
                    context.fill(path, with: .color(color))
                }
            }
        }
    }
}

#endif
