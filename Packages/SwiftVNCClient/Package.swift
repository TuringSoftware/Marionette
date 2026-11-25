// swift-tools-version: 6.2
// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "SwiftVNCClient",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "SwiftVNCClient", targets: ["SwiftVNCClient"]),
        .library(name: "VNCBackend", targets: ["VNCBackend"]),
    ],
    dependencies: [
        .package(path: "../COpenSSL"),
        .package(path: "../RemoteDesktopCore"),
        .package(path: "../RemoteDesktopTransport"),
    ],
    targets: [
        // LibVNCClient (the client half of LibVNCServer), pinned as a git submodule and compiled
        // from source. GPL-2.0-or-later, which makes everything that links this package GPL.
        .target(
            name: "CLibVNCClient",
            dependencies: [.product(name: "COpenSSL", package: "COpenSSL")],
            sources: [
                "shim/shim.c",
                "shim/jpeg.c",
                "libvncserver/src/libvncclient/cursor.c",
                "libvncserver/src/libvncclient/listen.c",
                // rfbclient.c includes the encoding decoders (zrle.c, hextile.c, ...) as templates.
                "libvncserver/src/libvncclient/rfbclient.c",
                "libvncserver/src/libvncclient/sockets.c",
                "libvncserver/src/libvncclient/vncviewer.c",
                "libvncserver/src/libvncclient/tls_openssl.c",
                "libvncserver/src/common/sockets.c",
                "libvncserver/src/common/crypto_openssl.c",
                "libvncserver/src/common/minilzo.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("config"),
                .headerSearchPath("libvncserver/include"),
                .headerSearchPath("libvncserver/src/common"),
                .headerSearchPath("libvncserver/src/libvncclient"),
                // Upstream's warnings are upstream's; they would bury our own.
                .unsafeFlags(["-w"]),
            ],
            linkerSettings: [.linkedLibrary("z"), .linkedFramework("CoreGraphics")]
        ),
        .target(name: "SwiftVNCClient", dependencies: ["CLibVNCClient"], resources: [.process("Resources")]),
        .target(
            name: "VNCBackend",
            dependencies: ["SwiftVNCClient", .product(name: "RemoteDesktopCore", package: "RemoteDesktopCore")],
            resources: [.process("Resources")]
        ),
        // A scripted RFB server over an in-memory pipe, for this package's tests.
        .target(name: "SwiftVNCClientTestSupport", dependencies: ["SwiftVNCClient"]),
        .testTarget(name: "SwiftVNCClientTests", dependencies: ["CLibVNCClient", "SwiftVNCClient", "SwiftVNCClientTestSupport"]),
        .testTarget(
            name: "VNCBackendTests",
            dependencies: [
                "VNCBackend",
                "SwiftVNCClientTestSupport",
                .product(name: "RemoteDesktopConformance", package: "RemoteDesktopCore"),
                .product(name: "RemoteDesktopTransport", package: "RemoteDesktopTransport"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
