// swift-tools-version: 6.2
// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
    name: "SwiftSRTP",
    platforms: [.iOS(.v26), .macOS(.v26), .visionOS(.v26)],
    products: [
        .library(name: "SwiftSRTP", targets: ["SwiftSRTP"]),
    ],
    targets: [
        // cisco/libsrtp, pinned as a git submodule and compiled from source with its built-in
        // AES and SHA-1, so the package has no binary dependency.
        .target(
            name: "CLibSRTP",
            sources: [
                "libsrtp/srtp/srtp.c",
                "libsrtp/crypto/cipher/cipher.c",
                "libsrtp/crypto/cipher/cipher_test_cases.c",
                "libsrtp/crypto/cipher/null_cipher.c",
                "libsrtp/crypto/cipher/aes.c",
                "libsrtp/crypto/cipher/aes_icm.c",
                "libsrtp/crypto/hash/auth.c",
                "libsrtp/crypto/hash/auth_test_cases.c",
                "libsrtp/crypto/hash/null_auth.c",
                "libsrtp/crypto/hash/hmac.c",
                "libsrtp/crypto/hash/sha1.c",
                "libsrtp/crypto/kernel/alloc.c",
                "libsrtp/crypto/kernel/crypto_kernel.c",
                "libsrtp/crypto/kernel/err.c",
                "libsrtp/crypto/kernel/key.c",
                "libsrtp/crypto/math/datatypes.c",
                "libsrtp/crypto/replay/rdb.c",
                "libsrtp/crypto/replay/rdbx.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .define("HAVE_CONFIG_H"),
                .headerSearchPath("config"),
                .headerSearchPath("libsrtp/include"),
                .headerSearchPath("libsrtp/crypto/include"),
            ]
        ),
        .target(name: "SwiftSRTP", dependencies: ["CLibSRTP"]),
        .testTarget(name: "SwiftSRTPTests", dependencies: ["SwiftSRTP"]),
    ],
    swiftLanguageModes: [.v6]
)
