// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDCrypto
import ARDProtocol
import ARDTestSupport
import Foundation
import Synchronization
import Testing

/// The cipher that seals key and pointer events: one AES-128-ECB block under the record layer's key.
@Suite struct InputCipherTests {
    /// FIPS-197 appendix C.1, as an input message.
    @Test func sealsOneBlockUnderItsKey() throws {
        let cipher = try InputCipher(key: PrimitiveTests.fipsKey)
        #expect(cipher.message(flags: 0x00, block: PrimitiveTests.fipsPlain) == Data([0x10, 0x00]) + PrimitiveTests.fipsCipher)
        #expect(cipher.message(flags: 0x03, block: PrimitiveTests.fipsPlain) == Data([0x10, 0x03]) + PrimitiveTests.fipsCipher)
    }

    @Test func agreesWithTheBlockPrimitiveForEventBlocks() throws {
        let key = Data(hex: "3c4fcf098815f7aba6d2ae2816157e2b")
        let cipher = try InputCipher(key: key)
        let blocks = [
            EncryptedInputEvent.pointerBlock(buttonMask: 1, x: 1914, y: 140, elapsedMicroseconds: 159_218),
            EncryptedInputEvent.pointerBlock(buttonMask: 0, x: 0, y: 0, elapsedMicroseconds: 0),
            EncryptedInputEvent.keyBlock(keysym: 0x63, isDown: true, elapsedMicroseconds: 1_595_257),
            EncryptedInputEvent.keyBlock(keysym: 0xffeb, isDown: false, elapsedMicroseconds: .max),
        ]
        for block in blocks {
            let message = cipher.message(flags: EncryptedInputEvent.plainFlags, block: block)
            #expect(message.count == 2 + EncryptedInputEvent.blockLength)
            #expect(message.dropFirst(2) == (try AES128.encryptECB(block, key: key)))
            let opened = try AES128.decryptECB(Data(message.dropFirst(2)), key: key)
            #expect(opened == block)
            #expect(EncryptedInputEvent.parse(block: opened) == EncryptedInputEvent.parse(block: block))
        }
    }

    @Test func everyMessageStandsAlone() throws {
        let cipher = try InputCipher(key: PrimitiveTests.fipsKey)
        let first = cipher.message(flags: 1, block: PrimitiveTests.fipsPlain)
        _ = cipher.message(flags: 1, block: Data(count: 16))
        #expect(cipher.message(flags: 1, block: PrimitiveTests.fipsPlain) == first)
        // A slice whose startIndex is not zero.
        let tail = (Data(count: 5) + PrimitiveTests.fipsPlain).dropFirst(5)
        #expect(cipher.message(flags: 1, block: tail) == first)
    }

    @Test func onlyAnAES128KeyIsTaken() {
        #expect(throws: CryptoError.invalidKeyLength(0)) { _ = try InputCipher(key: Data()) }
        #expect(throws: CryptoError.invalidKeyLength(15)) { _ = try InputCipher(key: Data(count: 15)) }
        #expect(throws: CryptoError.invalidKeyLength(32)) { _ = try InputCipher(key: Data(count: 32)) }
    }

    /// Keys come from one thread and the pointer from another; a session has one cipher for both.
    @Test func sealsCorrectlyFromManyThreadsAtOnce() throws {
        let key = PrimitiveTests.fipsKey
        let cipher = try InputCipher(key: key)
        let blocks: [Data] = (0..<64).map { (index: Int) -> Data in
            EncryptedInputEvent.pointerBlock(buttonMask: 1, x: UInt16(index), y: UInt16(index * 3), elapsedMicroseconds: UInt32(index * 1000))
        }
        let expected: [Data] = try blocks.map { (block: Data) -> Data in
            EncryptedInputEvent.message(flags: 0x03, sealedBlock: try AES128.encryptECB(block, key: key))
        }
        let wrong = Mutex(0)
        DispatchQueue.concurrentPerform(iterations: 4000) { index in
            if cipher.message(flags: 0x03, block: blocks[index % blocks.count]) != expected[index % blocks.count] {
                wrong.withLock { $0 += 1 }
            }
        }
        #expect(wrong.withLock { $0 } == 0)
    }
}
