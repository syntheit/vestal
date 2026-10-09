import Foundation

// MARK: - Render model: nodes
//
// The resolved tree a UI draws. Every text is a
// string, every size a number, every icon a name plus a glyph; colours are
// `#rrggbbaa` or a key of the snapshot's `theme.colors`.
//
// Decoding is lenient: unknown fields are ignored and an unknown node
// type decodes as `.unknown`, which a UI draws as its `alt` text. Encoding is
// deterministic: defaults are omitted and the encoder is expected to sort
// keys (`RenderJSON.encoder`), so output is golden-testable.
//

/// A size on one axis: an exact number of points, or `fill`.
/// Absent (nil where it's used) means fit.
public enum RenderLength: Equatable, Sendable, Codable {
    case points(Double)
    case fill

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Double.self) { self = .points(v); return }
        let s = try c.decode(String.self)
        guard s == "fill" else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected a number or \"fill\", got \"\(s)\"")
        }
        self = .fill
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .points(let v): try c.encode(v)
        case .fill: try c.encode("fill")
        }
    }
}

/// `[top, right, bottom, left]`.
public struct RenderInsets: Equatable, Sendable, Codable {
    public var top: Double
    public var right: Double
    public var bottom: Double
    public var left: Double

    public static let zero = RenderInsets(top: 0, right: 0, bottom: 0, left: 0)

    public init(top: Double, right: Double, bottom: Double, left: Double) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let v = try c.decode([Double].self)
        guard v.count == 4 else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "padding needs 4 numbers [t, r, b, l]")
        }
        self.init(top: v[0], right: v[1], bottom: v[2], left: v[3])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode([top, right, bottom, left])
    }

    public var horizontal: Double { left + right }
    public var vertical: Double { top + bottom }
}

public struct RenderBorder: Equatable, Sendable, Codable {
    public var color: String
    public var width: Double

    public init(color: String, width: Double) {
        self.color = color
        self.width = width
    }
}

/// Cross-axis alignment in a stack (`baseline` only for `h`), and `alignSelf`.
public enum RenderAlign: String, Equatable, Sendable, Codable {
    case start, center, end, stretch, baseline
}

/// Main-axis distribution of leftover space in a stack without fill children.
public enum RenderJustify: String, Equatable, Sendable, Codable {
    case start, center, end, between
}

public enum RenderAxis: String, Equatable, Sendable, Codable {
    case v, h
}

/// A text or grid column alignment.
public enum RenderTextAlign: String, Equatable, Sendable, Codable {
    case start, center, end
}

/// One node of the tree: the common fields and the
/// type's own fields in `content`.
public struct RenderNode: Equatable, Sendable, Codable {
    public var id: String
    public var width: RenderLength?
    public var height: RenderLength?
    public var minWidth: Double?
    public var maxWidth: Double?
    public var minHeight: Double?
    public var maxHeight: Double?
    public var padding: RenderInsets
    public var background: String?
    public var radius: Double
    public var border: RenderBorder?
    public var opacity: Double
    public var clip: Bool
    /// Replaces the parent stack's `gap` before this node.
    public var spaceBefore: Double?
    public var alignSelf: RenderAlign?
    /// Grid columns this cell takes.
    public var span: Int
    /// Clickable: a click sends `invoke` with this id.
    public var action: Bool
    /// Plain-text rendition.
    public var alt: String?
    public var content: Content

    public indirect enum Content: Equatable, Sendable {
        case stack(Stack)
        case grid(Grid)
        case text(Text)
        case icon(Icon)
        case bar(Bar)
        case ring(Ring)
        case spark(Spark)
        case divider(Divider)
        case spacer(Spacer)
        case bars(Bars)
        case stackedBar(StackedBar)
        case heatmap(Heatmap)
        case timeline(Timeline)
        case image(Image)
        /// A type this build doesn't know (a newer `minor`); drawn as `alt`.
        case unknown(type: String)
    }

    public init(id: String, _ content: Content) {
        self.id = id
        self.width = nil
        self.height = nil
        self.minWidth = nil
        self.maxWidth = nil
        self.minHeight = nil
        self.maxHeight = nil
        self.padding = .zero
        self.background = nil
        self.radius = 0
        self.border = nil
        self.opacity = 1
        self.clip = false
        self.spaceBefore = nil
        self.alignSelf = nil
        self.span = 1
        self.action = false
        self.alt = nil
        self.content = content
    }

    /// The `type` field.
    public var type: String {
        switch content {
        case .stack: return "stack"
        case .grid: return "grid"
        case .text: return "text"
        case .icon: return "icon"
        case .bar: return "bar"
        case .ring: return "ring"
        case .spark: return "spark"
        case .divider: return "divider"
        case .spacer: return "spacer"
        case .bars: return "bars"
        case .stackedBar: return "stackedBar"
        case .heatmap: return "heatmap"
        case .timeline: return "timeline"
        case .image: return "image"
        case .unknown(let type): return type
        }
    }

    /// The node's child nodes in order: a container's children, or a ring's
    /// `center`.
    public var children: [RenderNode] {
        get {
            switch content {
            case .stack(let s): return s.children
            case .grid(let g): return g.children
            case .ring(let r): return r.center.map { [$0] } ?? []
            default: return []
            }
        }
        set {
            switch content {
            case .stack(var s): s.children = newValue; content = .stack(s)
            case .grid(var g): g.children = newValue; content = .grid(g)
            case .ring(var r): r.center = newValue.first; content = .ring(r)
            default: break
            }
        }
    }

    // MARK: Node types

    public struct Stack: Equatable, Sendable {
        public var axis: RenderAxis = .v
        public var gap: Double = 0
        public var align: RenderAlign = .start
        public var justify: RenderJustify = .start
        public var children: [RenderNode] = []

        public init(axis: RenderAxis = .v, gap: Double = 0, align: RenderAlign = .start,
                    justify: RenderJustify = .start, children: [RenderNode] = []) {
            self.axis = axis
            self.gap = gap
            self.align = align
            self.justify = justify
            self.children = children
        }
    }

    public struct Grid: Equatable, Sendable {
        public struct Column: Equatable, Sendable, Codable {
            public enum Width: Equatable, Sendable, Codable {
                case points(Double), fill, fit

                public init(from decoder: Decoder) throws {
                    let c = try decoder.singleValueContainer()
                    if let v = try? c.decode(Double.self) { self = .points(v); return }
                    switch try c.decode(String.self) {
                    case "fill": self = .fill
                    default: self = .fit
                    }
                }

                public func encode(to encoder: Encoder) throws {
                    var c = encoder.singleValueContainer()
                    switch self {
                    case .points(let v): try c.encode(v)
                    case .fill: try c.encode("fill")
                    case .fit: try c.encode("fit")
                    }
                }
            }

            public var width: Width
            public var align: RenderTextAlign

            public init(width: Width = .fit, align: RenderTextAlign = .start) {
                self.width = width
                self.align = align
            }

            private enum Keys: String, CodingKey { case width, align }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                width = try c.decodeIfPresent(Width.self, forKey: .width) ?? .fit
                align = (try? c.decodeIfPresent(RenderTextAlign.self, forKey: .align)) ?? .start
            }

            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: Keys.self)
                try c.encode(width, forKey: .width)
                if align != .start { try c.encode(align, forKey: .align) }
            }
        }

        public var columns: [Column] = []
        public var gap: Double = 0
        public var rowGap: Double = 0
        public var children: [RenderNode] = []

        public init(columns: [Column] = [], gap: Double = 0, rowGap: Double = 0, children: [RenderNode] = []) {
            self.columns = columns
            self.gap = gap
            self.rowGap = rowGap
            self.children = children
        }
    }

    public struct Text: Equatable, Sendable {
        public var text: String = ""
        public var size: Double = 13
        public var weight: Int = 400
        /// `sans`, `mono` or `rounded`.
        public var font: String = "sans"
        public var color: String = "text"
        public var tracking: Double = 0
        /// Nil: unlimited (wraps).
        public var lines: Int?
        public var textAlign: RenderTextAlign = .start

        public init(text: String = "", size: Double = 13, weight: Int = 400, font: String = "sans",
                    color: String = "text", tracking: Double = 0, lines: Int? = nil,
                    textAlign: RenderTextAlign = .start) {
            self.text = text
            self.size = size
            self.weight = weight
            self.font = font
            self.color = color
            self.tracking = tracking
            self.lines = lines
            self.textAlign = textAlign
        }
    }

    public struct Icon: Equatable, Sendable {
        public var name: String = ""
        /// One character in the icon font; nil for `sf:` names (drawn as
        /// nothing outside macOS).
        public var glyph: String?
        /// `regular` or `fill`.
        public var weight: String = "regular"
        public var size: Double = 13
        public var color: String = "text"

        public init(name: String = "", glyph: String? = nil, weight: String = "regular",
                    size: Double = 13, color: String = "text") {
            self.name = name
            self.glyph = glyph
            self.weight = weight
            self.size = size
            self.color = color
        }
    }

    public struct Bar: Equatable, Sendable {
        /// 0…1.
        public var value: Double = 0
        public var overlay: Double?
        /// `above` or `below` the fill.
        public var overlayPosition: String = "above"
        public var color: String?
        public var trackColor: String?
        public var overlayColor: String?
        public var radius: Double = 2

        public init(value: Double = 0, overlay: Double? = nil, overlayPosition: String = "above",
                    color: String? = nil, trackColor: String? = nil, overlayColor: String? = nil,
                    radius: Double = 2) {
            self.value = value
            self.overlay = overlay
            self.overlayPosition = overlayPosition
            self.color = color
            self.trackColor = trackColor
            self.overlayColor = overlayColor
            self.radius = radius
        }
    }

    public struct Ring: Equatable, Sendable {
        public var value: Double = 0
        /// Degrees of arc; the gap is centred at the bottom.
        public var sweep: Double = 270
        public var thickness: Double = 6
        public var color: String?
        public var trackColor: String?
        public var center: RenderNode?

        public init(value: Double = 0, sweep: Double = 270, thickness: Double = 6,
                    color: String? = nil, trackColor: String? = nil, center: RenderNode? = nil) {
            self.value = value
            self.sweep = sweep
            self.thickness = thickness
            self.color = color
            self.trackColor = trackColor
            self.center = center
        }
    }

    public struct Spark: Equatable, Sendable {
        public var values: [Double] = []
        public var min: Double?
        public var max: Double?
        public var color: String?
        public var fill: String?
        public var strokeWidth: Double = 1.5
        public var dot: Bool = false

        public init(values: [Double] = [], min: Double? = nil, max: Double? = nil, color: String? = nil,
                    fill: String? = nil, strokeWidth: Double = 1.5, dot: Bool = false) {
            self.values = values
            self.min = min
            self.max = max
            self.color = color
            self.fill = fill
            self.strokeWidth = strokeWidth
            self.dot = dot
        }
    }

    public struct Divider: Equatable, Sendable {
        public var axis: RenderAxis = .h
        public var thickness: Double = 0.5
        public var color: String = "dim"

        public init(axis: RenderAxis = .h, thickness: Double = 0.5, color: String = "dim") {
            self.axis = axis
            self.thickness = thickness
            self.color = color
        }
    }

    public struct Spacer: Equatable, Sendable {
        /// Minimum length along the parent stack's axis.
        public var min: Double = 0

        public init(min: Double = 0) { self.min = min }
    }

    /// Vertical columns from the left edge, bottom-aligned.
    public struct Bars: Equatable, Sendable {
        /// One per column; the column is `value / max` tall, clamped.
        public var values: [Double] = []
        /// The value of a full-height column.
        public var max: Double = 1
        /// One per column.
        public var colors: [String] = []
        /// A column's width; nil: the columns share the width.
        public var barWidth: Double?
        /// Between columns.
        public var gap: Double = 3

        public init(values: [Double] = [], max: Double = 1, colors: [String] = [], barWidth: Double? = nil, gap: Double = 3) {
            self.values = values
            self.max = max
            self.colors = colors
            self.barWidth = barWidth
            self.gap = gap
        }
    }

    /// One horizontal bar split into segments, left to right; what the
    /// segments leave is the track.
    public struct StackedBar: Equatable, Sendable {
        public struct Segment: Equatable, Sendable, Codable {
            /// The segment's share of the whole bar, 0...1.
            public var value: Double
            public var color: String

            public init(value: Double, color: String) {
                self.value = value
                self.color = color
            }
        }

        public var segments: [Segment] = []
        public var trackColor: String = "track"
        /// The bar's corner radius.
        public var radius: Double = 4

        public init(segments: [Segment] = [], trackColor: String = "track", radius: Double = 4) {
            self.segments = segments
            self.trackColor = trackColor
            self.radius = radius
        }
    }

    /// A grid of square cells.
    public struct Heatmap: Equatable, Sendable {
        /// One entry per cell in fill order, resolved to a colour; nil is an
        /// empty cell, drawn in `trackColor`.
        public var cells: [String?] = []
        public var rows: Int = 7
        /// `columns`: cell `i` is at column `i / rows`, row `i % rows`.
        /// `rows`: row-major with `ceil(count / rows)` columns.
        public var direction: String = "columns"
        public var cell: Double = 8
        public var gap: Double = 2
        public var radius: Double = 2
        public var trackColor: String = "track"

        public init(cells: [String?] = [], rows: Int = 7, direction: String = "columns", cell: Double = 8,
                    gap: Double = 2, radius: Double = 2, trackColor: String = "track") {
            self.cells = cells
            self.rows = rows
            self.direction = direction
            self.cell = cell
            self.gap = gap
            self.radius = radius
            self.trackColor = trackColor
        }

        /// The number of columns the cells fill.
        public var columns: Int {
            let rows = Swift.max(self.rows, 1)
            return cells.isEmpty ? 0 : (cells.count + rows - 1) / rows
        }

        /// Where cell `index` is: its column and row.
        public func position(of index: Int) -> (column: Int, row: Int) {
            let rows = Swift.max(self.rows, 1)
            if direction == "rows" {
                let columns = Swift.max(self.columns, 1)
                return (index % columns, index / columns)
            }
            return (index / rows, index % rows)
        }
    }

    /// A time axis from the node's left edge (`from`) to its right (`to`),
    /// everything as fractions 0...1 of its width.
    public struct Timeline: Equatable, Sendable {
        public struct Item: Equatable, Sendable, Codable {
            public var start: Double
            /// Nil: a point marker.
            public var end: Double?
            public var label: String?
            public var color: String
            /// Overlapping items go on separate lanes, from 0 (the top).
            public var lane: Int

            public init(start: Double, end: Double? = nil, label: String? = nil, color: String, lane: Int = 0) {
                self.start = start
                self.end = end
                self.label = label
                self.color = color
                self.lane = lane
            }
        }

        public struct Tick: Equatable, Sendable, Codable {
            public var at: Double
            public var label: String

            public init(at: Double, label: String) {
                self.at = at
                self.label = label
            }
        }

        public var items: [Item] = []
        public var ticks: [Tick] = []
        public var lanes: Int = 1
        /// The current time; nil outside the range or when `now` is off.
        public var now: Double?
        public var nowColor: String = "accent"

        public init(items: [Item] = [], ticks: [Tick] = [], lanes: Int = 1, now: Double? = nil, nowColor: String = "accent") {
            self.items = items
            self.ticks = ticks
            self.lanes = lanes
            self.now = now
            self.nowColor = nowColor
        }
    }

    /// A picture from a file on this machine.
    public struct Image: Equatable, Sendable {
        /// The local file to draw: the `src` path, or for a URL its copy in
        /// vestal's cache. Nil: nothing to draw (an empty `track` rectangle).
        public var path: String?
        /// `cover` fills the frame and crops; `contain` shows the whole picture.
        public var fit: String = "cover"
        /// The picture's corner radius.
        public var radius: Double = 6

        public init(path: String? = nil, fit: String = "cover", radius: Double = 6) {
            self.path = path
            self.fit = fit
            self.radius = radius
        }
    }

    // MARK: Coding

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func opt<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T? {
            try c.decodeIfPresent(T.self, forKey: Key(key))
        }
        /// Lenient enums: an unknown value is the default, not an error.
        func lenient<T: Decodable>(_ key: String, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: Key(key))) ?? nil) ?? fallback
        }

        id = try c.decode(String.self, forKey: Key("id"))
        width = try opt("width")
        height = try opt("height")
        minWidth = try opt("minWidth")
        maxWidth = try opt("maxWidth")
        minHeight = try opt("minHeight")
        maxHeight = try opt("maxHeight")
        padding = try opt("padding") ?? .zero
        background = try opt("background")
        radius = try opt("radius") ?? 0
        border = try opt("border")
        opacity = try opt("opacity") ?? 1
        clip = try opt("clip") ?? false
        spaceBefore = try opt("spaceBefore")
        // `alignSelf` takes start, center, end or stretch; `baseline` is only
        // a stack's `align`.
        alignSelf = lenient("alignSelf", RenderAlign?.none).flatMap { $0 == .baseline ? nil : $0 }
        span = try opt("span") ?? 1
        action = try opt("action") ?? false
        alt = try opt("alt")

        let type = try c.decode(String.self, forKey: Key("type"))
        switch type {
        case "stack":
            content = .stack(Stack(
                axis: lenient("axis", RenderAxis.v),
                gap: try opt("gap") ?? 0,
                align: lenient("align", RenderAlign.start),
                justify: lenient("justify", RenderJustify.start),
                children: try opt("children") ?? []))
        case "grid":
            content = .grid(Grid(
                columns: try opt("columns") ?? [],
                gap: try opt("gap") ?? 0,
                rowGap: try opt("rowGap") ?? 0,
                children: try opt("children") ?? []))
        case "text":
            content = .text(Text(
                text: try opt("text") ?? "",
                size: try opt("size") ?? 13,
                weight: Int((try opt("weight", Double.self) ?? 400).rounded()),
                font: try opt("font") ?? "sans",
                color: try opt("color") ?? "text",
                tracking: try opt("tracking") ?? 0,
                lines: try opt("lines"),
                textAlign: lenient("textAlign", RenderTextAlign.start)))
        case "icon":
            content = .icon(Icon(
                name: try opt("name") ?? "",
                glyph: try opt("glyph"),
                weight: try opt("weight") ?? "regular",
                size: try opt("size") ?? 13,
                color: try opt("color") ?? "text"))
        case "bar":
            content = .bar(Bar(
                value: try opt("value") ?? 0,
                overlay: try opt("overlay"),
                overlayPosition: try opt("overlayPosition") ?? "above",
                color: try opt("color"),
                trackColor: try opt("trackColor"),
                overlayColor: try opt("overlayColor"),
                radius: try opt("radius") ?? 2))
            // `radius` is also a common field (the box's corner); for a bar it
            // is the bar's own corner, default 2, and the box has none.
            radius = 0
        case "ring":
            content = .ring(Ring(
                value: try opt("value") ?? 0,
                sweep: try opt("sweep") ?? 270,
                thickness: try opt("thickness") ?? 6,
                color: try opt("color"),
                trackColor: try opt("trackColor"),
                center: try opt("center")))
        case "spark":
            content = .spark(Spark(
                values: try opt("values") ?? [],
                min: try opt("min"),
                max: try opt("max"),
                color: try opt("color"),
                fill: try opt("fill"),
                strokeWidth: try opt("strokeWidth") ?? 1.5,
                dot: try opt("dot") ?? false))
        case "divider":
            content = .divider(Divider(
                axis: lenient("axis", RenderAxis.h),
                thickness: try opt("thickness") ?? 0.5,
                color: try opt("color") ?? "dim"))
        case "spacer":
            content = .spacer(Spacer(min: try opt("min") ?? 0))
        case "bars":
            content = .bars(Bars(
                values: try opt("values") ?? [],
                max: try opt("max") ?? 1,
                colors: try opt("colors") ?? [],
                barWidth: try opt("barWidth"),
                gap: try opt("gap") ?? 3))
        case "stackedBar":
            content = .stackedBar(StackedBar(
                segments: try opt("segments") ?? [],
                trackColor: try opt("trackColor") ?? "track",
                radius: try opt("radius") ?? 4))
            // The corner is the bar's own, as for `bar`.
            radius = 0
        case "heatmap":
            content = .heatmap(Heatmap(
                cells: try opt("cells") ?? [],
                rows: Swift.max(1, (try opt("rows", Int.self)) ?? 7),
                direction: lenient("direction", "columns") == "rows" ? "rows" : "columns",
                cell: try opt("cell") ?? 8,
                gap: try opt("gap") ?? 2,
                radius: try opt("radius") ?? 2,
                trackColor: try opt("trackColor") ?? "track"))
            radius = 0
        case "timeline":
            content = .timeline(Timeline(
                items: try opt("items") ?? [],
                ticks: try opt("ticks") ?? [],
                lanes: Swift.max(1, (try opt("lanes", Int.self)) ?? 1),
                now: try opt("now"),
                nowColor: try opt("nowColor") ?? "accent"))
        case "image":
            content = .image(Image(
                path: try opt("path"),
                fit: lenient("fit", "cover") == "contain" ? "contain" : "cover",
                radius: try opt("radius") ?? 6))
            radius = 0
        default:
            content = .unknown(type: type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        func put<T: Encodable>(_ key: String, _ value: T?) throws {
            if let value { try c.encode(value, forKey: Key(key)) }
        }
        func put<T: Encodable & Equatable>(_ key: String, _ value: T, default d: T) throws {
            if value != d { try c.encode(value, forKey: Key(key)) }
        }

        try c.encode(id, forKey: Key("id"))
        try c.encode(type, forKey: Key("type"))
        try put("width", width)
        try put("height", height)
        try put("minWidth", minWidth)
        try put("maxWidth", maxWidth)
        try put("minHeight", minHeight)
        try put("maxHeight", maxHeight)
        try put("padding", padding, default: .zero)
        try put("background", background)
        try put("border", border)
        try put("opacity", opacity, default: 1)
        try put("clip", clip, default: false)
        try put("spaceBefore", spaceBefore)
        try put("alignSelf", alignSelf)
        try put("span", span, default: 1)
        try put("action", action, default: false)
        try put("alt", alt)

        switch content {
        case .stack(let s):
            try put("radius", radius, default: 0)
            try put("axis", s.axis, default: .v)
            try put("gap", s.gap, default: 0)
            try put("align", s.align, default: .start)
            try put("justify", s.justify, default: .start)
            try put("children", s.children, default: [])
        case .grid(let g):
            try put("radius", radius, default: 0)
            try put("columns", g.columns, default: [])
            try put("gap", g.gap, default: 0)
            try put("rowGap", g.rowGap, default: 0)
            try put("children", g.children, default: [])
        case .text(let t):
            try put("radius", radius, default: 0)
            try c.encode(t.text, forKey: Key("text"))
            try put("size", t.size, default: 13)
            try put("weight", t.weight, default: 400)
            try put("font", t.font, default: "sans")
            try put("color", t.color, default: "text")
            try put("tracking", t.tracking, default: 0)
            try put("lines", t.lines)
            try put("textAlign", t.textAlign, default: .start)
        case .icon(let i):
            try put("radius", radius, default: 0)
            try c.encode(i.name, forKey: Key("name"))
            try put("glyph", i.glyph)
            try put("weight", i.weight, default: "regular")
            try put("size", i.size, default: 13)
            try put("color", i.color, default: "text")
        case .bar(let b):
            try put("value", b.value, default: 0)
            try put("overlay", b.overlay)
            try put("overlayPosition", b.overlayPosition, default: "above")
            try put("color", b.color)
            try put("trackColor", b.trackColor)
            try put("overlayColor", b.overlayColor)
            try put("radius", b.radius, default: 2)
        case .ring(let r):
            try put("radius", radius, default: 0)
            try put("value", r.value, default: 0)
            try put("sweep", r.sweep, default: 270)
            try put("thickness", r.thickness, default: 6)
            try put("color", r.color)
            try put("trackColor", r.trackColor)
            try put("center", r.center)
        case .spark(let s):
            try put("radius", radius, default: 0)
            try put("values", s.values, default: [])
            try put("min", s.min)
            try put("max", s.max)
            try put("color", s.color)
            try put("fill", s.fill)
            try put("strokeWidth", s.strokeWidth, default: 1.5)
            try put("dot", s.dot, default: false)
        case .divider(let d):
            try put("radius", radius, default: 0)
            try put("axis", d.axis, default: .h)
            try put("thickness", d.thickness, default: 0.5)
            try put("color", d.color, default: "dim")
        case .spacer(let s):
            try put("radius", radius, default: 0)
            try put("min", s.min, default: 0)
        case .bars(let b):
            try put("radius", radius, default: 0)
            try put("values", b.values, default: [])
            try put("max", b.max, default: 1)
            try put("colors", b.colors, default: [])
            try put("barWidth", b.barWidth)
            try put("gap", b.gap, default: 3)
        case .stackedBar(let b):
            try put("segments", b.segments, default: [])
            try put("trackColor", b.trackColor, default: "track")
            try put("radius", b.radius, default: 4)
        case .heatmap(let h):
            try put("cells", h.cells, default: [])
            try put("rows", h.rows, default: 7)
            try put("direction", h.direction, default: "columns")
            try put("cell", h.cell, default: 8)
            try put("gap", h.gap, default: 2)
            try put("radius", h.radius, default: 2)
            try put("trackColor", h.trackColor, default: "track")
        case .timeline(let t):
            try put("radius", radius, default: 0)
            try put("items", t.items, default: [])
            try put("ticks", t.ticks, default: [])
            try put("lanes", t.lanes, default: 1)
            try put("now", t.now)
            try put("nowColor", t.nowColor, default: "accent")
        case .image(let i):
            try put("path", i.path)
            try put("fit", i.fit, default: "cover")
            try put("radius", i.radius, default: 6)
        case .unknown:
            try put("radius", radius, default: 0)
        }
    }
}

// MARK: - Tree helpers

extension RenderNode {
    /// This node and every node under it, depth first, parents first.
    public func walk(_ visit: (RenderNode) -> Void) {
        visit(self)
        for child in children { child.walk(visit) }
    }

    /// The node with `id` in this subtree.
    public func node(withId target: String) -> RenderNode? {
        if id == target { return self }
        for child in children {
            if let found = child.node(withId: target) { return found }
        }
        return nil
    }

    /// Replaces the subtree whose root has `id`; false when there is none.
    @discardableResult
    public mutating func replace(id target: String, with node: RenderNode) -> Bool {
        if id == target { self = node; return true }
        var kids = children
        for i in kids.indices where kids[i].replace(id: target, with: node) {
            children = kids
            return true
        }
        return false
    }

    /// Ids that occur more than once in this subtree (ids must be unique).
    public var duplicateIds: [String] {
        var seen = Set<String>(), dupes: [String] = []
        walk { if !seen.insert($0.id).inserted { dupes.append($0.id) } }
        return dupes
    }
}
