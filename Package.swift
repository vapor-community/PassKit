// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PassKit",
    platforms: [
        .macOS(.v13), .iOS(.v16)
    ],
    products: [
        .library(name: "PassKit", targets: ["PassKit"]),
        .library(name: "Passes", targets: ["PassKit", "Passes"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.102.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.11.0"),
        .package(url: "https://github.com/vapor/apns.git", from: "4.1.0"),
    ],
    targets: [
        .target(
            name: "PassKit",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "VaporAPNS", package: "apns"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Passes",
            dependencies: [
                .target(name: "PassKit"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PassKitTests",
            dependencies: [
                .target(name: "PassKit"),
                .target(name: "Passes"),
                .product(name: "XCTVapor", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)

var swiftSettings: [SwiftSetting] { [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("ConciseMagicFile"),
    .enableUpcomingFeature("ForwardTrailingClosures"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("StrictConcurrency"),
    .enableExperimentalFeature("StrictConcurrency=complete"),
] }
