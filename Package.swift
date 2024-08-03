// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "PassKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "Passes", targets: ["Passes"]),
        .library(name: "Orders", targets: ["Orders"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.102.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.11.0"),
        .package(url: "https://github.com/vapor/apns.git", from: "4.1.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        // used in tests
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.7.4"),
    ],
    targets: [
        .target(
            name: "PassKit",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "Vapor", package: "vapor"),
                .product(name: "VaporAPNS", package: "apns"),
                .product(name: "ZIPFoundation", package: "zipfoundation"),
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
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "OrdersTests",
            dependencies: [
                .target(name: "Orders"),
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
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
