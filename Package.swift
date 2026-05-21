// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "seshctl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "seshctl-cli", targets: ["seshctl-cli"]),
        .executable(name: "SeshctlApp", targets: ["SeshctlApp"]),
        .library(name: "SeshctlCore", targets: ["SeshctlCore"]),
        .library(name: "SeshctlUI", targets: ["SeshctlUI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.4.1"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.4.0"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        // Sparkle 2.x — auto-update framework. Attached to the SeshctlApp
        // target only; SeshctlCore stays Foundation-only and the CLI doesn't
        // need it.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(
            name: "SeshctlCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "SeshctlUI",
            dependencies: [
                "SeshctlCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ]
        ),
        .executableTarget(
            name: "SeshctlApp",
            dependencies: [
                "SeshctlCore",
                "SeshctlUI",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(
            name: "seshctl-cli",
            dependencies: [
                "SeshctlCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SeshctlCoreTests",
            dependencies: ["SeshctlCore"]
        ),
        .testTarget(
            name: "SeshctlUITests",
            dependencies: ["SeshctlUI", "SeshctlCore"]
        ),
        .testTarget(
            name: "SeshctlAppTests",
            dependencies: ["SeshctlApp"]
        ),
    ]
)
