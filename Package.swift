// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LoadedModels",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "LoadedModels", path: "Sources/LoadedModels")
    ]
)
