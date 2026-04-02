// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Moss",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "moss", targets: ["MossCLI"]),
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MossCLI",
            path: "Sources/MossCLI"
        ),
    ]
)
