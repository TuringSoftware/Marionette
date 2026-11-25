// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CommonCrypto
public import Foundation

/// Security type 2, RFB's classic VNC password: the server's 16-byte challenge encrypted with DES,
/// keyed by the first eight bytes of the password with each byte's bits reversed (RFC 6143 §7.2.2
/// and the reference implementations).
///
/// A last resort only: it proves nothing about the server, a captured exchange can be attacked
/// offline, and it agrees no key, so a session after it is not encrypted.
public enum VNCPasswordLogin {
    public static let challengeLength = 16

    public static func response(to challenge: Data, password: String) throws(CryptoError) -> Data {
        guard challenge.count == challengeLength else { throw .failure("a VNC challenge of \(challenge.count) bytes") }
        var key = [UInt8](repeating: 0, count: kCCKeySizeDES)
        for (index, byte) in password.utf8.prefix(kCCKeySizeDES).enumerated() {
            var reversed: UInt8 = 0
            for bit in 0..<8 where byte & (1 << bit) != 0 { reversed |= 0x80 >> bit }
            key[index] = reversed
        }
        var output = Data(count: challengeLength)
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            challenge.withUnsafeBytes { input in
                CCCrypt(
                    CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                    key, key.count, nil, input.baseAddress, input.count, out.baseAddress, challengeLength, &moved
                )
            }
        }
        guard status == kCCSuccess, moved == challengeLength else { throw .failure("CCCrypt status \(status)") }
        return output
    }
}
