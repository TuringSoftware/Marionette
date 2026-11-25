// swift-tools-version: 6.2
// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "RemoteDesktopDecode",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "RemoteDesktopDecode", targets: ["RemoteDesktopDecode"]),
    ],
    targets: [
        .target(name: "RemoteDesktopDecode"),
        .testTarget(
            name: "RemoteDesktopDecodeTests",
            dependencies: ["RemoteDesktopDecode"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
