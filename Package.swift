// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hisashi",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Hisashi", path: "Sources/Hisashi")
    ],
    swiftLanguageModes: [.v5]
)
