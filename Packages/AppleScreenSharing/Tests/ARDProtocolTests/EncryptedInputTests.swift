// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
import ARDTestSupport
import Foundation
import Testing

/// The blocks inside `EncryptedInputEvent` messages, against two that Screen Sharing.app sent to
/// macOS 27.0.1 (decrypted with the session's record key by `marionettectl proxy`).
@Suite struct EncryptedInputEventTests {
    /// A press of the left button at (1914, 140), 159,218 µs after the event before it.
    static let recordedPointer = Data(hex: "00 00 00 00 00 00 00 02 6d f2 ff 01 07 7a 00 8c")
    /// "c" going down 1,595,257 µs after the event before it, from keyboard type 0x5b, key code 8.
    static let recordedKey = Data(hex: "ff 01 00 00 00 63 00 18 57 79 00 00 00 5b 00 08")

    @Test func aPointerBlockIsLaidOutAsScreenSharingLaysItOut() {
        let block = EncryptedInputEvent.pointerBlock(buttonMask: 1, x: 1914, y: 140, elapsedMicroseconds: 159_218)
        #expect(block == Self.recordedPointer)
        #expect(EncryptedInputEvent.parse(block: Self.recordedPointer) == .pointer(buttonMask: 1, x: 1914, y: 140))
    }

    /// This client names a key by its keysym alone: the six bytes where Screen Sharing.app puts
    /// its keyboard's type and the key's code stay zero. Everything before them is the same.
    @Test func aKeyBlockMatchesScreenSharingsUpToTheKeyCode() {
        let block = EncryptedInputEvent.keyBlock(keysym: 0x63, isDown: true, elapsedMicroseconds: 1_595_257)
        #expect(block.count == EncryptedInputEvent.blockLength)
        #expect(block.prefix(10) == Self.recordedKey.prefix(10))
        #expect(block.suffix(6) == Data(count: 6))
        #expect(EncryptedInputEvent.parse(block: Self.recordedKey) == .key(keysym: 0x63, isDown: true))
        #expect(EncryptedInputEvent.parse(block: block) == .key(keysym: 0x63, isDown: true))
    }

    @Test func blocksReadBackAsWhatWasPutIn() {
        let pointers: [(UInt8, UInt16, UInt16, UInt32)] = [(0, 0, 0, 0), (1, 10, 20, 1), (5, .max, .max, .max), (2, 0x1234, 0xabcd, 16_667)]
        for (mask, x, y, elapsed) in pointers {
            let block = EncryptedInputEvent.pointerBlock(buttonMask: mask, x: x, y: y, elapsedMicroseconds: elapsed)
            #expect(block.count == EncryptedInputEvent.blockLength)
            #expect(EncryptedInputEvent.parse(block: block) == .pointer(buttonMask: mask, x: x, y: y))
            #expect(block.prefix(6) == Data(count: 6))
            #expect(block.dropFirst(6).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } == elapsed)
        }
        // A keysym from every range the keyboard sends: Latin-1, a function key, a modifier, and
        // a Unicode keysym; a pointer's marker byte in the time must not make a key a pointer event.
        for (keysym, isDown, elapsed) in [(0x61, true, 0), (0xffbe, false, 250_000), (0xffeb, true, .max), (0x0100_20ac, false, 0xff00_00ff)] as [(UInt32, Bool, UInt32)] {
            let block = EncryptedInputEvent.keyBlock(keysym: keysym, isDown: isDown, elapsedMicroseconds: elapsed)
            #expect(block.count == EncryptedInputEvent.blockLength)
            #expect(EncryptedInputEvent.parse(block: block) == .key(keysym: keysym, isDown: isDown))
            #expect(block.dropFirst(6).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } == elapsed)
        }
    }

    /// No flag is set on anything this client sends. On a pointer event bit 0 would say that the
    /// viewer supplies the click count (in bits 1–3), and on a key event bit 1 that the Mac should
    /// go by the key code in the block; with neither, the Mac counts clicks from the elapsed times
    /// and maps the keysym itself.
    @Test func noFlagIsSetOnWhatThisClientSends() {
        #expect(EncryptedInputEvent.plainFlags == 0x00)
    }

    @Test func theMessageIsTheTypeTheFlagsAndTheSealedBlock() {
        let sealed = Data((0..<16).map { UInt8($0 &* 17) })
        let message = EncryptedInputEvent.message(flags: 0x03, sealedBlock: sealed)
        #expect(message == Data([0x10, 0x03]) + sealed)
        #expect(ClientMessageType.encryptedInputEvent == 0x10)
    }

    /// What is in a block is whatever the peer's key made of sixteen bytes: anything at all.
    @Test func blocksThatAreNotEventsAreRefusedAndNoneTraps() {
        #expect(EncryptedInputEvent.parse(block: Data()) == nil)
        #expect(EncryptedInputEvent.parse(block: Self.recordedPointer.dropLast()) == nil)
        #expect(EncryptedInputEvent.parse(block: Self.recordedKey + Data([0])) == nil)
        #expect(EncryptedInputEvent.parse(block: Data(count: 16)) == nil)
        // Neither marker where one belongs.
        #expect(EncryptedInputEvent.parse(block: Data(hex: "01 01 00 00 00 63 00 00 00 00 fe 01 00 0a 00 14")) == nil)
        // A slice whose startIndex is not zero.
        let tail = (Data(count: 7) + Self.recordedPointer).dropFirst(7)
        #expect(EncryptedInputEvent.parse(block: tail) == .pointer(buttonMask: 1, x: 1914, y: 140))

        var generator = SeededGenerator(seed: 16)
        for _ in 0..<20_000 {
            let length = Int.random(in: 0...40, using: &generator)
            var bytes = (0..<length).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            // Most random blocks carry no marker; put one where it counts in half of them.
            if length == 16, Bool.random(using: &generator) { bytes[Bool.random(using: &generator) ? 0 : 10] = 0xff }
            let event = EncryptedInputEvent.parse(block: Data(bytes))
            if length != 16 { #expect(event == nil) }
        }
    }
}
