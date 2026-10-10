import Foundation

/// `text` padded with trailing spaces to `width` characters (table columns).
func padRight(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}
