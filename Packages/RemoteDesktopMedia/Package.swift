// swift-tools-version: 6.2
// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

// `RemoteDesktopRender` is what front ends link: it turns `DisplayFrame`s and `AudioChunk`s into
// pixels and sound. It must not depend on `RemoteDesktopDecode`, which back ends link.
let package = Package(
    name: "RemoteDesktopMedia",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "RemoteDesktopRender", targets: ["RemoteDesktopRender"]),
    ],
    dependencies: [
        .package(path: "../RemoteDesktopCore"),
    ],
    targets: [
        .target(
            name: "RemoteDesktopRender",
            dependencies: [.product(name: "RemoteDesktopCore", package: "RemoteDesktopCore")]
        ),
        .testTarget(
            name: "RemoteDesktopRenderTests",
            dependencies: [
                "RemoteDesktopRender",
                .product(name: "RemoteDesktopCore", package: "RemoteDesktopCore"),
                .product(name: "RemoteDesktopSimulated", package: "RemoteDesktopCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
