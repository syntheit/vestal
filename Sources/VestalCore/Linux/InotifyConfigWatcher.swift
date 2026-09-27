import Dispatch
import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: - Config file watcher (inotify)
//
// The Linux counterpart of VestalMac's DispatchConfigWatcher: one inotify
// descriptor with two watches, on the config file's directory and on the file
// itself. The directory catches Home Manager's switch, which replaces the
// symlink `config.json` (the file it points to, in the Nix store, never
// changes), and editors that save through a temporary file and a rename; it
// only counts events for the config's own name, or for the directory itself
// going away. The file watch follows a symlink, so it catches writes in place
// to a file that lives elsewhere (an out-of-store symlink). Attribute changes
// are left out, as on macOS. `Resident` calls `watch` again after every
// reload, which watches whatever is there now, and debounces (300ms).
//
// If neither the directory nor the file exists, nothing is watched; SIGHUP
// and `vestal reload` still work.
//
// The event decoding and the choice of which events count are portable and
// tested on every platform; the watcher itself is Linux-only.

/// The kernel's inotify ABI (linux/inotify.h), for decoding events anywhere.
public enum Inotify {
    public static let modify: UInt32 = 0x0000_0002
    public static let closeWrite: UInt32 = 0x0000_0008
    public static let movedFrom: UInt32 = 0x0000_0040
    public static let movedTo: UInt32 = 0x0000_0080
    public static let create: UInt32 = 0x0000_0100
    public static let delete: UInt32 = 0x0000_0200
    public static let deleteSelf: UInt32 = 0x0000_0400
    public static let moveSelf: UInt32 = 0x0000_0800
    public static let unmount: UInt32 = 0x0000_2000
    public static let queueOverflow: UInt32 = 0x0000_4000
    public static let ignored: UInt32 = 0x0000_8000
    public static let onlyDirectory: UInt32 = 0x0100_0000

    /// What the directory watch asks for.
    public static let directoryMask: UInt32 =
        modify | closeWrite | movedFrom | movedTo | create | delete | deleteSelf | moveSelf | onlyDirectory
    /// What the file watch asks for.
    public static let fileMask: UInt32 = modify | closeWrite | deleteSelf | moveSelf

    public struct Event: Equatable, Sendable {
        public var watch: Int32
        public var mask: UInt32
        public var cookie: UInt32
        /// The entry's name, for events inside a watched directory.
        public var name: String

        public init(watch: Int32, mask: UInt32, cookie: UInt32 = 0, name: String = "") {
            self.watch = watch
            self.mask = mask
            self.cookie = cookie
            self.name = name
        }
    }

    /// The `struct inotify_event` records in what one read() returned: wd,
    /// mask, cookie and len as native 32-bit integers, then `len` bytes of
    /// name padded with NULs. A truncated record at the end is dropped.
    public static func events(_ bytes: [UInt8]) -> [Event] {
        let header = 16
        var events: [Event] = []
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset + header <= raw.count {
                let wd = raw.loadUnaligned(fromByteOffset: offset, as: Int32.self)
                let mask = raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)
                let cookie = raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self)
                let length = Int(raw.loadUnaligned(fromByteOffset: offset + 12, as: UInt32.self))
                guard offset + header + length <= raw.count else { break }
                let nameBytes = raw[(offset + header)..<(offset + header + length)].prefix { $0 != 0 }
                events.append(Event(watch: wd, mask: mask, cookie: cookie, name: String(decoding: nameBytes, as: UTF8.self)))
                offset += header + length
            }
        }
        return events
    }

    /// Whether `event` may mean the config changed: anything on the file's
    /// own watch, the directory itself going away, a change to the entry
    /// named `fileName` in the directory, or lost events (queue overflow).
    public static func affectsConfig(_ event: Event, directoryWatch: Int32?, fileWatch: Int32?, fileName: String) -> Bool {
        if event.mask & queueOverflow != 0 { return true }
        if let fileWatch, event.watch == fileWatch { return true }
        guard let directoryWatch, event.watch == directoryWatch else { return false }
        if event.mask & (deleteSelf | moveSelf | unmount) != 0 { return true }
        return !event.name.isEmpty && event.name == fileName
    }
}

#if os(Linux)
@MainActor
public final class InotifyConfigWatcher: ConfigWatcher {
    private var source: DispatchSourceRead?

    public init() {}

    public func watch(_ path: String, onChange: @escaping @MainActor () -> Void) {
        stop()
        let fd = inotify_init1(Int32(IN_NONBLOCK | IN_CLOEXEC))
        guard fd >= 0 else {
            vestalLog("config watch: inotify_init1 failed (errno \(errno)); reload with SIGHUP or `vestal reload`")
            return
        }
        let parent = (path as NSString).deletingLastPathComponent
        let fileName = (path as NSString).lastPathComponent
        let directory = inotify_add_watch(fd, parent.isEmpty ? "." : parent, Inotify.directoryMask)
        let file = inotify_add_watch(fd, path, Inotify.fileMask)
        guard directory >= 0 || file >= 0 else {
            // Neither is there (yet).
            close(fd)
            return
        }
        let directoryWatch: Int32? = directory >= 0 ? directory : nil
        let fileWatch: Int32? = file >= 0 ? file : nil
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler {
            let events = Self.drain(fd)
            let changed = events.contains {
                Inotify.affectsConfig($0, directoryWatch: directoryWatch, fileWatch: fileWatch, fileName: fileName)
            }
            if changed { MainActor.assumeIsolated { onChange() } }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    /// Everything readable now; the descriptor is non-blocking.
    private nonisolated static func drain(_ fd: Int32) -> [Inotify.Event] {
        var bytes: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                bytes.append(contentsOf: buffer[0..<count])
                continue
            }
            if count < 0 && errno == EINTR { continue }
            break
        }
        return Inotify.events(bytes)
    }
}
#endif
