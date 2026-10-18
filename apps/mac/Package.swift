// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Piopio",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "PiopioKit", targets: ["PiopioKit"]),
        .executable(name: "piopio-cli", targets: ["piopio-cli"]),
    ],
    targets: [
        .target(name: "PiopioKit"),
        .executableTarget(name: "piopio-cli", dependencies: ["PiopioKit"]),
        // Spike S2: transcript rendering benchmarks (docs/spec/09-roadmap.md).
        .executableTarget(name: "TranscriptLab", dependencies: ["PiopioKit"]),
        .testTarget(name: "PiopioKitTests", dependencies: ["PiopioKit"]),
    ]
)
