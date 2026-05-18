// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Vestal",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "vestal", targets: ["Vestal"])
    ],
    targets: [
        .executableTarget(
            name: "Vestal",
            path: "Sources/Vestal",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("EventKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
            ]
        )
    ]
)
