// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Moss",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "moss", targets: ["MossCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/Lakr233/libghostty-spm.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "MossApp",
            dependencies: [
                .product(name: "GhosttyKit", package: "libghostty-spm"),
                .product(name: "GhosttyTerminal", package: "libghostty-spm"),
            ],
            path: "Sources",
            exclude: ["MossCLI"],
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
            ]
        ),
        .executableTarget(
            name: "MossCLI",
            path: "Sources/MossCLI"
        ),
    ]
)
