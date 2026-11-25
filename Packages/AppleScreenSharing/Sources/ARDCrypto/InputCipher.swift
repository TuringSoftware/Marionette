// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import ARDProtocol
import CommonCrypto
public import Foundation
import Synchronization

/// Seals key and pointer events as `EncryptedInputEvent` messages: one AES-128-ECB block each,
/// under the key of the record layer (the one its rekey installed, not the login's).
///
/// One key schedule serves the whole session; a pointer can send more than a hundred events a
/// second. Safe to use from any thread.
public final class InputCipher: Sendable {
    /// CommonCrypto's cryptor, which is not safe to share without a lock.
    private struct Cryptor: @unchecked Sendable {
        let reference: CCCryptorRef
    }

    private let cryptor: Mutex<Cryptor>

    public init(key: Data) throws(CryptoError) {
        guard key.count == kCCKeySizeAES128 else { throw .invalidKeyLength(key.count) }
        var reference: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            CCCryptorCreateWithMode(
                CCOperation(kCCEncrypt), CCMode(kCCModeECB), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                nil, keyBytes.baseAddress, keyBytes.count, nil, 0, 0, 0, &reference
            )
        }
        guard status == kCCSuccess, let reference else { throw .failure("CCCryptorCreateWithMode status \(status)") }
        cryptor = Mutex(Cryptor(reference: reference))
    }

    deinit {
        cryptor.withLock { _ = CCCryptorRelease($0.reference) }
    }

    /// The complete message for one event block (``EncryptedInputEvent/pointerBlock(buttonMask:x:y:elapsedMicroseconds:)``
    /// or the key one).
    public func message(flags: UInt8, block: Data) -> Data {
        precondition(block.count == EncryptedInputEvent.blockLength)
        var sealed = Data(count: EncryptedInputEvent.blockLength)
        var moved = 0
        let status = cryptor.withLock { cryptor in
            sealed.withUnsafeMutableBytes { output in
                block.withUnsafeBytes { input in
                    CCCryptorUpdate(cryptor.reference, input.baseAddress, input.count, output.baseAddress, output.count, &moved)
                }
            }
        }
        // A whole block into an unpadded ECB cryptor cannot fail.
        precondition(status == kCCSuccess && moved == EncryptedInputEvent.blockLength)
        return EncryptedInputEvent.message(flags: flags, sealedBlock: sealed)
    }
}
