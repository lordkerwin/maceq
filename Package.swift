// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacEQ",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MacEQ",
            path: "Sources/MacEQ",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
