// swift-tools-version:6.0

import PackageDescription

let package = Package(
    name: "GCDWebServer",
    platforms: [
        .iOS(.v18)
    ],
    products: [
        .library(
            name: "GCDWebServer",
            targets: ["GCDWebServer"]
        )
    ],
    targets: [
        .target(
            name: "GCDWebServer",
            path: "GCDWebServer",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("Core"),
                .headerSearchPath("Requests"),
                .headerSearchPath("Responses")
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        )
    ]
)
