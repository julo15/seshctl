// swift-tools-version: 6.0
//
// Phase 1 parity-spike Swift harness.
//
// Single executable target depending on huggingface/swift-transformers for
// tokenization + CoreML for inference + Accelerate for mean-pool / L2 norm.
// No other third-party deps.
//
// swift-transformers 1.3.3 was the latest stable release as of 2026-05-16 —
// the version pin is exact for parity reproducibility (the spike is a gate;
// a quietly upgrading tokenizer dep could mask a regression).
//
// Platform: macOS 14+ — matches `coremltools.target.macOS14` in convert-model.py
// and gives us the modern CoreML mlprogram runtime.

import PackageDescription

let package = Package(
    name: "SpikeHarness",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(
            url: "https://github.com/huggingface/swift-transformers",
            exact: "1.3.3"
        ),
    ],
    targets: [
        .executableTarget(
            name: "SpikeHarness",
            dependencies: [
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
    ]
)
