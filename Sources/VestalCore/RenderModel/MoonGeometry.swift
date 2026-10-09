import Foundation

// MARK: - Moon phase: shared geometry
//
// The `moon` node is drawn by each UI from this outline, so the three UIs
// agree on which side is lit and how far the terminator bulges. Nothing here
// draws.

public enum MoonGeometry {
    /// The disc's radius in a square of `size`: a point inside the box.
    public static func radius(size: Double) -> Double { size / 2 - 1 }

    /// Whether the right side is lit: waxing, `phase` 0 through 0.5. The
    /// phase is seen from the northern hemisphere.
    public static func litOnRight(phase: Double) -> Bool { phase <= 0.5 }

    /// The lit part of the disc as a closed polygon in a `size` square (y
    /// down): the lit half of the rim from top to bottom, then the terminator
    /// back up, a half ellipse as wide as `|cos(2π phase)|` of the radius,
    /// bulging into the lit side for a crescent and into the dark one for a
    /// gibbous moon. A new moon has no area and a full moon is the disc.
    public static func litOutline(phase: Double, size: Double, segments: Int = 48) -> [(x: Double, y: Double)] {
        let p = phase - phase.rounded(.down)
        let r = radius(size: size), c = size / 2
        let direction = litOnRight(phase: p) ? 1.0 : -1.0
        let bulge = cos(2 * .pi * p)
        let n = max(segments, 4)
        var points: [(x: Double, y: Double)] = []
        for i in 0...n {
            let a = Double.pi * Double(i) / Double(n)
            points.append((c + direction * r * sin(a), c - r * cos(a)))
        }
        for i in 0...n {
            let a = Double.pi * Double(n - i) / Double(n)
            points.append((c + direction * r * bulge * sin(a), c - r * cos(a)))
        }
        return points
    }

    /// The name of the phase, as the `astro` source words it.
    public static func name(phase: Double) -> String {
        let p = phase - phase.rounded(.down)
        return Astro.phaseNames[Int((p * 8).rounded()) % 8]
    }
}
