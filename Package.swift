// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hisashi",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Hisashi", targets: ["Hisashi"]),
        // Loaded into /usr/bin/perl at runtime, see Sources/HisashiMedia.
        .library(name: "HisashiMedia", type: .dynamic, targets: ["HisashiMedia"]),
    ],
    targets: [
        .executableTarget(name: "Hisashi", path: "Sources/Hisashi"),
        .target(name: "HisashiMedia", path: "Sources/HisashiMedia"),
    ],
    swiftLanguageModes: [.v5]
)
