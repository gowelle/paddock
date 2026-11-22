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
        .executable(name: "paddock-ports", targets: ["paddock-ports"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        // The updater. A prebuilt framework from its publisher, pinned; Scripts/bundle.sh puts it in the app.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
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
        .executableTarget(
            name: "PaddockApp",
            dependencies: ["PaddockCore", .product(name: "Sparkle", package: "Sparkle")],
            // In the app bundle the framework is in Contents/Frameworks, beside Contents/MacOS.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // C, because Swift cannot see launch_activate_socket from <launch.h>.
        .executableTarget(name: "paddock-ports"),
        .target(name: "PaddockTestSupport", dependencies: ["PaddockCore"], path: "Tests/PaddockTestSupport"),
        // A stand-in service for the service framework's tests; never shipped (Scripts/bundle.sh names
        // the binaries it ships).
        .executableTarget(name: "paddock-fake-service", path: "Tests/FakeService"),
        .testTarget(name: "PaddockCoreTests", dependencies: ["PaddockCore", "PaddockTestSupport"]),
        .testTarget(name: "IntegrationTests", dependencies: ["PaddockCore", "PaddockTestSupport"]),
    ],
    swiftLanguageModes: [.v5]
)
