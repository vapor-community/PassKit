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
        .package(url: "https://github.com/vapor/vapor.git", from: "4.102.1"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.11.0"),
        .package(url: "https://github.com/vapor/apns.git", from: "4.1.0"),
        .package(url: "https://github.com/vapor-community/Zip.git", from: "2.2.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
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
                .product(name: "Zip", package: "zip"),
                .product(name: "X509", package: "swift-certificates"),
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
                .target(name: "PassKit"),
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            ],
            resources: [
                .copy("Templates"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "OrdersTests",
            dependencies: [
                .target(name: "Orders"),
                .target(name: "PassKit"),
                .product(name: "XCTVapor", package: "vapor"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
            ],
            resources: [
                .copy("Templates"),
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
