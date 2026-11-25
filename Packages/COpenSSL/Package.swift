// swift-tools-version: 6.2
// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

// OpenSSL as a prebuilt static library. `OpenSSL.xcframework` is produced by
// `Scripts/build-deps.sh` from the pinned sources in `ThirdParty/openssl`; it is not checked in.
let package = Package(
    name: "COpenSSL",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "COpenSSL", targets: ["OpenSSL"]),
    ],
    targets: [
        .binaryTarget(name: "OpenSSL", path: "OpenSSL.xcframework"),
    ]
)
