// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Onion",

    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
    ],

    products: [
        .library(
            name: "Onion",
            type: .dynamic,
            targets: ["Onion"]
        ),
    ],

    dependencies: [

        .package(
            url: "https://github.com/apple/swift-http-types.git",
            from: "1.3.1"
        ),

        .package(
            url: "https://github.com/pointfreeco/swift-snapshot-testing",
            from: "1.18.3"
        ),

        .package(
            url: "https://github.com/sloik/AliasWonderland.git",
            from: "4.0.1"
        ),

        .package(
            url: "https://github.com/sloik/OptionalAPI.git",
            from: "5.2.0"
        ),

        .package(
            url: "https://github.com/sloik/ExTests.git",
            from: "0.1.2"
        ),
    ],

    targets: [
        .target(
            name: "Onion",
            dependencies: [

                .product(
                    name: "HTTPTypes",
                    package: "swift-http-types"
                ),

                .product(
                    name: "HTTPTypesFoundation",
                    package: "swift-http-types"
                ),

                .product(
                    name: "AliasWonderland",
                    package: "AliasWonderland"
                ),

                .product(
                    name: "OptionalAPI",
                    package: "OptionalAPI"
                ),

            ]
        ),

        .testTarget(
            name: "OnionTests",
            dependencies: [
                "Onion",

                .product(name: "ExTests", package: "ExTests"),

                .product(name: "InlineSnapshotTesting", package: "swift-snapshot-testing"),
            ]
        ),
    ]
)

for target in package.targets {
  var settings = target.swiftSettings ?? []
  settings.append(.enableExperimentalFeature("StrictConcurrency"))
  target.swiftSettings = settings
}
