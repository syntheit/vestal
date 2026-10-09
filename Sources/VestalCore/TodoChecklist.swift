import Foundation

// MARK: - Markdown checklists
//
// The `checklist` parse mode of the `file` source and the `toggleTodo`
// action. The parser reads task-list items (`- [ ] text`, `- [x] text`;
// also `*`, `+` and `1.` markers) with the headings above them; the action
// ticks one item off by changing one byte of the file.
//
// Writing a file is the one thing here that changes the user's data, so
// `Toggle` is deliberately narrow:
//   - it only turns `[ ]` into `[x]`, on the line it was given;
//   - it refuses unless the file still has the bytes the dashboard read
//     (size and SHA-256 compared), and the line still holds the same item;
//   - every other byte of the file stays as it was, line endings and the
//     rest of the line included;
//   - the new content is written to a temporary file in the same directory,
//     the original's permissions are copied to it, the original is checked
//     once more, and only then is the temporary file renamed over it, so a
//     reader sees the old file or the new one, never half of one;
//   - a symbolic link is followed: the file it points to is replaced, the
//     link stays.

public enum TodoChecklist {
    /// Past this size the file is not read (the file source's own limit).
    public static let maxBytes = 10 * 1024 * 1024

    /// One task-list line.
    struct Item: Equatable {
        /// Index in the line of the byte between the brackets.
        var mark: Int
        var done: Bool
        var text: String
        var indent: Int
    }

    // MARK: Parsing

    /// The line as a task-list item, or nil. `bytes` is the line without
    /// its newline (a carriage return may end it).
    static func item(in bytes: ArraySlice<UInt8>) -> Item? {
        let start = bytes.startIndex
        var i = start
        let space: Set<UInt8> = [0x20, 0x09]
        while i < bytes.endIndex, space.contains(bytes[i]) { i += 1 }
        let indent = i - start
        // Marker: - * + or digits followed by . or ).
        guard i < bytes.endIndex else { return nil }
        if bytes[i] == 0x2D || bytes[i] == 0x2A || bytes[i] == 0x2B {
            i += 1
        } else if (0x30...0x39).contains(bytes[i]) {
            var digits = 0
            while i < bytes.endIndex, (0x30...0x39).contains(bytes[i]), digits < 9 { i += 1; digits += 1 }
            guard i < bytes.endIndex, bytes[i] == 0x2E || bytes[i] == 0x29 else { return nil }
            i += 1
        } else {
            return nil
        }
        let gap = i
        while i < bytes.endIndex, space.contains(bytes[i]) { i += 1 }
        guard i > gap, i + 2 < bytes.endIndex, bytes[i] == 0x5B, bytes[i + 2] == 0x5D else { return nil }
        let markByte = bytes[i + 1]
        guard markByte == 0x20 || markByte == 0x78 || markByte == 0x58 else { return nil }
        let after = i + 3
        // A space (or the end of the line) must follow the bracket.
        guard after >= bytes.endIndex || space.contains(bytes[after]) || bytes[after] == 0x0D else { return nil }
        var end = bytes.endIndex
        if end > after, bytes[end - 1] == 0x0D { end -= 1 }
        let text = String(decoding: bytes[min(after, end)..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return Item(mark: i + 1 - start, done: markByte != 0x20, text: text, indent: indent)
    }

    /// A heading line (`## Today`): its level and text.
    static func heading(in bytes: ArraySlice<UInt8>) -> (level: Int, text: String)? {
        var i = bytes.startIndex
        var spaces = 0
        while i < bytes.endIndex, bytes[i] == 0x20, spaces < 3 { i += 1; spaces += 1 }
        var level = 0
        while i < bytes.endIndex, bytes[i] == 0x23 { i += 1; level += 1 }
        guard (1...6).contains(level), i < bytes.endIndex, bytes[i] == 0x20 || bytes[i] == 0x09 else { return nil }
        var text = String(decoding: bytes[i...], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Closing hashes: `## Today ##`.
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return (level, text)
    }

    /// The `checklist` data: `{path, size, hash, modified, items}`, each item
    /// `{line, text, done, indent, section, sections}`. `line` counts from 1;
    /// `section` is the nearest heading above the item and `sections` all of
    /// the headings it sits under, outermost first. Items inside fenced code
    /// blocks are skipped.
    public static func shape(_ data: Data, path: String, modified: Date?) -> AnyJSON {
        let bytes = [UInt8](data)
        var items: [AnyJSON] = []
        var headings: [(level: Int, text: String)] = []
        var fence: UInt8?
        for (index, range) in lineRanges(bytes).enumerated() {
            let lineNumber = index + 1
            let line = bytes[range]
            if let marker = fenceMarker(in: line) {
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                continue
            }
            if fence != nil { continue }
            if let heading = heading(in: line) {
                headings.removeAll { $0.level >= heading.level }
                headings.append(heading)
                continue
            }
            guard let item = item(in: line) else { continue }
            items.append(.object([
                "line": .int(lineNumber),
                "text": .string(item.text),
                "done": .bool(item.done),
                "indent": .int(item.indent),
                "section": headings.last.map { .string($0.text) } ?? .null,
                "sections": .array(headings.map { .string($0.text) }),
            ]))
        }
        return .object([
            "path": .string(path),
            "size": .int(bytes.count),
            "hash": .string(hash(data)),
            "modified": modified.map { .int(Int($0.timeIntervalSince1970)) } ?? .null,
            "items": .array(items),
        ])
    }

    /// The byte range of each line, without its newline. A final line
    /// without a newline counts; the empty text after the last newline does not.
    static func lineRanges(_ bytes: [UInt8]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            ranges.append(start..<index)
            start = index + 1
        }
        if start < bytes.count { ranges.append(start..<bytes.count) }
        return ranges
    }

    /// ``` or ~~~ opening or closing a fenced block.
    private static func fenceMarker(in line: ArraySlice<UInt8>) -> UInt8? {
        var i = line.startIndex
        var spaces = 0
        while i < line.endIndex, line[i] == 0x20, spaces < 3 { i += 1; spaces += 1 }
        guard i + 3 <= line.endIndex else { return nil }
        let first = line[i]
        guard first == 0x60 || first == 0x7E, line[i + 1] == first, line[i + 2] == first else { return nil }
        return first
    }

    /// SHA-256 of the bytes, in hex.
    public static func hash(_ data: Data) -> String {
        SHA256.digest(data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Ticking an item off

    public struct ToggleError: Error, Equatable, CustomStringConvertible {
        public var description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    /// Turns the open item on `line` of the file at `path` into a done one.
    /// `hash` is the file's hash as the dashboard read it, `match` the item's
    /// text. Throws `ToggleError` (and writes nothing) when the file is not
    /// what was read, the line is not that open item, or the file can't be
    /// replaced.
    public static func toggle(path: String, line: Int, match: String, hash expected: String,
                              home: String = NSHomeDirectory()) throws {
        let expanded = CommandRunner.expandTilde(path, home: home)
        // Replace the file a link points to, not the link.
        let target = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        let original = try read(target)
        guard hash(original) == expected else {
            throw ToggleError("\((target as NSString).lastPathComponent) changed since it was read; nothing was ticked")
        }
        let bytes = [UInt8](original)
        let ranges = lineRanges(bytes)
        guard line >= 1, line <= ranges.count else { throw ToggleError("the file has no line \(line)") }
        let range = ranges[line - 1]
        guard let found = item(in: bytes[range]) else { throw ToggleError("line \(line) is not a task") }
        guard !found.done else { throw ToggleError("line \(line) is already ticked") }
        guard found.text == match.trimmingCharacters(in: .whitespaces) else {
            throw ToggleError("line \(line) is not \"\(match)\" any more; nothing was ticked")
        }
        var changed = original
        changed[changed.startIndex + range.lowerBound + found.mark] = 0x78
        try replace(target, with: changed, expecting: expected)
    }

    private static func read(_ path: String) throws -> Data {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard attributes != nil else { throw ToggleError("no such file: \(path)") }
        if let size = (attributes?[.size] as? NSNumber)?.intValue, size > maxBytes {
            throw ToggleError("\(path) is larger than 10 MiB")
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { throw ToggleError("can't read \(path)") }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1) else { throw ToggleError("can't read \(path)") }
        if data.count > maxBytes { throw ToggleError("\(path) is larger than 10 MiB") }
        return data
    }

    /// Writes `data` next to `path` and renames it over `path`, after
    /// checking once more that `path` still has the hash `expected`.
    private static func replace(_ path: String, with data: Data, expecting expected: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let temporary = "\(directory)/.\(name).vestal-\(getpid())-\(UInt32.random(in: 0...UInt32.max))"
        let manager = FileManager.default
        let permissions = (try? manager.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber
        guard manager.createFile(atPath: temporary, contents: nil, attributes: [.posixPermissions: NSNumber(value: 0o600)]),
              let handle = FileHandle(forWritingAtPath: temporary) else {
            throw ToggleError("can't write next to \(name)")
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            if let permissions { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary) }
            // The last look before the swap.
            guard hash(try read(path)) == expected else {
                throw ToggleError("\(name) changed since it was read; nothing was ticked")
            }
            guard rename(temporary, path) == 0 else {
                throw ToggleError("can't replace \(name): \(String(cString: strerror(errno)))")
            }
        } catch {
            try? handle.close()
            try? manager.removeItem(atPath: temporary)
            throw error as? ToggleError ?? ToggleError("can't write \(name): \(error.localizedDescription)")
        }
    }
}
