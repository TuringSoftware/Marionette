// swift-tools-version: 6.2
// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "RemoteDesktopInteraction",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "RemoteDesktopInteraction", targets: ["RemoteDesktopInteraction"]),
    ],
    dependencies: [
        .package(path: "../RemoteDesktopCore"),
    ],
    targets: [
        .target(
            name: "RemoteDesktopInteraction",
            dependencies: [.product(name: "RemoteDesktopCore", package: "RemoteDesktopCore")],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "RemoteDesktopInteractionTests",
            dependencies: [
                "RemoteDesktopInteraction",
                .product(name: "RemoteDesktopCore", package: "RemoteDesktopCore"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
