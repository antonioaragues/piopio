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
        .testTarget(name: "PiopioKitTests", dependencies: ["PiopioKit"]),
    ]
)
