// swift-tools-version:5.9
import PackageDescription

// VestalCore is portable (Foundation only) and builds and tests on Linux.
// VestalMac holds the macOS UI and platform code; every file in it is wrapped
// in `#if os(macOS)`, so on Linux it compiles to an empty module. VestalLinux
// is the GTK 4 UI; every file in it is wrapped in `#if os(Linux)`, and it and
// its C module exist in the package only when building on Linux.

let macOS = BuildSettingCondition.when(platforms: [.macOS])

// The system libsqlite3 (Thunderbird's calendar caches): in the macOS SDK; on
// Linux found through pkg-config.
#if os(Linux)
let sqliteTarget = Target.systemLibrary(name: "CSQLite", pkgConfig: "sqlite3")
#else
let sqliteTarget = Target.systemLibrary(name: "CSQLite")
#endif

#if os(Linux)
// GTK 4, gtk4-layer-shell, libepoxy and fontconfig as one flattened
// pkg-config module, which the Nix build and dev shell provide
// (nix/gtk-pkgconfig.nix; it also puts gtk4-layer-shell before
// libwayland-client on the link line, as that library requires).
// CWaylandCapture is C: one screenshot of an output over wlr-screencopy or
// ext-image-copy-capture (theme.backdrop "self"), with the protocol glue
// wayland-scanner generated from protocols/ vendored next to it.
let linuxTargets: [Target] = [
    .systemLibrary(name: "CGtk4", pkgConfig: "vestal-gtk4"),
    // _GNU_SOURCE on the command line: with -fmodules, a #define in the file
    // doesn't reach glibc's headers (memfd_create).
    .target(name: "CWaylandCapture", dependencies: ["CGtk4"], exclude: ["protocols"],
            cSettings: [.define("_GNU_SOURCE")]),
    .target(name: "VestalLinux", dependencies: ["VestalCore", "CGtk4", "CWaylandCapture"]),
]
let linuxUI: [Target.Dependency] = ["VestalLinux"]
#else
let linuxTargets: [Target] = []
let linuxUI: [Target.Dependency] = []
#endif

let package = Package(
    name: "Vestal",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "vestal", targets: ["vestal"]),
        .library(name: "VestalCore", targets: ["VestalCore"]),
    ],
    targets: [
        .target(
            name: "VestalCore",
            dependencies: ["CSQLite"],
            swiftSettings: [
                // Swift 5.10's closure specializer runs away on the expression
                // engine's continuation-passing evaluator (Expr/): a release
                // build does not finish in 30 minutes with it, and takes
                // seconds without.
                .unsafeFlags(["-Xllvm", "-sil-disable-pass=closure-specialize"], .when(configuration: .release)),
            ]
        ),
        .target(
            name: "VestalMac",
            dependencies: ["VestalCore"],
            linkerSettings: [
                .linkedFramework("AppKit", macOS),
                .linkedFramework("Carbon", macOS),
                .linkedFramework("SwiftUI", macOS),
                .linkedFramework("IOKit", macOS),
                .linkedFramework("EventKit", macOS),
                .linkedFramework("CoreAudio", macOS),
                .linkedFramework("Metal", macOS),
                .linkedFramework("MetalKit", macOS),
                .linkedFramework("QuartzCore", macOS),
            ]
        ),
        .executableTarget(
            name: "vestal",
            dependencies: ["VestalCore", "VestalMac"] + linuxUI
        ),
        .testTarget(
            name: "VestalCoreTests",
            dependencies: ["VestalCore", "CSQLite"],
            exclude: ["Fixtures"]
        ),
    ] + [sqliteTarget] + linuxTargets
)
