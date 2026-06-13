import Foundation

// MARK: - JSON path resolver
//
// Walks a path string like `.nearest_area[0].areaName[0].value` or
// `rates.BRL` against parsed JSON (the Any tree produced by
// JSONSerialization). Supports field access (`.field` or `field` at
// segment start) and array indexing (`[N]`). Empty path returns input.
//
// Used by widget extractors (weather fields, exchange items) so users can
// express data shape in config without code changes.

enum JSONPath {
    enum Segment: Equatable {
        case field(String)
        case index(Int)
    }

    /// Tokenize a path string into segments. Leading "." is optional.
    /// Examples:
    ///   ".nearest_area[0].areaName[0].value"
    ///     → [.field("nearest_area"), .index(0), .field("areaName"), .index(0), .field("value")]
    ///   "rates.BRL"
    ///     → [.field("rates"), .field("BRL")]
    ///   "items[2].name"
    ///     → [.field("items"), .index(2), .field("name")]
    static func tokenize(_ path: String) -> [Segment] {
        var segments: [Segment] = []
        var buffer = ""
        var inBracket = false
        let chars = path.hasPrefix(".") ? path.dropFirst() : path[path.startIndex...]
        for ch in chars {
            switch ch {
            case ".":
                if !buffer.isEmpty {
                    segments.append(.field(buffer))
                    buffer = ""
                }
            case "[":
                if !buffer.isEmpty {
                    segments.append(.field(buffer))
                    buffer = ""
                }
                inBracket = true
            case "]":
                if inBracket, let i = Int(buffer) {
                    segments.append(.index(i))
                }
                buffer = ""
                inBracket = false
            default:
                buffer.append(ch)
            }
        }
        if !buffer.isEmpty {
            segments.append(.field(buffer))
        }
        return segments
    }

    /// Resolve a path against a parsed-JSON root. Returns nil if any segment
    /// fails (missing key, out-of-bounds index, type mismatch).
    static func resolve(_ path: String, in root: Any) -> Any? {
        let segments = tokenize(path)
        if segments.isEmpty { return root }
        var current: Any? = root
        for seg in segments {
            switch seg {
            case .field(let name):
                if let dict = current as? [String: Any] {
                    current = dict[name]
                } else {
                    return nil
                }
            case .index(let i):
                if let arr = current as? [Any] {
                    current = (i >= 0 && i < arr.count) ? arr[i] : nil
                } else {
                    return nil
                }
            }
            if current == nil { return nil }
        }
        return current
    }
}
