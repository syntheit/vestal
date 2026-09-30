import Foundation

// MARK: - Render model: messages
//
// The snapshot, patch and interaction messages, as Swift values. The
// in-process API passes these directly; the socket protocol serialises
// exactly these.

/// The render model's protocol version.
public enum RenderProtocol {
    public static let version = 1
    public static let minor = 0
}

/// JSON coding for the render model: sorted keys, so output is deterministic.
public enum RenderJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static var decoder: JSONDecoder { JSONDecoder() }
}

/// An entry of the snapshot's `views` list.
public struct RenderViewInfo: Equatable, Sendable, Codable {
    public var name: String
    public var title: String?
    public var key: String?

    public init(name: String, title: String? = nil, key: String? = nil) {
        self.name = name
        self.title = title
        self.key = key
    }
}

/// `theme` in a snapshot: the resolved palette, font families and icon fonts.
public struct RenderTheme: Equatable, Sendable, Codable {
    /// `aurora`, `blur` or `none`.
    public var background: String
    /// Every colour name a node may use, as `#rrggbbaa`.
    public var colors: [String: String]
    /// Family per role; nil means the platform default.
    public var fonts: Fonts
    public var icons: Icons
    /// `theme.dim`, 0 to 1: how much of the palette's `bg` lies over
    /// the blurred desktop for `aurora` and `blur`. Nil (omitted): the UI's
    /// default (`linuxDim` on Linux; none on macOS, where the material
    /// tints). See `windowAlpha`.
    public var dim: Double?
    /// `theme.backdrop`, the GTK UI's: `self` (vestal captures the
    /// output and blurs it), `compositor` (a translucent window over the
    /// compositor's blur) or `none` (translucent, no blur asked for). Nil
    /// (omitted): `self` where the compositor can capture, else
    /// `compositor`. The macOS UI ignores it.
    public var backdrop: String?
    /// `theme.blur`: the radius, in points, of `self`'s blur. Nil
    /// (omitted): `linuxBlur`.
    public var blur: Double?

    public struct Fonts: Equatable, Sendable, Codable {
        public var sans: String?
        public var mono: String?
        public var rounded: String?

        public init(sans: String? = nil, mono: String? = nil, rounded: String? = nil) {
            self.sans = sans
            self.mono = mono
            self.rounded = rounded
        }

        // Nulls are written out: `{"sans": null, …}` as in the protocol.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(sans, forKey: .sans)
            try c.encode(mono, forKey: .mono)
            try c.encode(rounded, forKey: .rounded)
        }
    }

    public struct Icons: Equatable, Sendable, Codable {
        public var set: String
        /// Font family per weight: `regular`, `fill`.
        public var fonts: [String: String]
        /// `theme.icons`: `"native"` lets the macOS UI draw the
        /// names it knows as SF Symbols, `"phosphor"` always uses the icon
        /// font. Nil (omitted): the platform's default, native on macOS.
        /// Other UIs always draw the font.
        public var mode: String?

        public init(set: String = "phosphor", fonts: [String: String] = ["regular": "Phosphor", "fill": "Phosphor-Fill"],
                    mode: String? = nil) {
            self.set = set
            self.fonts = fonts
            self.mode = mode
        }
    }

    public init(background: String = "aurora", colors: [String: String] = RenderTheme.tokyoNight,
                fonts: Fonts = Fonts(), icons: Icons = Icons(), dim: Double? = nil, backdrop: String? = nil,
                blur: Double? = nil) {
        self.background = background
        self.colors = colors
        self.fonts = fonts
        self.icons = icons
        self.dim = dim
        self.backdrop = backdrop
        self.blur = blur
    }

    private enum CodingKeys: String, CodingKey { case background, colors, fonts, icons, dim, backdrop, blur }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        background = try c.decodeIfPresent(String.self, forKey: .background) ?? "aurora"
        colors = try c.decodeIfPresent([String: String].self, forKey: .colors) ?? [:]
        fonts = try c.decodeIfPresent(Fonts.self, forKey: .fonts) ?? Fonts()
        icons = try c.decodeIfPresent(Icons.self, forKey: .icons) ?? Icons()
        dim = try c.decodeIfPresent(Double.self, forKey: .dim).map(Self.clampDim)
        backdrop = try c.decodeIfPresent(String.self, forKey: .backdrop).flatMap { ThemeConfig.backdrops.contains($0) ? $0 : nil }
        blur = try c.decodeIfPresent(Double.self, forKey: .blur).map(Self.clampBlur)
    }

    /// The `tokyo-night` palette, resolved to `#rrggbbaa`.
    public static let tokyoNight: [String: String] = [
        "text": "#ffffffff",
        "subtle": "#ffffff80",
        "dim": "#ffffff4d",
        "accent": "#7aa1f7ff",
        "good": "#73cf8fff",
        "warn": "#e3c975ff",
        "bad": "#f06b6bff",
        "bg": "#1a1c26ff",
        "track": "#ffffff0f",
        "scrim": "#000000a6",
        "blue": "#7aa1f7ff",
        "green": "#73cf8fff",
        "yellow": "#e3c975ff",
        "red": "#f06b6bff",
        "cyan": "#7dcfffff",
        "purple": "#ba99f7ff",
        "teal": "#73d6c2ff",
        "orange": "#ff9e64ff",
    ]
}

// MARK: - Window background (theme.dim)

extension RenderTheme {
    /// The Linux UI's `theme.dim`: half, so the blurred desktop reads
    /// through as it does under the macOS HUD material, while white text
    /// keeps at least 3.3:1 contrast even over a white wallpaper. It stays
    /// above Hyprland's default `ignore_alpha` (0.3), below which Hyprland
    /// blurs only the aurora's ribbons.
    public static let linuxDim = 0.5

    /// `theme.dim` from the config: a number clamped to 0...1 (check-config
    /// warns outside it); nil when absent or not a finite number.
    public static func dim(_ value: AnyJSON?) -> Double? {
        switch value {
        case .int(let n)?: return clampDim(Double(n))
        case .double(let d)?: return d.isFinite ? clampDim(d) : nil
        default: return nil
        }
    }

    static func clampDim(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 1
    }

    /// How much of the palette's `bg` covers the desktop behind the
    /// dashboard: all of it for `none`; `dim`, else the UI's `defaultDim`,
    /// for `aurora` and `blur` (over the compositor's blur). A `bg` with its
    /// own alpha is multiplied by it.
    public func windowAlpha(defaultDim: Double) -> Double {
        background == "none" ? 1 : (dim ?? defaultDim)
    }

    /// The GTK window's CSS rule: the palette's `bg` at
    /// `windowAlpha(defaultDim: linuxDim)`.
    public var linuxWindowCSS: String { linuxWindowCSS(selfBackdrop: false) }

    /// With `selfBackdrop` (this show draws its own blurred capture, which
    /// lays the tint itself), the window is clear: the capture, tint and
    /// aurora are one opaque layer that fades in over the desktop.
    public func linuxWindowCSS(selfBackdrop: Bool) -> String {
        let hex = colors["bg"].flatMap(RenderPalette.hex) ?? Self.tokyoNight["bg"]!
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0xff
        func channel(_ shift: UInt64) -> Double { Double((value >> shift) & 0xff) / 255 }
        let alpha = selfBackdrop ? 0 : channel(0) * windowAlpha(defaultDim: Self.linuxDim)
        return "window.vestal { background-color: \(Format.cssRGBA(red: channel(24), green: channel(16), blue: channel(8), alpha: alpha)); }"
    }
}

// MARK: - Backdrop (theme.backdrop, theme.blur)

extension RenderTheme {
    /// The GTK UI's `theme.blur`: about the macOS HUD material's blur at
    /// scale 1, heavy enough that text behind the dashboard is gone.
    public static let linuxBlur = 48.0

    /// `theme.blur`'s range: from none to far more than anyone needs.
    public static let blurRange = 0.0...200.0

    /// `theme.blur` from the config: a number clamped to `blurRange`
    /// (check-config warns outside it); nil when absent or not a finite
    /// number.
    public static func blur(_ value: AnyJSON?) -> Double? {
        switch value {
        case .int(let n)?: return clampBlur(Double(n))
        case .double(let d)?: return d.isFinite ? clampBlur(d) : nil
        default: return nil
        }
    }

    static func clampBlur(_ value: Double) -> Double {
        value.isFinite ? min(max(value, blurRange.lowerBound), blurRange.upperBound) : linuxBlur
    }

    /// `theme.backdrop` from the config, nil unless one of `ThemeConfig.backdrops`.
    public static func backdrop(_ value: AnyJSON?) -> String? {
        value?.stringValue.flatMap { ThemeConfig.backdrops.contains($0) ? $0 : nil }
    }

    /// The backdrop the GTK UI wants: none for a `none` background (the
    /// opaque `bg`), else `backdrop`, else `self`. The UI falls back to
    /// `compositor` when the compositor can't capture the screen.
    public var linuxBackdrop: String {
        background == "none" ? "none" : (backdrop ?? "self")
    }
}

/// `popup` in a snapshot: one popup at a time.
public struct RenderPopup: Equatable, Sendable, Codable {
    public var id: String
    public var width: Double
    public var node: RenderNode

    public init(id: String = "popup", width: Double = 520, node: RenderNode) {
        self.id = id
        self.width = width
        self.node = node
    }
}

/// One entry of `diagnostics`.
public struct RenderDiagnostic: Equatable, Sendable, Codable {
    public var id: String?
    public var field: String?
    public var severity: String
    public var code: String
    public var message: String

    public init(id: String? = nil, field: String? = nil, severity: String, code: String, message: String) {
        self.id = id
        self.field = field
        self.severity = severity
        self.code = code
        self.message = message
    }
}

/// The whole model at one moment.
public struct RenderSnapshot: Equatable, Sendable, Codable {
    public var type: String = "snapshot"
    public var `protocol`: Int
    public var minor: Int
    public var seq: Int
    public var view: String
    public var views: [RenderViewInfo]
    public var visible: Bool
    public var theme: RenderTheme
    public var root: RenderNode
    public var popup: RenderPopup?
    public var diagnostics: [RenderDiagnostic]

    public init(seq: Int = 1, view: String = "main", views: [RenderViewInfo] = [], visible: Bool = true,
                theme: RenderTheme = RenderTheme(), root: RenderNode, popup: RenderPopup? = nil,
                diagnostics: [RenderDiagnostic] = []) {
        self.protocol = RenderProtocol.version
        self.minor = RenderProtocol.minor
        self.seq = seq
        self.view = view
        self.views = views
        self.visible = visible
        self.theme = theme
        self.root = root
        self.popup = popup
        self.diagnostics = diagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case type, `protocol`, minor, seq, view, views, visible, theme, root, popup, diagnostics
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "snapshot"
        self.protocol = try c.decodeIfPresent(Int.self, forKey: .protocol) ?? RenderProtocol.version
        minor = try c.decodeIfPresent(Int.self, forKey: .minor) ?? 0
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        view = try c.decodeIfPresent(String.self, forKey: .view) ?? "main"
        views = try c.decodeIfPresent([RenderViewInfo].self, forKey: .views) ?? []
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? true
        theme = try c.decodeIfPresent(RenderTheme.self, forKey: .theme) ?? RenderTheme()
        root = try c.decode(RenderNode.self, forKey: .root)
        popup = try c.decodeIfPresent(RenderPopup.self, forKey: .popup)
        diagnostics = try c.decodeIfPresent([RenderDiagnostic].self, forKey: .diagnostics) ?? []
    }

    // `popup: null` is written out, as in the protocol.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(self.protocol, forKey: .protocol)
        try c.encode(minor, forKey: .minor)
        try c.encode(seq, forKey: .seq)
        try c.encode(view, forKey: .view)
        try c.encode(views, forKey: .views)
        try c.encode(visible, forKey: .visible)
        try c.encode(theme, forKey: .theme)
        try c.encode(root, forKey: .root)
        try c.encode(popup, forKey: .popup)
        try c.encode(diagnostics, forKey: .diagnostics)
    }
}

// MARK: - Patches

public enum RenderPatchOp: Equatable, Sendable, Codable {
    /// Swap the subtree whose root has `id`.
    case replace(id: String, node: RenderNode)
    /// A new root: a view switch or a reload.
    case root(node: RenderNode, view: String)
    case popup(RenderPopup?)
    case theme(RenderTheme)
    case views([RenderViewInfo])
    case diagnostics([RenderDiagnostic])
    /// An op this build doesn't know; ignored.
    case unknown(op: String)

    private enum CodingKeys: String, CodingKey { case op, id, node, view, popup, theme, views, diagnostics }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let op = try c.decode(String.self, forKey: .op)
        switch op {
        case "replace":
            self = .replace(id: try c.decode(String.self, forKey: .id), node: try c.decode(RenderNode.self, forKey: .node))
        case "root":
            self = .root(node: try c.decode(RenderNode.self, forKey: .node),
                         view: try c.decodeIfPresent(String.self, forKey: .view) ?? "main")
        case "popup":
            self = .popup(try c.decodeIfPresent(RenderPopup.self, forKey: .popup))
        case "theme":
            self = .theme(try c.decode(RenderTheme.self, forKey: .theme))
        case "views":
            self = .views(try c.decode([RenderViewInfo].self, forKey: .views))
        case "diagnostics":
            self = .diagnostics(try c.decode([RenderDiagnostic].self, forKey: .diagnostics))
        default:
            self = .unknown(op: op)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .replace(let id, let node):
            try c.encode("replace", forKey: .op)
            try c.encode(id, forKey: .id)
            try c.encode(node, forKey: .node)
        case .root(let node, let view):
            try c.encode("root", forKey: .op)
            try c.encode(node, forKey: .node)
            try c.encode(view, forKey: .view)
        case .popup(let popup):
            try c.encode("popup", forKey: .op)
            try c.encode(popup, forKey: .popup)
        case .theme(let theme):
            try c.encode("theme", forKey: .op)
            try c.encode(theme, forKey: .theme)
        case .views(let views):
            try c.encode("views", forKey: .op)
            try c.encode(views, forKey: .views)
        case .diagnostics(let diagnostics):
            try c.encode("diagnostics", forKey: .op)
            try c.encode(diagnostics, forKey: .diagnostics)
        case .unknown(let op):
            try c.encode(op, forKey: .op)
        }
    }
}

public struct RenderPatch: Equatable, Sendable, Codable {
    public var type: String = "patch"
    public var `protocol`: Int
    public var seq: Int
    /// The `seq` this patch applies to.
    public var base: Int
    public var ops: [RenderPatchOp]

    public init(seq: Int, base: Int, ops: [RenderPatchOp]) {
        self.protocol = RenderProtocol.version
        self.seq = seq
        self.base = base
        self.ops = ops
    }

    private enum CodingKeys: String, CodingKey { case type, `protocol`, seq, base, ops }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "patch"
        self.protocol = try c.decodeIfPresent(Int.self, forKey: .protocol) ?? RenderProtocol.version
        seq = try c.decode(Int.self, forKey: .seq)
        base = try c.decode(Int.self, forKey: .base)
        ops = try c.decode([RenderPatchOp].self, forKey: .ops)
    }
}

public enum RenderPatchError: Error, Equatable, CustomStringConvertible {
    /// `base` isn't the last applied `seq`: ask for a fresh snapshot.
    case baseMismatch(expected: Int, got: Int)
    /// A `replace` names an id that isn't in the tree.
    case unknownId(String)

    public var description: String {
        switch self {
        case .baseMismatch(let expected, let got): return "patch base \(got) does not follow seq \(expected)"
        case .unknownId(let id): return "patch replaces unknown node \(id)"
        }
    }
}

extension RenderSnapshot {
    /// This snapshot with `patch` applied, ops in order. Throws when
    /// the patch doesn't follow this snapshot or names a missing node; the
    /// client then asks for a fresh snapshot.
    public func applying(_ patch: RenderPatch) throws -> RenderSnapshot {
        guard patch.base == seq else { throw RenderPatchError.baseMismatch(expected: seq, got: patch.base) }
        var next = self
        for op in patch.ops { try next.apply(op) }
        next.seq = patch.seq
        return next
    }

    /// Applies one op in place.
    public mutating func apply(_ op: RenderPatchOp) throws {
        switch op {
        case .replace(let id, let node):
            if root.replace(id: id, with: node) { return }
            if var popup, popup.node.replace(id: id, with: node) {
                self.popup = popup
                return
            }
            throw RenderPatchError.unknownId(id)
        case .root(let node, let view):
            root = node
            self.view = view
        case .popup(let popup):
            self.popup = popup
        case .theme(let theme):
            self.theme = theme
        case .views(let views):
            self.views = views
        case .diagnostics(let diagnostics):
            self.diagnostics = diagnostics
        case .unknown:
            break
        }
    }
}

// MARK: - Interaction

/// UI → core. The in-process UI hands these to the core; over the socket
/// they are `{"cmd": …}` lines.
public enum RenderInput: Equatable, Sendable, Codable {
    /// A click on a node with `action: true`.
    case invoke(id: String)
    /// A key press the UI didn't consume, in the hotkey grammar.
    case key(String)
    /// The window went away on its own.
    case hide
    /// A UI-provided view switcher.
    case view(name: String)
    /// Resync: the UI wants a fresh snapshot.
    case snapshot

    private enum CodingKeys: String, CodingKey { case cmd, id, key, name }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .cmd) {
        case "invoke": self = .invoke(id: try c.decode(String.self, forKey: .id))
        case "key": self = .key(try c.decode(String.self, forKey: .key))
        case "hide": self = .hide
        case "view": self = .view(name: try c.decode(String.self, forKey: .name))
        case "snapshot": self = .snapshot
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .cmd, in: c, debugDescription: "unknown cmd \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .invoke(let id):
            try c.encode("invoke", forKey: .cmd)
            try c.encode(id, forKey: .id)
        case .key(let key):
            try c.encode("key", forKey: .cmd)
            try c.encode(key, forKey: .key)
        case .hide:
            try c.encode("hide", forKey: .cmd)
        case .view(let name):
            try c.encode("view", forKey: .cmd)
            try c.encode(name, forKey: .name)
        case .snapshot:
            try c.encode("snapshot", forKey: .cmd)
        }
    }
}

/// Core → UI, besides snapshots and patches: an effect the UI carries out.
public enum RenderEffect: Equatable, Sendable {
    /// Put text on the clipboard.
    case copy(String)
    /// An optional transient message; UIs may ignore it.
    case notify(level: String, text: String)
}
