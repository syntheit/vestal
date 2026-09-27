// swift-tools-version:5.9
import PackageDescription

// VestalCore is portable (Foundation only) and builds and tests on Linux.
// VestalMac holds the macOS UI and platform code; every file in it is wrapped
// in `#if os(macOS)`, so on Linux it compiles to an empty module. VestalLinux
// is the GTK 4 UI; every file in it is wrapped in `#if os(Linux)`, and it and
// its C module exist in the package only when building on Linux.

let macOS = BuildSettingCondition.when(platforms: [.macOS])

#if os(Linux)
// GTK 4, gtk4-layer-shell, libepoxy and fontconfig as one flattened
// pkg-config module, which the Nix build and dev shell provide
// (nix/gtk-pkgconfig.nix; it also puts gtk4-layer-shell before
// libwayland-client on the link line, as that library requires).
let linuxTargets: [Target] = [
    .systemLibrary(name: "CGtk4", pkgConfig: "vestal-gtk4"),
    .target(name: "VestalLinux", dependencies: ["VestalCore", "CGtk4"]),
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
        .target(name: "VestalCore"),
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
            dependencies: ["VestalCore"],
            exclude: ["Fixtures"]
        ),
    ] + linuxTargets
)
