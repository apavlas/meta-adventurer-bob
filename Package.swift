// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BobCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "BobCore", targets: ["BobCore"]),
    ],
    targets: [
        .target(name: "BobCore"),
        .testTarget(
            name: "BobCoreTests",
            dependencies: ["BobCore"]
        ),
    ]
)
