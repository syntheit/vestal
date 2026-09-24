// swift-tools-version:5.9
import PackageDescription

// VestalCore is portable (Foundation only) and builds and tests on Linux.
// VestalMac holds the macOS UI and platform code; every file in it is wrapped
// in `#if os(macOS)`, so on Linux it compiles to an empty module and the
// `vestal` executable is CLI-only.

let macOS = BuildSettingCondition.when(platforms: [.macOS])

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
            dependencies: ["VestalCore", "VestalMac"]
        ),
        .testTarget(
            name: "VestalCoreTests",
            dependencies: ["VestalCore"],
            exclude: ["Fixtures"]
        ),
    ]
)
