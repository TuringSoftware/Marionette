// swift-tools-version: 6.2
// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "SwiftSSH2",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "SwiftSSH2", targets: ["SwiftSSH2"]),
        // A private OpenSSH server and friends, for this package's tests and its dependents'.
        .library(name: "SwiftSSH2TestSupport", targets: ["SwiftSSH2TestSupport"]),
    ],
    dependencies: [
        .package(path: "../COpenSSL"),
    ],
    targets: [
        .target(
            name: "CLibSSH2",
            dependencies: [.product(name: "COpenSSL", package: "COpenSSL")],
            sources: [
                "shim/shim.c",
                "libssh2/src/agent.c",
                "libssh2/src/bcrypt_pbkdf.c",
                "libssh2/src/chacha.c",
                "libssh2/src/channel.c",
                "libssh2/src/cipher-chachapoly.c",
                "libssh2/src/comp.c",
                "libssh2/src/crypt.c",
                // crypto.c includes the back end chosen in the configuration (openssl.c).
                "libssh2/src/crypto.c",
                "libssh2/src/global.c",
                "libssh2/src/hostkey.c",
                "libssh2/src/keepalive.c",
                "libssh2/src/kex.c",
                "libssh2/src/knownhost.c",
                "libssh2/src/mac.c",
                "libssh2/src/misc.c",
                "libssh2/src/packet.c",
                "libssh2/src/pem.c",
                "libssh2/src/poly1305.c",
                "libssh2/src/publickey.c",
                "libssh2/src/scp.c",
                "libssh2/src/session.c",
                "libssh2/src/sftp.c",
                "libssh2/src/transport.c",
                "libssh2/src/userauth.c",
                "libssh2/src/userauth_kbd_packet.c",
                "libssh2/src/version.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("config"),
                .headerSearchPath("libssh2/include"),
                .headerSearchPath("libssh2/src"),
            ]
        ),
        .target(name: "SwiftSSH2", dependencies: ["CLibSSH2"]),
        .target(name: "SwiftSSH2TestSupport", dependencies: ["SwiftSSH2"]),
        .testTarget(name: "SwiftSSH2Tests", dependencies: ["SwiftSSH2", "SwiftSSH2TestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
