// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnapRecorder",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SnapRecorder", targets: ["SnapRecorder"])
    ],
    targets: [
        .executableTarget(
            name: "SnapRecorder",
            path: "Sources/SnapRecorder"
        )
    ],
    swiftLanguageModes: [.v5]
)
