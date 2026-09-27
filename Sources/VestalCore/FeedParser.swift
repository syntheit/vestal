import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// MARK: - Feed parser
//
// `parse: "feed"`: RSS 2.0 (and RSS 1.0/RDF), Atom 1.0 and JSON Feed 1.x,
// normalised to one shape (docs/EXTENSIBILITY.md 5.4):
//
//     { "title": …, "url": …, "items": [ { "id", "title", "url", "date",
//       "author", "summary" } ] }
//
// Every item has all six keys; what the feed doesn't say is `null`. `date` is
// epoch seconds. `summary` is plain text (see `plainText`), at most
// `maxSummary` characters. Items keep the feed's order, up to `maxItems`.
//
// XML goes through Foundation's `XMLParser` into a small element tree, with
// namespace processing off: elements are matched by local name ("dc:creator"
// is "creator"), preferring an unprefixed element where two share a local
// name (an RSS `link` next to an `atom:link`). Dates are parsed by hand, not
// with DateFormatter, so the result is the same on every platform and locale.

public enum FeedParser {
    /// The first 500 items.
    public static let maxItems = 500
    /// Longest `summary`, in characters.
    public static let maxSummary = 500

    /// RSS 2.0, Atom 1.0 or JSON Feed 1.1 → the feed shape. Throws SourceError.
    public static func parse(_ data: Data) throws -> AnyJSON {
        var body = data
        if body.starts(with: [0xEF, 0xBB, 0xBF]) { body = Data(body.dropFirst(3)) }
        guard let first = body.first(where: { !isASCIIWhitespace($0) }) else {
            throw SourceError("not a feed: the document is empty")
        }
        switch first {
        case UInt8(ascii: "{"):
            return try parseJSONFeed(body)
        case UInt8(ascii: "<"):
            if looksLikeHTML(body) { throw SourceError("not a feed: got an HTML page") }
            return try parseXML(body)
        default:
            throw SourceError("not a feed: neither XML nor JSON")
        }
    }

    /// HTML → plain text as `summary` uses it (tags stripped, entities decoded, whitespace collapsed); not truncated.
    public static func plainText(_ html: String) -> String {
        collapse(decodeEntities(stripTags(html)))
    }

    // MARK: Shape

    struct Item {
        var id: String?
        var title: String?
        var url: String?
        var date: Int?
        var author: String?
        var summary: String?

        var json: AnyJSON {
            .object([
                "id": id.map(AnyJSON.string) ?? .null,
                "title": title.map(AnyJSON.string) ?? .null,
                "url": url.map(AnyJSON.string) ?? .null,
                "date": date.map(AnyJSON.int) ?? .null,
                "author": author.map(AnyJSON.string) ?? .null,
                "summary": summary.map(AnyJSON.string) ?? .null,
            ])
        }
    }

    static func feed(title: String?, url: String?, items: [Item]) -> AnyJSON {
        .object([
            "title": title.map(AnyJSON.string) ?? .null,
            "url": url.map(AnyJSON.string) ?? .null,
            "items": .array(items.prefix(maxItems).map(\.json)),
        ])
    }

    /// Plain text cut to `maxSummary` characters, ending in "…" when cut;
    /// nil when empty.
    static func summary(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        guard text.count > maxSummary else { return text }
        var cut = String(text.prefix(maxSummary - 1))
        while cut.last?.isWhitespace == true { cut.removeLast() }
        return cut + "…"
    }

    /// Nil for a missing or blank string, else the string trimmed.
    static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    // MARK: JSON Feed

    static func parseJSONFeed(_ data: Data) throws -> AnyJSON {
        guard case .success(let json) = AnyJSON.parse(data), let root = json.objectValue else {
            throw SourceError("not a feed: malformed JSON")
        }
        let version = root["version"]?.stringValue ?? ""
        guard version.contains("jsonfeed.org") || root["items"]?.arrayValue != nil else {
            throw SourceError("not a feed: JSON without a JSON Feed \"version\" or \"items\"")
        }

        func string(_ value: AnyJSON?) -> String? {
            switch value {
            case .string(let s)?: return s
            case .int(let i)?: return String(i)
            case .double(let d)?: return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
            default: return nil
            }
        }
        func authorName(_ object: [String: AnyJSON]) -> String? {
            if let first = object["authors"]?.arrayValue?.first?.objectValue,
               let name = nonEmpty(first["name"]?.stringValue) {
                return name
            }
            return nonEmpty(object["author"]?.objectValue?["name"]?.stringValue)
        }

        let feedAuthor = authorName(root)
        var items: [Item] = []
        for value in (root["items"]?.arrayValue ?? []).prefix(maxItems) {
            guard let entry = value.objectValue else { continue }
            var item = Item()
            item.url = nonEmpty(entry["url"]?.stringValue) ?? nonEmpty(entry["external_url"]?.stringValue)
            item.id = nonEmpty(string(entry["id"])) ?? item.url
            item.title = (entry["title"]?.stringValue).map(collapse)
            item.date = (entry["date_published"]?.stringValue).flatMap(FeedDate.rfc3339)
                ?? (entry["date_modified"]?.stringValue).flatMap(FeedDate.rfc3339)
            item.author = authorName(entry) ?? feedAuthor
            if let text = nonEmpty(entry["summary"]?.stringValue) ?? nonEmpty(entry["content_text"]?.stringValue) {
                item.summary = summary(collapse(text))
            } else if let html = entry["content_html"]?.stringValue {
                item.summary = summary(plainText(html))
            }
            items.append(item)
        }
        return feed(title: (root["title"]?.stringValue).map(collapse),
                    url: nonEmpty(root["home_page_url"]?.stringValue),
                    items: items)
    }

    // MARK: XML

    static func parseXML(_ data: Data) throws -> AnyJSON {
        let builder = TreeBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        let ok = parser.parse()
        if let problem = builder.rejected { throw SourceError("not a feed: \(problem)") }
        guard ok, let root = builder.root else {
            throw SourceError("not a feed: malformed XML (line \(parser.lineNumber))")
        }
        switch root.local {
        case "rss": return rss(root)
        case "RDF": return rdf(root)
        default: return atom(root)
        }
    }

    /// RSS 0.9x and 2.0: `rss > channel > item`.
    static func rss(_ root: Element) -> AnyJSON {
        let channel = root.child("channel") ?? root
        return feed(title: (channel.child("title")?.text).map(collapse),
                    url: channel.linkText,
                    items: channel.children("item").prefix(maxItems).map(rssItem))
    }

    /// RSS 1.0: `rdf:RDF > channel` and `rdf:RDF > item`, siblings.
    static func rdf(_ root: Element) -> AnyJSON {
        let channel = root.child("channel")
        return feed(title: (channel?.child("title")?.text).map(collapse),
                    url: channel?.linkText,
                    items: root.children("item").prefix(maxItems).map(rssItem))
    }

    static func rssItem(_ element: Element) -> Item {
        var item = Item()
        item.title = (element.child("title")?.text).map(collapse)
        item.url = element.linkText
        item.id = nonEmpty(element.child("guid")?.text) ?? nonEmpty(element.attribute("about")) ?? item.url
        item.date = (element.child("pubDate")?.text).flatMap(FeedDate.rfc822)
            ?? (element.child("date")?.text).flatMap(FeedDate.rfc3339)
        item.author = nonEmpty(element.child("author")?.text) ?? nonEmpty(element.child("creator")?.text)
        if let description = nonEmpty(element.child("description")?.text) ?? nonEmpty(element.child("encoded")?.text) {
            item.summary = summary(plainText(description))
        }
        return item
    }

    /// Atom 1.0: `feed > entry`. An entry without its own author inherits
    /// the feed's (RFC 4287 4.2.1).
    static func atom(_ root: Element) -> AnyJSON {
        let feedAuthor = nonEmpty(root.child("author")?.child("name")?.text)
        let items = root.children("entry").prefix(maxItems).map { entry -> Item in
            var item = Item()
            item.title = entry.child("title").map(atomText)
            item.url = entry.alternateHref
            item.id = nonEmpty(entry.child("id")?.text) ?? item.url
            item.date = (entry.child("published")?.text).flatMap(FeedDate.rfc3339)
                ?? (entry.child("updated")?.text).flatMap(FeedDate.rfc3339)
            item.author = nonEmpty(entry.child("author")?.child("name")?.text) ?? feedAuthor
            let text = entry.child("summary").map(atomText) ?? ""
            item.summary = summary(text.isEmpty ? entry.child("content").map(atomText) ?? "" : text)
            return item
        }
        return feed(title: root.child("title").map(atomText), url: root.alternateHref, items: Array(items))
    }

    /// An Atom text construct as plain text, by its `type`: `text` (the
    /// default), `html` (escaped markup) or `xhtml` (inline elements).
    static func atomText(_ element: Element) -> String {
        switch element.attribute("type")?.lowercased() {
        case "html", "text/html":
            return plainText(element.text)
        case "xhtml", "application/xhtml+xml":
            return plainText(element.markup)
        default:
            return collapse(element.text)
        }
    }

    static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    /// An HTML page rather than XML: `<!doctype html` or `<html` before any
    /// other element, ignoring case.
    static func looksLikeHTML(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(1024), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }

    // MARK: XML tree

    /// An element with its attributes and content, names as written in the
    /// document ("dc:creator").
    final class Element {
        enum Node {
            case element(Element)
            case text(String)
        }

        let name: String
        let attributes: [String: String]
        var nodes: [Node] = []

        init(name: String, attributes: [String: String]) {
            self.name = name
            self.attributes = attributes
        }

        /// The name without its prefix.
        var local: String { Self.localName(name) }

        var isPrefixed: Bool { name.contains(":") }

        static func localName(_ name: String) -> String {
            guard let colon = name.lastIndex(of: ":") else { return name }
            return String(name[name.index(after: colon)...])
        }

        /// Child elements with local name `local`, in order.
        func children(_ local: String) -> [Element] {
            nodes.compactMap {
                if case .element(let e) = $0, e.local == local { return e }
                return nil
            }
        }

        /// The first unprefixed child named `local`, else the first prefixed one.
        func child(_ local: String) -> Element? {
            let all = children(local)
            return all.first(where: { !$0.isPrefixed }) ?? all.first
        }

        /// An attribute by local name.
        func attribute(_ local: String) -> String? {
            if let value = attributes[local] { return value }
            return attributes.first(where: { Self.localName($0.key) == local })?.value
        }

        /// All text inside, CDATA included, untrimmed.
        var text: String {
            var out = ""
            appendText(to: &out)
            return out
        }

        private func appendText(to out: inout String) {
            for node in nodes {
                switch node {
                case .text(let s): out += s
                case .element(let e): e.appendText(to: &out)
                }
            }
        }

        /// The content re-serialised as markup, for Atom `xhtml` text.
        var markup: String {
            var out = ""
            for node in nodes {
                switch node {
                case .text(let s):
                    out += s.replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
                case .element(let e):
                    out += "<\(e.local)>\(e.markup)</\(e.local)>"
                }
            }
            return out
        }

        /// RSS `link`: the first one with text, which skips an `atom:link`.
        var linkText: String? {
            let links = children("link")
            for link in links.filter({ !$0.isPrefixed }) + links.filter(\.isPrefixed) {
                if let url = FeedParser.nonEmpty(link.text) { return url }
            }
            return nil
        }

        /// Atom `link`: the first `rel="alternate"` or rel-less `href`.
        var alternateHref: String? {
            for link in children("link") {
                let rel = link.attribute("rel") ?? "alternate"
                if rel == "alternate", let href = FeedParser.nonEmpty(link.attribute("href")) { return href }
            }
            return nil
        }
    }

    /// Builds the element tree. Rejects the document at its root element
    /// unless that is `rss`, `feed` or `rdf:RDF`.
    final class TreeBuilder: NSObject, XMLParserDelegate {
        var root: Element?
        var rejected: String?
        private var stack: [Element] = []
        /// Text since the last tag. libxml2 hands it over in many small
        /// pieces (one per entity reference), so it is joined here once.
        private var pending = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            flush()
            let element = Element(name: elementName, attributes: attributeDict)
            if let parent = stack.last {
                parent.nodes.append(.element(element))
            } else if root == nil {
                guard ["rss", "feed", "RDF"].contains(element.local) else {
                    rejected = "the root element is <\(elementName)>, not <rss>, <feed> or <rdf:RDF>"
                    parser.abortParsing()
                    return
                }
                root = element
            }
            stack.append(element)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            flush()
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            pending += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            pending += String(decoding: CDATABlock, as: UTF8.self)
        }

        private func flush() {
            guard !pending.isEmpty else { return }
            stack.last?.nodes.append(.text(pending))
            pending = ""
        }
    }

    // MARK: HTML to text

    /// Elements that break a line, so their tags become a space: "<p>a</p><p>b</p>"
    /// reads "a b", while "<b>a</b>b" stays "ab".
    static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt", "figcaption",
        "figure", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "img", "li", "main",
        "nav", "ol", "p", "pre", "section", "table", "td", "th", "tr", "ul",
    ]

    /// Markup removed: tags, comments, and the contents of `script` and
    /// `style`. A "<" not followed by a letter, "/", "!" or "?" is text.
    static func stripTags(_ html: String) -> String {
        let scalars = Array(html.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        let n = scalars.count

        func startsWith(_ s: String, at index: Int) -> Bool {
            var j = index
            for c in s.unicodeScalars {
                guard j < n, Self.lower(scalars[j]) == c else { return false }
                j += 1
            }
            return true
        }
        func find(_ s: String, from index: Int) -> Int? {
            var j = index
            while j < n {
                if startsWith(s, at: j) { return j }
                j += 1
            }
            return nil
        }

        while i < n {
            let c = scalars[i]
            guard c == "<", i + 1 < n else { out.append(c); i += 1; continue }
            let next = scalars[i + 1]
            let isTag = next == "/" || next == "!" || next == "?"
                || (next.isASCII && CharacterSet.letters.contains(next))
            guard isTag else { out.append(c); i += 1; continue }

            if startsWith("<!--", at: i) {
                i = find("-->", from: i + 4).map { $0 + 3 } ?? n
                continue
            }

            // Tag name, for block elements and script/style.
            var j = i + 1
            let closing = scalars[j] == "/"
            if closing { j += 1 }
            var name = ""
            while j < n, scalars[j].isASCII, CharacterSet.alphanumerics.contains(scalars[j]) {
                name.unicodeScalars.append(Self.lower(scalars[j]))
                j += 1
            }
            // End of the tag, skipping ">" inside quoted attribute values.
            var quote: Unicode.Scalar?
            while j < n {
                let s = scalars[j]
                if let q = quote {
                    if s == q { quote = nil }
                } else if s == "\"" || s == "'" {
                    quote = s
                } else if s == ">" {
                    break
                }
                j += 1
            }
            i = j + 1

            if !closing, name == "script" || name == "style" {
                i = find("</\(name)", from: i).flatMap { end in find(">", from: end) }.map { $0 + 1 } ?? n
                continue
            }
            if blockElements.contains(name) { out.append(" ") }
        }
        return String(out)
    }

    static func lower(_ s: Unicode.Scalar) -> Unicode.Scalar {
        (s.value >= 0x41 && s.value <= 0x5A) ? Unicode.Scalar(s.value + 0x20)! : s
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
        "rdquo": "”", "laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "copy": "©",
        "reg": "®", "trade": "™", "euro": "€", "deg": "°", "times": "×",
    ]

    /// Named (a common set) and numeric character references decoded; an
    /// unknown or malformed one is left as it is. `&nbsp;` becomes a space.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semicolon = after.prefix(32).firstIndex(of: ";"),
               let decoded = decodeEntity(after[..<semicolon]) {
                out += decoded
                rest = after[after.index(after: semicolon)...]
            } else {
                out += "&"
                rest = after
            }
        }
        out += rest
        return out
    }

    static func decodeEntity(_ name: Substring) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.first == "x" || digits.first == "X" {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
            return scalar == "\u{A0}" ? " " : String(Character(scalar))
        }
        return namedEntities[String(name)]
    }
}

// MARK: - Dates

extension FeedParser {
/// Feed timestamps to epoch seconds, parsed by hand so no locale or
/// platform formatter is involved.
enum FeedDate {
    /// RFC 822 / RFC 2822, as RSS `pubDate` uses it: "Sat, 07 Sep 2002
    /// 00:00:01 GMT". The weekday and seconds are optional; a two-digit year
    /// is 19xx from 50 up, else 20xx; the zone is a numeric offset ("+0100",
    /// "-05:00"), a named zone (GMT, UT, EST, PDT, …) or missing (UTC). An
    /// unknown named zone counts as UTC (RFC 2822 4.3). Falls back to
    /// RFC 3339, which some feeds use in `pubDate`.
    static func rfc822(_ string: String) -> Int? {
        var tokens = string
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
        guard !tokens.isEmpty else { return nil }
        tokens.removeAll(where: { $0.hasPrefix("(") })  // "(UTC)" comments
        if let first = tokens.first, first.first?.isLetter == true, month(first) == nil {
            tokens.removeFirst()  // weekday
        }
        guard tokens.count >= 4 else { return rfc3339(string) }

        var day: Int?
        var monthNumber: Int?
        if let d = Int(tokens[0]), let m = month(tokens[1]) {
            day = d; monthNumber = m          // 07 Sep 2002
        } else if let m = month(tokens[0]), let d = Int(tokens[1]) {
            day = d; monthNumber = m          // Sep 07 2002
        }
        guard let day, let monthNumber, var year = Int(tokens[2]) else { return rfc3339(string) }
        if tokens[2].count <= 2 {
            year += year >= 50 ? 1900 : 2000
        } else if tokens[2].count == 3 {
            year += 1900
        }

        let clock = tokens[3].split(separator: ":").map { Int($0) }
        guard clock.count == 2 || clock.count == 3, clock.allSatisfy({ $0 != nil }) else { return nil }
        let hour = clock[0]!, minute = clock[1]!, second = clock.count == 3 ? clock[2]! : 0

        let offset = tokens.count > 4 ? zoneOffset(tokens[4]) : 0
        guard let offset else { return nil }
        return epoch(year: year, month: monthNumber, day: day, hour: hour, minute: minute, second: second,
                     offset: offset)
    }

    /// RFC 3339 / ISO 8601, as Atom and JSON Feed use it:
    /// "2003-12-13T18:30:02.25+01:00", "…Z", a space or lowercase "t" for
    /// the "T", seconds and fraction optional, a missing zone read as UTC,
    /// and a bare date as midnight UTC. Fractions are dropped.
    static func rfc3339(_ string: String) -> Int? {
        let s = Array(string.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var i = 0
        func number(_ width: Int) -> Int? {
            guard i + width <= s.count else { return nil }
            var value = 0
            for byte in s[i..<(i + width)] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            i += width
            return value
        }
        func skip(_ c: Character) -> Bool {
            guard i < s.count, s[i] == c.asciiValue else { return false }
            i += 1
            return true
        }

        guard let year = number(4), skip("-"), let month = number(2), skip("-"), let day = number(2) else {
            return nil
        }
        guard i < s.count else {
            return epoch(year: year, month: month, day: day, hour: 0, minute: 0, second: 0, offset: 0)
        }
        guard skip("T") || skip("t") || skip(" "), let hour = number(2), skip(":"), let minute = number(2) else {
            return nil
        }
        var second = 0
        if skip(":") {
            guard let value = number(2) else { return nil }
            second = value
            if skip(".") || skip(",") {
                while i < s.count, s[i] >= 0x30, s[i] <= 0x39 { i += 1 }
            }
        }
        var offset = 0
        if i < s.count {
            guard let zone = zoneOffset(String(decoding: s[i...], as: UTF8.self)) else { return nil }
            offset = zone
        }
        return epoch(year: year, month: month, day: day, hour: hour, minute: minute, second: second, offset: offset)
    }

    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// 1-12 for a month name or its first three letters, any case.
    static func month(_ token: String) -> Int? {
        let lower = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard lower.count >= 3 else { return nil }
        return months.firstIndex(of: String(lower.prefix(3))).map { $0 + 1 }
    }

    /// Hours east of UTC for the named zones feeds use.
    static let namedZones: [String: Int] = [
        "UT": 0, "UTC": 0, "GMT": 0, "Z": 0, "WET": 0,
        "EST": -5, "EDT": -4, "CST": -6, "CDT": -5, "MST": -7, "MDT": -6, "PST": -8, "PDT": -7,
        "AKST": -9, "AKDT": -8, "HST": -10,
        "BST": 1, "CET": 1, "CEST": 2, "WEST": 1, "EET": 2, "EEST": 3, "MSK": 3,
        "JST": 9, "KST": 9, "AEST": 10, "AEDT": 11,
    ]

    /// Seconds east of UTC: "Z", "+01:00", "+0100", "+01", or a zone name.
    static func zoneOffset(_ token: String) -> Int? {
        if let sign = token.first, sign == "+" || sign == "-" {
            let digits = token.dropFirst().filter { $0 != ":" }
            guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            let hours: Int, minutes: Int
            switch digits.count {
            case 2: hours = Int(digits)!; minutes = 0
            case 4: hours = Int(digits.prefix(2))!; minutes = Int(digits.suffix(2))!
            default: return nil
            }
            guard minutes < 60 else { return nil }
            return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
        }
        let name = token.uppercased()
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return (namedZones[name] ?? 0) * 3600
    }

    /// Epoch seconds for a civil date and time at `offset` seconds east of
    /// UTC; nil when a field is out of range.
    static func epoch(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int, offset: Int) -> Int? {
        guard (1...12).contains(month), (0...23).contains(hour),
              (0...59).contains(minute), (0...60).contains(second) else { return nil }
        // The month's real length: "2026-02-30" is not a date.
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let length = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        guard (1...length).contains(day) else { return nil }
        // Days from 1970-01-01 (Howard Hinnant's days_from_civil).
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return days * 86400 + hour * 3600 + minute * 60 + second - offset
    }
}

}

// MARK: - Whitespace

extension FeedParser {
    /// Runs of whitespace (newlines and no-break spaces included) as one
    /// space, trimmed.
    static func collapse(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for c in text {
            if c.isWhitespace {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(c)
            }
        }
        return out
    }
}
