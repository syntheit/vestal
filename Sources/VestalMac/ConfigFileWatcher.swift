#if os(macOS)
import Darwin
import Dispatch
import Foundation
import VestalCore

// MARK: - Config file watcher
//
// Two DispatchSource vnode sources: the config file's directory and the file
// itself. The directory catches Home Manager's switch, which replaces the
// symlink `config.json` (the file it points to, in the Nix store, never
// changes), and editors that save through a temporary file and a rename; the
// file catches writes in place. Attribute changes are left out (reading the
// file may touch its access time). The resident app calls `watch` again
// after every reload, which opens whatever file is there now. O_EVTONLY
// descriptors don't keep a volume from unmounting.

@MainActor
final class DispatchConfigWatcher: ConfigWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []

    func watch(_ path: String, onChange: @escaping @MainActor () -> Void) {
        stop()
        let parent = (path as NSString).deletingLastPathComponent
        let targets: [(String, DispatchSource.FileSystemEvent)] = [
            (parent.isEmpty ? "." : parent, [.write, .delete, .rename, .revoke]),
            (path, [.write, .extend, .delete, .rename, .link, .revoke]),
        ]
        for (target, events) in targets {
            let fd = open(target, O_EVTONLY)
            guard fd >= 0 else { continue }  // not there (yet)
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
            source.setEventHandler { onChange() }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        for source in sources { source.cancel() }
        sources = []
    }
}
#endif
