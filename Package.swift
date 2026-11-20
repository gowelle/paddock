// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Paddock",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PaddockCore", targets: ["PaddockCore"]),
        .executable(name: "paddockd", targets: ["paddockd"]),
        .executable(name: "paddock", targets: ["paddock"]),
        .executable(name: "PaddockApp", targets: ["PaddockApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "PaddockCore"),
        .executableTarget(name: "paddockd", dependencies: ["PaddockCore"]),
        .executableTarget(
            name: "paddock",
            dependencies: [
                "PaddockCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "PaddockApp", dependencies: ["PaddockCore"]),
        .testTarget(name: "PaddockCoreTests", dependencies: ["PaddockCore"]),
        .testTarget(name: "IntegrationTests", dependencies: ["PaddockCore"]),
    ],
    swiftLanguageModes: [.v5]
)
