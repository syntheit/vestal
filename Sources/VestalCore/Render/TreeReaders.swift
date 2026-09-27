import Foundation

// MARK: - Which sources an expanded widget tree reads
//
// For scheduling (a visible-only source that no widget of the view reads is
// not fetched, EXTENSIBILITY.md §5.1) and `vestal sources`. Static: a
// widget's `source` names, and the source names its expressions spell out
// (`$sources.x`, `$sources["x"]`, `meta("x")`, `$history.x`,
// `history("x"; …)`). `host_health` reads `system` and every `host:<name>`
// source. Popups count once they are open, not here.

public enum TreeReaders {
    /// Source name → the widgets of `view` that read it (`view/widget`,
    /// or `view/<index>` for an inline root child), in view order.
    public static func readers(of tree: AnyJSON, view: String, sourceNames: Set<String>) -> [String: [String]] {
        let top = tree.objectValue ?? [:]
        guard let viewObject = top["views"]?.objectValue?[view]?.objectValue else { return [:] }
        let widgets = top["widgets"]?.objectValue ?? [:]
        let entries = (viewObject["children"] ?? viewObject["order"])?.arrayValue ?? []
        var readers: [String: [String]] = [:]
        for (index, entry) in entries.enumerated() {
            let reader: String
            let widget: AnyJSON?
            if case .string(let key) = entry {
                reader = "\(view)/\(key)"
                widget = widgets[key]
            } else {
                reader = "\(view)/\(index)"
                widget = entry
            }
            guard let widget else { continue }
            var names = Set<String>()
            collect(widget, into: &names, sourceNames: sourceNames)
            for name in names.sorted() where !(readers[name] ?? []).contains(reader) {
                readers[name, default: []].append(reader)
            }
        }
        return readers
    }

    private static let patterns: [NSRegularExpression] = [
        #"\$sources\.([A-Za-z_][A-Za-z0-9_]*)"#,
        #"\$sources\[\s*"([^"]+)"\s*\]"#,
        #"\bmeta\(\s*"([^"]+)"\s*\)"#,
        #"\$history\.([A-Za-z_][A-Za-z0-9_]*)"#,
        #"\$history\[\s*"([^"]+)"\s*\]"#,
        #"\bhistory(?:_times)?\(\s*"([^"]+)"\s*;"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func collect(_ value: AnyJSON, into names: inout Set<String>, sourceNames: Set<String>) {
        switch value {
        case .object(let members):
            for (key, member) in members {
                if key == "popup" { continue }
                if key == "source", case .string(let name) = member { names.insert(name) }
                collect(member, into: &names, sourceNames: sourceNames)
            }
        case .array(let items):
            for item in items { collect(item, into: &names, sourceNames: sourceNames) }
        case .string(let text):
            guard text.contains("$") || text.contains("(") else { return }
            let range = NSRange(text.startIndex..., in: text)
            for pattern in patterns {
                for match in pattern.matches(in: text, range: range) {
                    if let r = Range(match.range(at: 1), in: text) { names.insert(String(text[r])) }
                }
            }
            if text.contains("host_health") {
                names.insert(SourceReaders.system)
                names.formUnion(sourceNames.filter { $0.hasPrefix("host:") })
            }
        default:
            break
        }
    }
}
