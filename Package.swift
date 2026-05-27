// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "seshctl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "seshctl-cli", targets: ["seshctl-cli"]),
        .executable(name: "SeshctlApp", targets: ["SeshctlApp"]),
        .library(name: "SeshctlCore", targets: ["SeshctlCore"]),
        .library(name: "SeshctlRecall", targets: ["SeshctlRecall"]),
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
        // swift-transformers — provides the `Tokenizers` product used by
        // SeshctlRecall for native semantic search. Pinned to 1.3.3 (the
        // version verified in the Phase 1 parity spike).
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.3"),
    ],
    targets: [
        .target(
            name: "SeshctlCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "SeshctlRecall",
            dependencies: [
                "SeshctlCore",
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            resources: [
                .copy("Models"),
            ]
        ),
        .target(
            name: "SeshctlUI",
            dependencies: [
                "SeshctlCore",
                "SeshctlRecall",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ]
        ),
        .executableTarget(
            name: "SeshctlApp",
            dependencies: [
                "SeshctlCore",
                "SeshctlRecall",
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
            name: "SeshctlRecallTests",
            dependencies: ["SeshctlRecall", "SeshctlCore"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
        .testTarget(
            name: "SeshctlUITests",
            dependencies: ["SeshctlUI", "SeshctlCore", "SeshctlRecall"]
        ),
        .testTarget(
            name: "SeshctlAppTests",
            dependencies: ["SeshctlApp"]
        ),
    ]
)
