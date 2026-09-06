// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "paneglance",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "paneglance", targets: ["paneglance"])
    ],
    targets: [
        .executableTarget(name: "paneglance"),
        .testTarget(
            name: "paneglanceTests",
            dependencies: ["paneglance"],
            exclude: ["fixtures"]
        )
    ]
)
