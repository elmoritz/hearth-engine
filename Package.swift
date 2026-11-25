// swift-tools-version: 6.2
import PackageDescription

// E-API-1: Swift 6 language mode and warnings as errors on every target; no dependencies.
let strict: [SwiftSetting] = [.swiftLanguageMode(.v6), .treatAllWarnings(as: .error)]

let package = Package(
    name: "HearthEngine",
    platforms: [.iOS("26.4"), .macOS(.v14)],
    products: [
        .library(name: "HearthEngine", targets: ["HearthEngine"]),
        .library(name: "HearthHarness", targets: ["HearthHarness"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "HearthEngine", resources: [.process("Shaders")], swiftSettings: strict),
        .target(name: "HearthHarness", dependencies: ["HearthEngine"], swiftSettings: strict),
        .testTarget(name: "HearthEngineTests", dependencies: ["HearthEngine", "HearthHarness"], swiftSettings: strict),
    ]
)
