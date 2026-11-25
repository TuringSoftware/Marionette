// swift-tools-version: 6.2
// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "marionettectl",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/RemoteDesktopCore"),
        .package(path: "../../Packages/RemoteDesktopTransport"),
        .package(path: "../../Packages/AppleScreenSharing"),
        .package(path: "../../Packages/RemoteDesktopDecode"),
        // Linking the VNC back end makes the built tool GPL-3.0-or-later; its own sources stay Apache-2.0.
        .package(path: "../../Packages/SwiftVNCClient"),
    ],
    targets: [
        .executableTarget(
            name: "marionettectl",
            dependencies: [
                .product(name: "RemoteDesktopCore", package: "RemoteDesktopCore"),
                .product(name: "RemoteDesktopTransport", package: "RemoteDesktopTransport"),
                .product(name: "AppleScreenSharing", package: "AppleScreenSharing"),
                .product(name: "ARDProtocol", package: "AppleScreenSharing"),
                .product(name: "ARDCrypto", package: "AppleScreenSharing"),
                .product(name: "RemoteDesktopDecode", package: "RemoteDesktopDecode"),
                .product(name: "VNCBackend", package: "SwiftVNCClient"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
