// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SingKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "SingCore", targets: ["SingCore"]),
        .library(name: "SingDesign", targets: ["SingDesign"]),
        .library(name: "SingClient", targets: ["SingClient"]),
        .library(name: "SingHost", targets: ["SingHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
    ],
    targets: [
        .target(name: "SingCore"),
        .target(name: "SingDesign", dependencies: ["SingCore"], resources: [.process("Resources")]),
        .target(name: "SingClient", dependencies: ["SingCore"]),
        .target(
            name: "SingHost",
            dependencies: [
                "SingCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ]
        ),
        .testTarget(name: "SingCoreTests", dependencies: ["SingCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SingHostTests", dependencies: ["SingHost"], resources: [.copy("Fixtures")]),
    ]
)
