// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Piopio",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "PiopioKit", targets: ["PiopioKit"]),
        .library(name: "PiopioTranscript", targets: ["PiopioTranscript"]),
        .executable(name: "piopio-cli", targets: ["piopio-cli"]),
    ],
    targets: [
        .target(name: "PiopioKit"),
        .executableTarget(name: "piopio-cli", dependencies: ["PiopioKit"]),
        // The session transcript: a windowed TextKit 2 document (docs/spikes/s2).
        .target(name: "PiopioTranscript", dependencies: ["PiopioKit"]),
        // Spike S2: transcript rendering benchmarks (docs/spec/09-roadmap.md).
        .executableTarget(name: "TranscriptLab", dependencies: ["PiopioKit", "PiopioTranscript"]),
        .testTarget(name: "PiopioKitTests", dependencies: ["PiopioKit"]),
        .testTarget(name: "PiopioTranscriptTests", dependencies: ["PiopioTranscript"]),
    ]
)
