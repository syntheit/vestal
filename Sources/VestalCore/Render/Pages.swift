import Foundation

// MARK: - Pages
//
// Paging between views, like a phone's home screens: the order the pages
// come in, how a change of page is drawn, and the indicator. The core owns
// which page is current; the UIs draw the transition and the dots from the
// snapshot's `pages`, and report keys and swipes back.

/// The top-level `pages` object, read once.
public struct PagesConfig: Equatable, Sendable {
    public static let transitions = ["slide", "fade", "none"]
    public static let indicators = ["dots", "none"]

    /// `pages.order` as written (nil: not set).
    public var order: [String]?
    public var transition: String
    public var indicator: String
    public var swipe: Bool
    public var wrap: Bool

    public init(order: [String]? = nil, transition: String = "slide", indicator: String = "dots",
                swipe: Bool = true, wrap: Bool = false) {
        self.order = order
        self.transition = transition
        self.indicator = indicator
        self.swipe = swipe
        self.wrap = wrap
    }

    /// Reads `pages`; anything invalid falls back to its default.
    public init(_ json: AnyJSON?) {
        let object = json?.objectValue ?? [:]
        var order: [String]?
        if case .array(let items)? = object["order"] {
            let names = items.compactMap(\.stringValue)
            if names.count == items.count { order = names }
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            if case .bool(let b)? = object[key] { return b }
            return fallback
        }
        self.init(order: order,
                  transition: object["transition"]?.stringValue.flatMap { Self.transitions.contains($0) ? $0 : nil } ?? "slide",
                  indicator: object["indicator"]?.stringValue.flatMap { Self.indicators.contains($0) ? $0 : nil } ?? "dots",
                  swipe: flag("swipe", true), wrap: flag("wrap", false))
    }
}

/// `pages` in a snapshot. Present only when there are two or more pages.
public struct RenderPages: Equatable, Sendable, Codable {
    /// The pages in paging order.
    public var items: [RenderViewInfo]
    /// Where the current view is in `items`; nil when it is not a page
    /// (reached by its key or `vestal show`).
    public var index: Int?
    /// +1 when the last change of view went to a later page, -1 to an
    /// earlier one; absent when there was none or it had no direction.
    public var direction: Int?
    public var transition: String
    public var indicator: String
    public var swipe: Bool
    public var wrap: Bool

    public init(items: [RenderViewInfo], index: Int?, direction: Int? = nil, transition: String = "slide",
                indicator: String = "dots", swipe: Bool = true, wrap: Bool = false) {
        self.items = items
        self.index = index
        self.direction = direction
        self.transition = transition
        self.indicator = indicator
        self.swipe = swipe
        self.wrap = wrap
    }

    /// The page `step` away from the current one, or nil at an end without
    /// `wrap`, or when the current view is not a page.
    public func neighbor(_ step: Int) -> String? {
        guard let index, items.count > 1 else { return nil }
        let target = index + step
        if (0..<items.count).contains(target) { return items[target].name }
        guard wrap else { return nil }
        return items[((target % items.count) + items.count) % items.count].name
    }
}

// MARK: - Swipe

/// A two-finger horizontal swipe on a trackpad, as a pure state machine the
/// UIs share. They feed it the finger movement and the gesture's phase; it
/// answers with what to draw or do.
///
/// Deltas are finger movement: positive when the fingers move right, which
/// drags the page right and reveals the previous one.
public struct PageSwipe: Sendable {
    public enum Phase: Sendable { case began, changed, ended, cancelled }

    public enum Output: Equatable, Sendable {
        /// Not a page swipe (vertical, or too little motion yet): the event
        /// belongs to whatever else scrolls.
        case passThrough
        /// Move the current page to this offset (points, positive: right).
        case drag(offset: Double)
        /// Go to the next (+1) or previous (-1) page.
        case commit(direction: Int)
        /// Spring back to rest.
        case cancel
    }

    /// Horizontal motion must beat vertical motion by this factor.
    public static let dominance = 1.5
    /// Motion (points) before a gesture is judged horizontal or not.
    public static let lockDistance = 6.0
    /// The page follows the finger up to this fraction of the width.
    public static let maxOffsetFraction = 0.2
    /// A release past this fraction of the width commits.
    public static let commitFraction = 0.12
    /// A release faster than this (points per second), after at least
    /// `flickDistance`, commits.
    public static let flickVelocity = 500.0
    public static let flickDistance = 24.0

    public var width: Double
    public var canGoPrevious: Bool
    public var canGoNext: Bool

    private enum Lock { case undecided, horizontal, vertical, finished }
    private var lock = Lock.finished
    private var x = 0.0
    private var y = 0.0
    private var samples: [(time: Double, x: Double)] = []

    public init(width: Double, canGoPrevious: Bool, canGoNext: Bool) {
        self.width = width
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
    }

    /// Whether the gesture is being treated as a page swipe.
    public var isDragging: Bool { lock == .horizontal }

    /// The page offset for `total` finger travel: resistance that grows to
    /// `maxOffsetFraction` of the width, and a stiffer pull where there is no
    /// page to go to.
    public func offset(for total: Double) -> Double {
        let limit = width * Self.maxOffsetFraction
        let available = total < 0 ? canGoNext : canGoPrevious
        let reach = limit * (available ? 1 : 0.35)
        return (total < 0 ? -1 : 1) * reach * tanh(abs(total) / max(width * 0.45, 1))
    }

    public mutating func handle(dx: Double, dy: Double, phase: Phase, time: Double) -> Output {
        switch phase {
        case .began:
            lock = .undecided
            x = 0
            y = 0
            samples = []
            return move(dx: dx, dy: dy, time: time)
        case .changed:
            if lock == .finished { return .passThrough }
            return move(dx: dx, dy: dy, time: time)
        case .cancelled:
            defer { lock = .finished }
            return lock == .horizontal ? .cancel : .passThrough
        case .ended:
            let result = release()
            lock = .finished
            return result
        }
    }

    private mutating func move(dx: Double, dy: Double, time: Double) -> Output {
        x += dx
        y += dy
        switch lock {
        case .undecided:
            guard abs(x) + abs(y) >= Self.lockDistance else { return .passThrough }
            lock = abs(x) > Self.dominance * abs(y) ? .horizontal : .vertical
            guard lock == .horizontal else { return .passThrough }
            samples = [(time, x)]
            return .drag(offset: offset(for: x))
        case .horizontal:
            samples.append((time, x))
            if samples.count > 8 { samples.removeFirst() }
            return .drag(offset: offset(for: x))
        default:
            return .passThrough
        }
    }

    private func release() -> Output {
        guard lock == .horizontal else { return .passThrough }
        let direction = x < 0 ? 1 : -1
        let available = direction > 0 ? canGoNext : canGoPrevious
        guard available else { return .cancel }
        if abs(x) > width * Self.commitFraction { return .commit(direction: direction) }
        // Velocity over the last ~100 ms of movement.
        if let last = samples.last, let first = samples.first(where: { last.time - $0.time <= 0.1 }), last.time > first.time {
            let velocity = (last.x - first.x) / (last.time - first.time)
            if abs(x) >= Self.flickDistance, abs(velocity) > Self.flickVelocity, (velocity < 0) == (direction > 0) {
                return .commit(direction: direction)
            }
        }
        return .cancel
    }
}

// MARK: - Motion

public enum PageMotion {
    /// Seconds for a slide.
    public static let slideDuration = 0.25
    /// Seconds for a crossfade.
    public static let fadeDuration = 0.18

    /// What a UI draws for a change of view: `slide`, `fade` or `none`.
    /// A slide becomes a fade under reduced motion, and a change with no
    /// direction (a jump to a view that is not a page) fades.
    public static func kind(transition: String, direction: Int?, reduceMotion: Bool) -> String {
        switch transition {
        case "none": return "none"
        case "fade": return "fade"
        default: return reduceMotion || (direction ?? 0) == 0 ? "fade" : "slide"
        }
    }
}
