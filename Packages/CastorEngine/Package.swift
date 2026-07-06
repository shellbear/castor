// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CastorEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CastorEngine", targets: ["CastorEngine"])
    ],
    dependencies: [
        .package(url: "https://github.com/swhitty/FlyingFox.git", .upToNextMajor(from: "0.20.0"))
    ],
    targets: [
        .target(
            name: "CastorEngine",
            dependencies: [
                .product(name: "FlyingFox", package: "FlyingFox"),
                .product(name: "FlyingSocks", package: "FlyingFox"),
            ]
        ),
        .testTarget(
            name: "CastorEngineTests",
            dependencies: ["CastorEngine"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
