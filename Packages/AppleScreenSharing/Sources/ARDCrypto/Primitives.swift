// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CommonCrypto
import CryptoKit
public import Foundation

/// Where secret random bytes come from. Injected so that protocol exchanges can be replayed
/// byte for byte in tests.
public protocol RandomSource: Sendable {
    func bytes(_ count: Int) -> Data
}

public struct SystemRandomSource: RandomSource {
    public init() {}

    public func bytes(_ count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

public enum CryptoError: Error, Sendable, Equatable {
    case invalidKeyLength(Int)
    case notBlockAligned(Int)
    case failure(String)
}

public enum Digest {
    public static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    public static func sha1(_ data: Data) -> Data {
        Data(Insecure.SHA1.hash(data: data))
    }

    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func sha512(_ data: Data) -> Data {
        Data(SHA512.hash(data: data))
    }
}

/// AES-128 on whole blocks.
public enum AES128 {
    public static let blockSize = 16

    public static func encryptECB(_ data: Data, key: Data) throws(CryptoError) -> Data {
        try crypt(CCOperation(kCCEncrypt), data, key: key)
    }

    public static func decryptECB(_ data: Data, key: Data) throws(CryptoError) -> Data {
        try crypt(CCOperation(kCCDecrypt), data, key: key)
    }

    private static func crypt(_ operation: CCOperation, _ data: Data, key: Data) throws(CryptoError) -> Data {
        guard key.count == kCCKeySizeAES128 else { throw .invalidKeyLength(key.count) }
        guard data.count % blockSize == 0 else { throw .notBlockAligned(data.count) }
        var output = Data(count: data.count)
        var moved = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                        keyBytes.baseAddress, keyBytes.count, nil,
                        input.baseAddress, input.count,
                        out.baseAddress, capacity, &moved
                    )
                }
            }
        }
        guard status == kCCSuccess, moved == data.count else { throw .failure("CCCrypt status \(status)") }
        return output
    }
}

/// One direction of an AES-128-CBC stream whose chain carries across calls.
///
/// Not thread-safe; each direction of a connection owns one.
public final class AES128CBCStream {
    private let cryptor: CCCryptorRef

    public enum Direction {
        case encrypt
        case decrypt
    }

    public init(_ direction: Direction, key: Data, iv: Data) throws(CryptoError) {
        guard key.count == kCCKeySizeAES128 else { throw .invalidKeyLength(key.count) }
        guard iv.count == AES128.blockSize else { throw .invalidKeyLength(iv.count) }
        var created: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreate(
                    CCOperation(direction == .encrypt ? kCCEncrypt : kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES), 0,
                    keyBytes.baseAddress, keyBytes.count, ivBytes.baseAddress, &created
                )
            }
        }
        guard status == kCCSuccess, let created else { throw .failure("CCCryptorCreate status \(status)") }
        cryptor = created
    }

    deinit {
        CCCryptorRelease(cryptor)
    }

    /// Transforms whole blocks, continuing the chain from the previous call.
    public func update(_ data: Data) throws(CryptoError) -> Data {
        guard data.count % AES128.blockSize == 0 else { throw .notBlockAligned(data.count) }
        var output = Data(count: data.count)
        var moved = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                CCCryptorUpdate(cryptor, input.baseAddress, input.count, out.baseAddress, capacity, &moved)
            }
        }
        guard status == kCCSuccess, moved == data.count else { throw .failure("CCCryptorUpdate status \(status)") }
        return output
    }
}
