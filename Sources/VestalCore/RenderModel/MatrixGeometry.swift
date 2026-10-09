import Foundation

// MARK: - Matrix clock: shared geometry
//
// The `matrix` node is drawn by each UI from these cells: a 5 by 7 dot grid
// per digit, or seven-segment digits, every cell of the panel present and
// the unlit ones faintly visible. The numbers are the approved face's, at a
// height of 84 points; `size` scales them. Nothing here draws.

public enum MatrixGeometry {
    /// The 5 by 7 dot glyphs, by character: seven rows of five 0 or 1.
    public static let glyphs: [Character: [String]] = [
        "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
        "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
        "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
        "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
        "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
        "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
        "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
        "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
        "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
        "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    ]

    /// The lit segments of a seven-segment digit, by character: letters a to g
    /// (top, top right, bottom right, bottom, bottom left, top left, middle).
    public static let segments: [Character: String] = [
        "0": "abcdef", "1": "bc", "2": "abdeg", "3": "abcdg", "4": "bcfg",
        "5": "acdfg", "6": "acdefg", "7": "abc", "8": "abcdefg", "9": "abcdfg",
    ]

    /// The design height of a dot matrix and of a segment digit.
    public static let dotHeight = 84.0
    public static let segmentHeight = 86.0

    public struct Cell: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case dot, polygon, rect }
        public var kind: Kind
        public var lit: Bool
        /// A dot's center and radius, or a rect's origin, size and corner.
        public var x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0, radius: Double = 0
        /// A polygon's corners, x then y.
        public var points: [Double] = []
    }

    public struct Result: Equatable, Sendable {
        public var cells: [Cell]
        public var width: Double
        public var height: Double
    }

    /// The segment polygons of a `w` by `h` digit with stroke `t`, by segment.
    public static func segmentPolygons(width w: Double, height h: Double, thickness t: Double) -> [Character: [Double]] {
        let g = 1.6, l = t / 2, r = w - t / 2, top = t / 2, mid = h / 2, bottom = h - t / 2
        func horizontal(_ y: Double) -> [Double] {
            [l + g, y, l + g + t / 2, y - t / 2, r - g - t / 2, y - t / 2, r - g, y, r - g - t / 2, y + t / 2, l + g + t / 2, y + t / 2]
        }
        func vertical(_ x: Double, _ y0: Double, _ y1: Double) -> [Double] {
            [x, y0 + g, x + t / 2, y0 + g + t / 2, x + t / 2, y1 - g - t / 2, x, y1 - g, x - t / 2, y1 - g - t / 2, x - t / 2, y0 + g + t / 2]
        }
        return ["a": horizontal(top), "g": horizontal(mid), "d": horizontal(bottom),
                "f": vertical(l, top, mid), "b": vertical(r, top, mid), "e": vertical(l, mid, bottom), "c": vertical(r, mid, bottom)]
    }

    /// The cells of `text` (digits, `:`, anything else a blank digit) at `size`
    /// (the height of a dot matrix, as 84 is in the approved face).
    public static func layout(text: String, segments useSegments: Bool, size: Double) -> Result {
        let s = size / dotHeight
        var cells: [Cell] = []
        var x = 0.0
        let tilt = tan(-6.0 * .pi / 180)
        let polygons = segmentPolygons(width: 46, height: 86, thickness: 9)
        let order: [Character] = ["a", "b", "c", "d", "e", "f", "g"]
        let characters = Array(text)
        for ch in characters {
            if ch == ":" {
                if useSegments {
                    cells.append(Cell(kind: .rect, lit: true, x: x + 2 * s, y: 24 * s, width: 9 * s, height: 9 * s, radius: 1.5 * s))
                    cells.append(Cell(kind: .rect, lit: true, x: x, y: 54 * s, width: 9 * s, height: 9 * s, radius: 1.5 * s))
                    x += 22 * s
                } else {
                    cells.append(Cell(kind: .dot, lit: true, x: x + 6 * s, y: 30 * s, width: 8.6 * s, height: 8.6 * s, radius: 4.3 * s))
                    cells.append(Cell(kind: .dot, lit: true, x: x + 6 * s, y: 54 * s, width: 8.6 * s, height: 8.6 * s, radius: 4.3 * s))
                    x += 24 * s
                }
                continue
            }
            if useSegments {
                let on = segments[ch] ?? ""
                for name in order {
                    guard let p = polygons[name] else { continue }
                    var points: [Double] = []
                    var i = 0
                    while i < p.count {
                        let px = p[i] * s, py = p[i + 1] * s
                        points.append(x + 6 * s + px + tilt * py)
                        points.append(py)
                        i += 2
                    }
                    cells.append(Cell(kind: .polygon, lit: on.contains(name), points: points))
                }
                x += 56 * s
            } else {
                let rows = glyphs[ch]
                for row in 0..<7 {
                    for col in 0..<5 {
                        let lit = rows.map { Array($0[row])[col] == "1" } ?? false
                        cells.append(Cell(kind: .dot, lit: lit, x: x + (Double(col) * 12 + 6) * s, y: (Double(row) * 12 + 6) * s,
                                          width: 8.6 * s, height: 8.6 * s, radius: 4.3 * s))
                    }
                }
                x += 72 * s
            }
        }
        let trailing = useSegments ? 10.0 : 12.0
        return Result(cells: cells, width: characters.isEmpty ? 0 : max(0, x - trailing * s),
                      height: (useSegments ? segmentHeight : dotHeight) * s)
    }
}

private extension String {
    subscript(_ i: Int) -> Character { self[index(startIndex, offsetBy: i)] }
}
