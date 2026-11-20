// swift-tools-version: 6.0
import PackageDescription

// ASRBenchCore is platform-independent (it also builds and tests on Linux).
// ASRBenchEngines and ASRBenchMLXEngines hold the Apple-only adapters (Speech framework,
// WhisperKit, AVFoundation, MLX), so they and their dependencies are left out when the manifest
// is evaluated on Linux.
#if os(Linux)
let appleOnlyDependencies: [Package.Dependency] = []
let appleOnlyProducts: [Product] = []
let appleOnlyTargets: [Target] = []
#else
let appleOnlyDependencies: [Package.Dependency] = [
    // WhisperKit now ships from the `argmax-oss-swift` package (the old WhisperKit URL redirects here).
    .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    // mlx-audio-swift, pinned to the head of its open pull request 412 ("Stop Qwen3-ASR generation
    // at the tokenizer's end tokens"). That is upstream `main` of Neywa-Labs/mlx-audio-swift plus
    // two commits; without them Rumble-2-Flash never stops generating. Switch to an upstream
    // release once the pull request is merged.
    .package(url: "https://github.com/TypeWhisper/mlx-audio-swift.git", revision: "8a2907ebecedb3525f292b8ef73501cef98340dc"),
    .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.33.0")),
    .package(url: "https://github.com/huggingface/swift-huggingface.git", .upToNextMajor(from: "0.8.1")),
]
let appleOnlyProducts: [Product] = [
    .library(name: "ASRBenchEngines", targets: ["ASRBenchEngines"]),
    .library(name: "ASRBenchMLXEngines", targets: ["ASRBenchMLXEngines"]),
]
let appleOnlyTargets: [Target] = [
    .target(
        name: "ASRBenchEngines",
        dependencies: [
            "ASRBenchCore",
            .product(name: "WhisperKit", package: "argmax-oss-swift"),
        ],
        // Swift 5 language mode: WhisperKit's types are not fully Sendable-annotated, and this
        // target could not be compiled where it was written. Core stays in Swift 6 mode.
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // Engines that run on MLX (Metal). Kept apart from ASRBenchEngines because MLX is a large
    // dependency and does not run in the iOS Simulator.
    .target(
        name: "ASRBenchMLXEngines",
        dependencies: [
            "ASRBenchCore",
            .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
            .product(name: "MLX", package: "mlx-swift"),
            .product(name: "HuggingFace", package: "swift-huggingface"),
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "ASRBenchEnginesTests",
        dependencies: ["ASRBenchEngines", "ASRBenchMLXEngines"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]
#endif

let package = Package(
    name: "VoiceASRBenchmark",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ASRBenchCore", targets: ["ASRBenchCore"]),
        .executable(name: "asrbench-dataset", targets: ["asrbench-dataset"]),
    ] + appleOnlyProducts,
    dependencies: appleOnlyDependencies,
    targets: [
        .target(name: "ASRBenchCore"),
        .executableTarget(name: "asrbench-dataset", dependencies: ["ASRBenchCore"]),
        .testTarget(name: "ASRBenchCoreTests", dependencies: ["ASRBenchCore"]),
    ] + appleOnlyTargets
)
