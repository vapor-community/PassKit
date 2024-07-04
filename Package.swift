// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PassKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "Passes", targets: ["PassKit", "Passes"]),
        .library(name: "Orders", targets: ["PassKit", "Orders"]),
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
        .target(
            name: "Orders",
            dependencies: [
                .target(name: "PassKit"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PassesTests",
            dependencies: [
                .target(name: "Passes"),
                .product(name: "XCTVapor", package: "vapor"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "OrdersTests",
            dependencies: [
                .target(name: "Orders"),
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
