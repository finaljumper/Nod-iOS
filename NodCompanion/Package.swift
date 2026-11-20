// swift-tools-version: 6.2
import PackageDescription

// NodCore holds everything that can be tested without a device: the conversation logic, the
// transport contract and the text handling for speech. NodSpeech holds the Apple-framework
// pieces. The SwiftUI app in App/ is built from project.yml and depends on both.
let package = Package(
    name: "NodCompanion",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "NodCore", targets: ["NodCore"]),
        .library(name: "NodSpeech", targets: ["NodSpeech"]),
    ],
    dependencies: [
        // Supertonic 3 runs through sherpa-onnx, the same way as in LangPal. sherpa-onnx pins
        // its own ONNX Runtime binaries (csukuangfj/onnxruntime-libs).
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", exact: "2.0.0"),
        // Mirrors Apple's SpeechAnalyzer API with a choice of recognition engine. It is early
        // work (0.1.0); pinned so that an update is a deliberate step.
        .package(url: "https://github.com/mattt/AnySpeechRecognizer", exact: "0.1.0"),
        // Runs Gradium's Phonon voice on Core ML.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
    ],
    targets: [
        .target(name: "NodCore"),
        .target(
            name: "NodSpeech",
            dependencies: [
                "NodCore",
                .product(name: "sherpa-onnx", package: "sherpa-onnx"),
                .product(name: "AnySpeechRecognizer", package: "AnySpeechRecognizer"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            // Swift 5 mode: the audio callbacks and the C speech engine predate strict concurrency.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "NodCoreTests", dependencies: ["NodCore"]),
    ]
)
