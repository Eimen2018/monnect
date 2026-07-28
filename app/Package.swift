// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Monnect",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Monnect", path: "Sources/Monnect")
    ]
)
