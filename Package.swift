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
        .target(
            name: "VestalCore",
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
            dependencies: ["VestalCore", "VestalMac"]
        ),
        .testTarget(
            name: "VestalCoreTests",
            dependencies: ["VestalCore"],
            exclude: ["Fixtures"]
        ),
    ]
)
