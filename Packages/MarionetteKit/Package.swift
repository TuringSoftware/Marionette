// swift-tools-version: 6.2
// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "MarionetteKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "MarionetteKit", targets: ["MarionetteKit"]),
    ],
    dependencies: [
        .package(path: "../RemoteDesktopCore"),
        .package(path: "../RemoteDesktopInteraction"),
        .package(path: "../RemoteDesktopMedia"),
        .package(path: "../RemoteDesktopTransport"),
        .package(path: "../AppleScreenSharing"),
        .package(path: "../SwiftVNCClient"),
        .package(path: "../SwiftSSH2"),
    ],
    targets: [
        .target(
            name: "MarionetteKit",
            dependencies: [
                .product(name: "RemoteDesktopCore", package: "RemoteDesktopCore"),
                // The simulated back end backs the demo computer and the `-MarionetteScenario` environments.
                .product(name: "RemoteDesktopSimulated", package: "RemoteDesktopCore"),
                .product(name: "RemoteDesktopTransport", package: "RemoteDesktopTransport"),
                .product(name: "SwiftSSH2", package: "SwiftSSH2"),
                .product(name: "AppleScreenSharing", package: "AppleScreenSharing"),
                // GPL-3.0-or-later (it links LibVNCClient). MarionetteKit's own sources stay Apache-2.0, but
                // anything that ships MarionetteKit with this back end is distributed under the GPL.
                .product(name: "VNCBackend", package: "SwiftVNCClient"),
                .product(name: "RemoteDesktopInteraction", package: "RemoteDesktopInteraction"),
                .product(name: "RemoteDesktopRender", package: "RemoteDesktopMedia"),
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MarionetteKitTests",
            dependencies: [
                "MarionetteKit",
                .product(name: "RemoteDesktopCore", package: "RemoteDesktopCore"),
                .product(name: "RemoteDesktopSimulated", package: "RemoteDesktopCore"),
                .product(name: "RemoteDesktopInteraction", package: "RemoteDesktopInteraction"),
                .product(name: "RemoteDesktopTransport", package: "RemoteDesktopTransport"),
                .product(name: "SwiftSSH2TestSupport", package: "SwiftSSH2"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
