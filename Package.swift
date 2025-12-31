// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftBONJSON",
    products: [
        .library(
            name: "SwiftBONJSON",
            targets: ["SwiftBONJSON"]
        ),
    ],
    targets: [
        // C library target for ksbonjson
        .target(
            name: "CKSBONJSON",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include/ksbonjson"),
                .define("KSBONJSON_MAX_CONTAINER_DEPTH", to: "200")
            ]
        ),
        // Swift wrapper target
        .target(
            name: "SwiftBONJSON",
            dependencies: ["CKSBONJSON"]
        ),
        .testTarget(
            name: "SwiftBONJSONTests",
            dependencies: ["SwiftBONJSON"]
        ),
    ]
)
