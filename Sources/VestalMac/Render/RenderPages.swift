#if os(macOS)
import AppKit
import SwiftUI
import VestalCore

// MARK: - Pages
//
// Paging between views like a phone's home screens: the transition between
// two pages, the dots, and the two-finger swipe. The core owns which page is
// current; this file draws the change and reports swipes back (`page`).

/// A change of page in flight.
struct PageChange: Equatable {
    var serial: Int
    /// The page that was on screen.
    var outgoing: NodeHandle
    /// +1: the new page is later (it comes in from the right); -1: earlier.
    var direction: Int
    /// A slide; otherwise a crossfade.
    var slides: Bool
    /// How far a swipe had already dragged the old page, in points.
    var startOffset: Double
    var duration: Double

    static func == (a: PageChange, b: PageChange) -> Bool { a.serial == b.serial }
}

/// How one layer of the stage moves at `progress` (0: the change begins, 1:
/// it is done).
struct PageLayerMotion {
    var offset: Double
    var opacity: Double

    static let rest = PageLayerMotion(offset: 0, opacity: 1)

    static func outgoing(_ change: PageChange, progress p: Double, width: Double) -> PageLayerMotion {
        if change.slides {
            return PageLayerMotion(offset: change.startOffset * (1 - p) - Double(change.direction) * width * p, opacity: 1)
        }
        return PageLayerMotion(offset: 0, opacity: 1 - p)
    }

    static func incoming(_ change: PageChange, progress p: Double, width: Double) -> PageLayerMotion {
        if change.slides {
            return PageLayerMotion(offset: Double(change.direction) * width * (1 - p), opacity: 1)
        }
        return PageLayerMotion(offset: 0, opacity: p)
    }
}

// MARK: - Dots

/// One dot per page, near the bottom of the screen: the current page in the
/// accent color, the rest dim.
struct PageDots: View {
    let pages: RenderPages
    let style: RenderStyle

    private static let size: CGFloat = 7
    private static let spacing: CGFloat = 10
    private static let bottom: CGFloat = 28

    var body: some View {
        HStack(spacing: Self.spacing) {
            ForEach(Array(pages.items.enumerated()), id: \.offset) { offset, _ in
                Circle()
                    .fill(offset == pages.index ? style.color("accent") : style.color("dim"))
                    .frame(width: Self.size, height: Self.size)
            }
        }
        .animation(.easeOut(duration: 0.2), value: pages.index)
        .padding(.bottom, Self.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .allowsHitTesting(false)
    }
}

extension RenderPages {
    /// Whether the indicator is drawn.
    var showsDots: Bool { indicator == "dots" && items.count > 1 }
}

// MARK: - Swipe

/// Two-finger horizontal swipes on the trackpad, from the app's scroll-wheel
/// monitor. `PageSwipe` (VestalCore) decides what a gesture is; this feeds it
/// the events and moves the page.
@MainActor
final class PageSwipeController {
    private let store: RenderStore
    private var swipe: PageSwipe?
    /// After a horizontal gesture, the inertia events that follow belong to it.
    private var swallowMomentum = false

    init(store: RenderStore) {
        self.store = store
    }

    /// True when the event was a page swipe's and is consumed.
    func handle(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, let pages = store.snapshot?.pages, pages.swipe, pages.index != nil,
              store.pagesLive else { return false }
        if !event.momentumPhase.isEmpty { return swallowMomentum }
        let phase: PageSwipe.Phase
        switch event.phase {
        case .began:
            let width = Double(event.window?.contentView?.bounds.width ?? 0)
            guard width > 0 else { return false }
            swipe = PageSwipe(width: width, canGoPrevious: pages.neighbor(-1) != nil, canGoNext: pages.neighbor(1) != nil)
            swallowMomentum = false
            phase = .began
        case .changed: phase = .changed
        case .ended: phase = .ended
        case .cancelled: phase = .cancelled
        default: return false
        }
        guard var current = swipe else { return false }
        // Finger movement, whichever way the user's scrolling is set.
        let sign = event.isDirectionInvertedFromDevice ? 1.0 : -1.0
        let output = current.handle(dx: Double(event.scrollingDeltaX) * sign, dy: Double(event.scrollingDeltaY) * sign,
                                    phase: phase, time: event.timestamp)
        swipe = (phase == .ended || phase == .cancelled) ? nil : current
        switch output {
        case .passThrough:
            return false
        case .drag(let offset):
            store.dragOffset = offset
            return true
        case .commit(let direction):
            swallowMomentum = true
            store.send(.page(step: direction))
            // Should the core not move (a stale model), the page returns.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [store] in
                if store.pageChange == nil, store.dragOffset != 0 { store.springBack() }
            }
            return true
        case .cancel:
            swallowMomentum = true
            store.springBack()
            return true
        }
    }
}

extension RenderStore {
    /// The dragged page returns to rest.
    func springBack() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dragOffset = 0 }
    }
}
#endif
