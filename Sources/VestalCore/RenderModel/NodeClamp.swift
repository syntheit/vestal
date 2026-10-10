import Foundation

extension RenderNode {
    /// `value` limited to `minimum`/`maximum` (border-box), never negative.
    /// The renderers' per-node specs call this with their own copies of the
    /// limits.
    public static func clamp(_ value: Double, minimum: Double?, maximum: Double?) -> Double {
        var v = value
        if let m = maximum { v = min(v, m) }
        if let m = minimum { v = max(v, m) }
        return max(0, v)
    }

    public func clampWidth(_ w: Double) -> Double {
        RenderNode.clamp(w, minimum: minWidth, maximum: maxWidth)
    }

    public func clampHeight(_ h: Double) -> Double {
        RenderNode.clamp(h, minimum: minHeight, maximum: maxHeight)
    }
}
