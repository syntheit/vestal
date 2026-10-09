#if os(macOS)
import AppKit
import SwiftUI
import VestalCore

// MARK: - Frames
//
// Every node's final frame, for `--frames`: collected while
// the stage renders, from a GeometryReader behind each node, in the stage's
// coordinates. `clipped` marks nodes cut off by the window or a `clip`
// ancestor, `truncated` texts cut by `lines`. Only offscreen renders ask for
// frames; the app draws without probes.

/// One node's frame, as the GTK UI writes it.
public struct RenderedFrame: Codable, Equatable {
    public var id: String
    public var x: Double, y: Double, width: Double, height: Double
    public var clipped: Bool
    public var truncated: Bool
}

/// Frames by node id, written during rendering on the main thread.
final class FrameCollector: @unchecked Sendable {
    static let space = "vestal-stage"
    private var frames: [ObjectIdentifier: CGRect] = [:]

    func record(_ handle: NodeHandle, _ frame: CGRect) {
        frames[ObjectIdentifier(handle)] = frame
    }

    /// The frames in tree order (the root's, then the popup's), with the
    /// clip and truncation flags.
    @MainActor
    func frames(of store: RenderStore, window: CGRect) -> [RenderedFrame] {
        var result: [RenderedFrame] = []
        func visit(_ handle: NodeHandle, clip: CGRect) {
            guard let frame = frames[ObjectIdentifier(handle)] else { return }
            let clipped = !clip.insetBy(dx: -0.5, dy: -0.5).contains(frame)
            result.append(RenderedFrame(id: handle.node.id, x: Double(frame.minX), y: Double(frame.minY),
                                        width: Double(frame.width), height: Double(frame.height),
                                        clipped: clipped, truncated: Self.truncated(handle, frame, store.style)))
            let inner = handle.node.clip ? clip.intersection(frame) : clip
            for child in handle.children { visit(child, clip: inner) }
        }
        if let root = store.root { visit(root, clip: window) }
        if let popup = store.popup, let card = frames[ObjectIdentifier(popup.handle)] {
            // The card clips its content (RenderStageView).
            visit(popup.handle, clip: window.intersection(card))
        }
        return result
    }

    /// Whether a text with `lines` doesn't fit its frame: measured with the
    /// AppKit font SwiftUI's system font resolves to.
    @MainActor
    private static func truncated(_ handle: NodeHandle, _ frame: CGRect, _ style: RenderStyle) -> Bool {
        guard case .text(let t) = handle.node.content, let lines = t.lines else { return false }
        let available = frame.width - handle.node.padding.horizontal
        let font = nsFont(role: t.font, size: t.size, weight: t.weight, style: style)
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if t.tracking != 0 { attributes[.kern] = t.tracking }
        let string = NSAttributedString(string: t.text, attributes: attributes)
        if lines <= 1 && !t.text.contains("\n") { return string.size().width > available + 0.5 }
        let bounds = string.boundingRect(with: NSSize(width: available, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        return bounds.height > lineHeight * CGFloat(max(1, lines)) + 0.5
    }

    /// A font of an installed family at a weight, by family or PostScript name.
    private static func namedFont(_ family: String, size: Double, weight: NSFont.Weight) -> NSFont? {
        if NSFontManager.shared.availableMembers(ofFontFamily: family) != nil {
            let traits: [NSFontDescriptor.TraitKey: Any] = [.weight: weight.rawValue]
            let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: traits])
            if let font = NSFont(descriptor: descriptor, size: CGFloat(size)) { return font }
        }
        return NSFont(name: family, size: CGFloat(size))
    }

    private static func nsFont(role: String, size: Double, weight: Int, style: RenderStyle) -> NSFont {
        let w: NSFont.Weight
        switch (min(900, max(100, weight)) + 50) / 100 {
        case 1: w = .ultraLight
        case 2: w = .thin
        case 3: w = .light
        case 4: w = .regular
        case 5: w = .medium
        case 6: w = .semibold
        case 7: w = .bold
        case 8: w = .heavy
        default: w = .black
        }
        let family = RenderStyle.family(role: role, fonts: style.theme.fonts).0
        if let family, let custom = namedFont(family, size: size, weight: w) { return custom }
        if let fallback = RenderStyle.fallback(role: role, fonts: style.theme.fonts),
           let custom = namedFont(fallback, size: size, weight: w) { return custom }
        switch role {
        case "mono": return .monospacedSystemFont(ofSize: CGFloat(size), weight: w)
        case "rounded":
            let base = NSFont.systemFont(ofSize: CGFloat(size), weight: w)
            return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: CGFloat(size)) } ?? base
        default: return .systemFont(ofSize: CGFloat(size), weight: w)
        }
    }
}

private struct FrameCollectorKey: EnvironmentKey {
    static let defaultValue: FrameCollector? = nil
}

extension EnvironmentValues {
    /// Set only for offscreen renders that write frames.
    var renderFrames: FrameCollector? {
        get { self[FrameCollectorKey.self] }
        set { self[FrameCollectorKey.self] = newValue }
    }
}

/// Behind a node: reports its frame to the collector.
struct FrameProbe: View {
    let handle: NodeHandle
    let collector: FrameCollector

    var body: some View {
        GeometryReader { proxy in
            let _ = collector.record(handle, proxy.frame(in: .named(FrameCollector.space)))
            Color.clear
        }
    }
}
#endif
