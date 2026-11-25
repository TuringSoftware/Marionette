// swift-tools-version: 6.2
// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "RemoteDesktopTransport",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "RemoteDesktopTransport", targets: ["RemoteDesktopTransport"]),
    ],
    dependencies: [
        .package(path: "../RemoteDesktopCore"),
        .package(path: "../SwiftSSH2"),
    ],
    targets: [
        .target(
            name: "RemoteDesktopTransport",
            dependencies: [
                .product(name: "RemoteDesktopCore", package: "RemoteDesktopCore"),
                .product(name: "SwiftSSH2", package: "SwiftSSH2"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "RemoteDesktopTransportTests",
            dependencies: [
                "RemoteDesktopTransport",
                .product(name: "SwiftSSH2TestSupport", package: "SwiftSSH2"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
