// swift-tools-version: 6.2
// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "RemoteDesktopCore",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "RemoteDesktopCore", targets: ["RemoteDesktopCore"]),
        .library(name: "RemoteDesktopSimulated", targets: ["RemoteDesktopSimulated"]),
        .library(name: "RemoteDesktopConformance", targets: ["RemoteDesktopConformance"]),
    ],
    targets: [
        .target(name: "RemoteDesktopCore"),
        .target(name: "RemoteDesktopSimulated", dependencies: ["RemoteDesktopCore"], resources: [.process("Resources")]),
        .target(name: "RemoteDesktopConformance", dependencies: ["RemoteDesktopCore"]),
        .testTarget(
            name: "RemoteDesktopCoreTests",
            dependencies: ["RemoteDesktopCore", "RemoteDesktopSimulated", "RemoteDesktopConformance"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
