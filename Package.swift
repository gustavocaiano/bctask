// swift-tools-version: 6.0

import PackageDescription

// BCTask — lightweight native macOS menu-bar todo app.
// Targets macOS 13 (MenuBarExtra availability floor). No third-party dependencies.
//
// Test tooling note: on Command Line Tools-only machines (no full Xcode) the
// Swift Testing framework and macro plugin live outside the SDK, so
// scripts/test.sh derives the needed search paths from the active developer
// directory and passes them to every target. Package.swift stays conventional
// and free of machine-specific flags.
let package = Package(
    name: "BCTask",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "BCTaskCore", targets: ["BCTaskCore"]),
    ],
    targets: [
        .target(
            name: "BCTaskCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "BCTask",
            dependencies: ["BCTaskCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BCTaskCoreTests",
            dependencies: ["BCTaskCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BCTaskAppTests",
            dependencies: ["BCTask"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
