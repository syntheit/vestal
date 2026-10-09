import Foundation

// MARK: - Drawn clock faces: shared arithmetic
//
// The `analog` and `flip` nodes are drawn by each UI from these numbers, so
// the three UIs (SwiftUI, GTK, web) agree on angles, geometry and which
// flip tiles change. Nothing here draws.

/// The time the UIs draw clocks with: the wall clock, or the moment a
/// screenshot was asked for (`--at`).
public enum RenderClock {
    /// Set by a command that draws a fixed moment; nil: the wall clock.
    nonisolated(unsafe) public static var override: Date?

    public static func now() -> Date { override ?? Date() }
}

// MARK: Analog

public enum AnalogMath {
    /// A moment read in a time zone.
    public struct Time: Equatable, Sendable {
        public var hour: Int
        public var minute: Int
        /// Seconds including the fraction, 0..<60.
        public var second: Double
        /// Day of the month.
        public var day: Int
    }

    /// `date` as the wall clock of `zone` (an IANA name; nil or an unknown
    /// name: the system zone).
    public static func time(_ date: Date, zone: String?) -> Time {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond, .day], from: date)
        return Time(hour: parts.hour ?? 0, minute: parts.minute ?? 0,
                    second: Double(parts.second ?? 0) + Double(parts.nanosecond ?? 0) / 1e9, day: parts.day ?? 1)
    }

    /// Hand angles in degrees clockwise from 12 o'clock. `second` is whole
    /// for a stepping seconds hand and fractional for a sweeping one; the
    /// minute and hour hands move continuously with it.
    public static func angles(hour: Int, minute: Int, second: Double) -> (hour: Double, minute: Double, second: Double) {
        (hour: (Double(hour % 12) + Double(minute) / 60 + second / 3600) * 30,
         minute: (Double(minute) + second / 60) * 6,
         second: second * 6)
    }

    /// The angles of `time` for a seconds `mode` (`none`, `step`, `sweep`):
    /// only a sweeping hand uses the fraction of the second.
    public static func angles(_ time: Time, mode: String) -> (hour: Double, minute: Double, second: Double) {
        angles(hour: time.hour, minute: time.minute, second: mode == "sweep" ? time.second : time.second.rounded(.down))
    }

    /// The point `radius` from `center` at `degrees` clockwise from 12 o'clock
    /// (y grows downwards).
    public static func point(center: Double, radius: Double, degrees: Double) -> (x: Double, y: Double) {
        let r = degrees * .pi / 180
        return (center + radius * sin(r), center - radius * cos(r))
    }
}

/// Where an `analog` node's parts go, in points, for a square of `size`.
/// Proportions are the approved faces': the quiet one (no ticks) has short
/// hands and a dot at twelve; the others have ticks, tails and the seconds
/// hand's counterweight.
public struct AnalogGeometry: Equatable, Sendable {
    public struct Hand: Equatable, Sendable {
        public var length: Double
        public var tail: Double
        public var width: Double
    }

    public struct Window: Equatable, Sendable {
        public var x: Double, y: Double, width: Double, height: Double, fontSize: Double
    }

    public var size: Double
    public var center: Double
    /// The face circle's radius (the stroke sits on it).
    public var faceRadius: Double
    /// Tick marks: outer radius, and the length of an hour and a minute mark.
    public var tickOuter: Double
    public var hourTickLength: Double
    public var minuteTickLength: Double
    public var hourTickWidth: Double
    public var minuteTickWidth: Double
    /// A mark every this many minutes (5, 1) or none (0).
    public var tickEvery: Int
    /// The quiet face's dot at twelve: y and radius; radius 0: none.
    public var dotY: Double
    public var dotRadius: Double
    public var hour: Hand
    public var minute: Hand
    public var second: Hand?
    /// The seconds hand's counterweight dot: distance below the pivot, radius.
    public var secondDotOffset: Double
    public var secondDotRadius: Double
    public var pivotRadius: Double
    /// A hole in the pivot (with a seconds hand); 0: none.
    public var pivotHole: Double
    public var window: Window?
    /// The numerals' radius and font size; 0: none.
    public var numeralRadius: Double
    public var numeralSize: Double

    public init(size: Double, ticks: String, seconds: String, dateWindow: Bool, numerals: Bool) {
        self.size = size
        let c = size / 2
        center = c
        faceRadius = c - 1
        let quiet = ticks == "none"
        // The approved faces are drawn at 236 (quiet) and 260; scale from those.
        let k = size / (quiet ? 236 : 260)
        tickEvery = ticks == "minutes" ? 1 : ticks == "hours" ? 5 : 0
        tickOuter = c - 7 * k
        hourTickLength = (tickEvery == 1 ? 15 : 10) * k
        minuteTickLength = 6 * k
        hourTickWidth = 2.5 * k
        minuteTickWidth = 1 * k
        dotY = quiet ? 14 * k : 0
        dotRadius = quiet ? 2.5 * k : 0
        if quiet {
            hour = Hand(length: 58 * k, tail: 0, width: 5 * k)
            minute = Hand(length: 92 * k, tail: 0, width: 3 * k)
        } else {
            hour = Hand(length: 66 * k, tail: 14 * k, width: 6 * k)
            minute = Hand(length: 102 * k, tail: 16 * k, width: 4 * k)
        }
        second = seconds == "none" ? nil : Hand(length: 114 * k, tail: 26 * k, width: 1.6 * k)
        secondDotOffset = 22 * k
        secondDotRadius = 3.5 * k
        pivotRadius = (seconds == "none" ? 5 : 4.5) * k
        pivotHole = seconds == "none" ? 0 : 1.6 * k
        window = dateWindow ? Window(x: c + 58 * k, y: c - 11 * k, width: 32 * k, height: 22 * k, fontSize: 13 * k) : nil
        numeralRadius = numerals ? c - (tickEvery == 0 ? 28 : 42) * k : 0
        numeralSize = numerals ? 20 * k : 0
    }

    /// The tick marks as (angle in degrees, major) pairs.
    public var ticks: [(degrees: Double, major: Bool)] {
        guard tickEvery > 0 else { return [] }
        return stride(from: 0, to: 60, by: tickEvery).map { (Double($0) * 6, $0 % 5 == 0) }
    }
}

// MARK: Flip

/// The tiles of a `flip` node, left to right with their bottoms on one line,
/// after the approved face: big tiles 80 x 114 at font size 90, small 36 x 52
/// at 40, 6 between elements, 3 between small tiles, 8 more before the small
/// group, a colon of two 9 point squares in a 21 point cell.
public enum FlipLayout {
    public struct Item: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case tile, colon, space }
        public var kind: Kind
        /// The character a tile shows; "" for others.
        public var character: String
        public var big: Bool
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double
        /// The tile's number among the tiles, left to right; -1 for others.
        public var index: Int
    }

    public struct Result: Equatable, Sendable {
        public var items: [Item]
        public var width: Double
        public var height: Double
        public var tileCount: Int
    }

    public static func bigTile(_ fontSize: Double) -> (width: Double, height: Double) { (fontSize * 80 / 90, fontSize * 114 / 90) }
    public static func smallTile(_ fontSize: Double) -> (width: Double, height: Double) { (fontSize * 36 / 40, fontSize * 52 / 40) }

    /// The tiles for `text` (big) followed by `small` (small tiles). A colon
    /// is two squares, a space a gap, anything else a tile.
    public static func layout(text: String, small: String, size: Double, smallSize: Double) -> Result {
        let big = bigTile(size), little = smallTile(smallSize)
        let scale = size / 90
        let height = max(big.height, small.isEmpty ? 0 : little.height)
        var items: [Item] = []
        var x = 0.0
        var tiles = 0

        func add(_ character: Character, isBig: Bool) {
            let box = isBig ? big : little
            switch character {
            case ":":
                items.append(Item(kind: .colon, character: ":", big: isBig, x: x, y: 0, width: 21 * scale, height: height, index: -1))
                x += 21 * scale
            case " ":
                items.append(Item(kind: .space, character: "", big: isBig, x: x, y: 0, width: box.width / 2, height: height, index: -1))
                x += box.width / 2
            default:
                items.append(Item(kind: .tile, character: String(character), big: isBig, x: x, y: height - box.height,
                                  width: box.width, height: box.height, index: tiles))
                tiles += 1
                x += box.width
            }
        }

        for (n, character) in text.enumerated() {
            if n > 0 { x += 6 * scale }
            add(character, isBig: true)
        }
        for (n, character) in small.enumerated() {
            x += n == 0 ? (text.isEmpty ? 0 : 14 * scale) : 3 * scale
            add(character, isBig: false)
        }
        return Result(items: items, width: x, height: height, tileCount: tiles)
    }

    /// The two squares of a colon in a cell of `height`, as y offsets from the
    /// cell's top, and their side.
    public static func colonSquares(height: Double, scale: Double) -> (y: [Double], side: Double) {
        let block = 40 * scale, lift = 18 * scale
        let top = (height - block) / 2 - lift
        return ([top, top + 31 * scale], 9 * scale)
    }

    /// The tiles that changed between two texts, by tile number. Texts with a
    /// different number of tiles (or no previous text) change nothing: a node
    /// that is new, or whose shape changed, simply appears.
    public static func changedTiles(old: [String], new: [String]) -> Set<Int> {
        guard !old.isEmpty, old.count == new.count else { return [] }
        return Set(new.indices.filter { old[$0] != new[$0] })
    }

    /// The characters of the tiles of `layout`, in tile order.
    public static func characters(_ layout: Result) -> [String] {
        layout.items.filter { $0.kind == .tile }.map(\.character)
    }
}

/// The fold of a tile: the top half falls over 170 ms, then the bottom half
/// rises over 170 ms.
public enum FlipTiming {
    public static let halfMilliseconds = 170.0

    /// The two halves' rotation about the middle seam at `elapsed`
    /// milliseconds, in degrees: the falling top half goes from 0 to 90, the
    /// rising bottom half from 90 to 0. Nil once the fold is done.
    public static func angles(elapsed: Double) -> (top: Double, bottom: Double)? {
        guard elapsed < halfMilliseconds * 2 else { return nil }
        if elapsed < halfMilliseconds {
            let t = max(0, elapsed) / halfMilliseconds
            return (90 * t * t, 90)  // ease-in
        }
        let t = (elapsed - halfMilliseconds) / halfMilliseconds
        return (90, 90 * (1 - (1 - (1 - t) * (1 - t))))  // ease-out
    }
}

// MARK: Ring

/// Where a `ring` node's arc, dot, marks and labels go, for the square of
/// `side` points it is drawn in. Angles are canvas radians: 0 points right,
/// and they grow clockwise on screen (y down).
public struct RingGeometry: Equatable, Sendable {
    /// How far inside the box the arc sits when there are marks to fit.
    public static let tickRoom = 15.0

    public var radius: Double
    public var start: Double
    public var sweep: Double
    public var ticks: Int
    public var tickCount: Int { ticks }
    public var labelRadius: Double

    public init(side: Double, ring: RenderNode.Ring) {
        let arc = min(max(ring.sweep, 0), 360) * .pi / 180
        sweep = arc
        // A full circle starts at twelve o'clock; any other arc has its gap
        // centered at the bottom.
        start = ring.sweep >= 360 ? -.pi / 2 : .pi / 2 + (2 * .pi - arc) / 2
        ticks = ring.ticks
        if ring.ticks > 0 {
            radius = max(0, side / 2 - Self.tickRoom)
        } else {
            radius = max(0, (side - ring.thickness) / 2)
        }
        labelRadius = max(0, radius - 20)
    }

    public var isFull: Bool { sweep >= 2 * .pi - 1e-9 }

    /// The canvas angle `fraction` (0 to 1) of the way along the arc.
    public func angle(at fraction: Double) -> Double { start + sweep * fraction }

    /// An offset from the ring's center at `radius` and canvas angle `angle`.
    public static func offset(radius: Double, angle: Double) -> (x: Double, y: Double) {
        (radius * cos(angle), radius * sin(angle))
    }

    /// Mark `index`'s fraction along the arc: a full circle has `ticks` marks
    /// round it, an arc has the first and the last on its ends.
    public func tickFraction(_ index: Int) -> Double {
        let steps = isFull ? ticks : max(1, ticks - 1)
        return Double(index) / Double(steps)
    }

    /// Every fourth mark is longer and brighter.
    public func isMajor(_ index: Int) -> Bool { index % max(1, ticks / 4) == 0 }

    /// Radii a mark spans, outside the arc.
    public func tickRadii(major: Bool) -> (inner: Double, outer: Double) { (radius + 9, radius + (major ? 15 : 12)) }

    /// Label `index` of `count`: its fraction along the arc.
    public func labelFraction(_ index: Int, of count: Int) -> Double {
        let steps = isFull ? count : max(1, count - 1)
        return Double(index) / Double(steps)
    }
}
