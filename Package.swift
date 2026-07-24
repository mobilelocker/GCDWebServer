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
        ),
        .library(
            name: "GCDWebDAVServer",
            targets: ["GCDWebDAVServer"]
        ),
        .library(
            name: "GCDWebUploader",
            targets: ["GCDWebUploader"]
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
                .linkedLibrary("z"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("UIKit")
            ]
        ),
        .target(
            name: "GCDWebDAVServer",
            dependencies: ["GCDWebServer"],
            path: "GCDWebDAVServer",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("../GCDWebServer/Core"),
                .headerSearchPath("../GCDWebServer/include")
            ],
            linkerSettings: [
                .linkedLibrary("xml2")
            ]
        ),
        .target(
            name: "GCDWebUploader",
            dependencies: ["GCDWebServer"],
            path: "GCDWebUploader",
            exclude: ["GCDWebUploader.bundle"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("../GCDWebServer/Core"),
                .headerSearchPath("../GCDWebServer/include")
            ],
            linkerSettings: [
                .linkedFramework("SystemConfiguration")
            ]
        ),
        .testTarget(
            name: "GCDWebServerTests",
            dependencies: ["GCDWebServer", "GCDWebDAVServer", "GCDWebUploader"],
            path: "Tests",
            cSettings: [
                .headerSearchPath("../GCDWebServer/Core"),
                .headerSearchPath("../GCDWebServer/include"),
                .headerSearchPath("../GCDWebDAVServer"),
                .headerSearchPath("../GCDWebUploader")
            ],
            linkerSettings: [
                .linkedLibrary("z")
            ]
        )
    ]
)
