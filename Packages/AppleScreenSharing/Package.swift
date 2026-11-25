// swift-tools-version: 6.2
// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "AppleScreenSharing",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "AppleScreenSharing", targets: ["AppleScreenSharing"]),
        .library(name: "ARDProtocol", targets: ["ARDProtocol"]),
        // For tools that stand between a viewer and a Mac (marionettectl proxy).
        .library(name: "ARDCrypto", targets: ["ARDCrypto"]),
    ],
    dependencies: [
        .package(path: "../RemoteDesktopCore"),
        .package(path: "../SwiftSRTP"),
        .package(path: "../RemoteDesktopDecode"),
        .package(path: "../RemoteDesktopTransport"),
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.7.0"),
    ],
    targets: [
        // Wire formats and parsers. No cryptography and no I/O, so it can be fuzzed on its own.
        .target(
            name: "ARDProtocol",
            dependencies: [.product(name: "RemoteDesktopCore", package: "RemoteDesktopCore")],
            resources: [.process("Resources")],
            // Optimised in every configuration, as ARDCrypto is: unoptimised, Adaptive quality's
            // tile decoder took 4.2 s for one whole 2048 × 1536 update, against tens of milliseconds.
            swiftSettings: [.unsafeFlags(["-O"])],
            linkerSettings: [.linkedLibrary("z")]
        ),
        // Login mathematics and the record layer. No I/O.
        .target(
            name: "ARDCrypto",
            dependencies: ["ARDProtocol", .product(name: "BigInt", package: "BigInt")],
            // Optimised in every configuration: unoptimised, a login's 4096-bit arithmetic takes
            // seconds, and debug builds are where the app is run most.
            swiftSettings: [.unsafeFlags(["-O"])]
        ),
        .target(
            name: "AppleScreenSharing",
            dependencies: [
                "ARDProtocol",
                "ARDCrypto",
                .product(name: "RemoteDesktopCore", package: "RemoteDesktopCore"),
                .product(name: "SwiftSRTP", package: "SwiftSRTP"),
                .product(name: "RemoteDesktopDecode", package: "RemoteDesktopDecode"),
            ],
            resources: [.process("Resources")]
        ),
        .target(name: "ARDTestSupport", path: "Tests/ARDTestSupport"),
        .testTarget(name: "ARDProtocolTests", dependencies: ["ARDProtocol", "ARDTestSupport"], resources: [.copy("Fixtures")]),
        .testTarget(name: "ARDCryptoTests", dependencies: ["ARDCrypto", "ARDTestSupport"]),
        .testTarget(
            name: "AppleScreenSharingTests",
            dependencies: [
                "AppleScreenSharing",
                "ARDProtocol",
                "ARDCrypto",
                .product(name: "BigInt", package: "BigInt"),
                .product(name: "RemoteDesktopDecode", package: "RemoteDesktopDecode"),
                .product(name: "SwiftSRTP", package: "SwiftSRTP"),
                .product(name: "RemoteDesktopConformance", package: "RemoteDesktopCore"),
                .product(name: "RemoteDesktopTransport", package: "RemoteDesktopTransport"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
