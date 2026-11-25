// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDCrypto
import ARDProtocol
import ARDTestSupport
import BigInt
import Foundation
import Testing

/// Hands out a fixed byte pattern, so exchanges are reproducible.
struct CountingRandom: RandomSource {
    var start: UInt8 = 1

    func bytes(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: Int(start) + $0 * 13) })
    }
}

@Suite struct PrimitiveTests {
    // FIPS-197 appendix C.1.
    static let fipsKey = Data(hex: "000102030405060708090a0b0c0d0e0f")
    static let fipsPlain = Data(hex: "00112233445566778899aabbccddeeff")
    static let fipsCipher = Data(hex: "69c4e0d86a7b0430d8cdb78070b4c55a")

    @Test func aesECBKnownAnswer() throws {
        #expect(try AES128.encryptECB(Self.fipsPlain, key: Self.fipsKey) == Self.fipsCipher)
        #expect(try AES128.decryptECB(Self.fipsCipher, key: Self.fipsKey) == Self.fipsPlain)
        // ECB: equal blocks encrypt equally, independent of position.
        #expect(try AES128.encryptECB(Self.fipsPlain + Self.fipsPlain, key: Self.fipsKey) == Self.fipsCipher + Self.fipsCipher)
    }

    @Test func aesRejectsBadSizes() {
        #expect(throws: CryptoError.invalidKeyLength(5)) { try AES128.encryptECB(Self.fipsPlain, key: Data(count: 5)) }
        #expect(throws: CryptoError.notBlockAligned(15)) { try AES128.encryptECB(Data(count: 15), key: Self.fipsKey) }
        #expect(throws: CryptoError.invalidKeyLength(8)) { _ = try AES128CBCStream(.encrypt, key: Self.fipsKey, iv: Data(count: 8)) }
    }

    // NIST SP 800-38A F.2.1, CBC-AES128.
    static let cbcKey = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")
    static let cbcIV = Data(hex: "000102030405060708090a0b0c0d0e0f")
    static let cbcPlain = Data(hex: """
        6bc1bee22e409f96e93d7e117393172a ae2d8a571e03ac9c9eb76fac45af8e51
        30c81c46a35ce411e5fbc1191a0a52ef f69f2445df4f9b17ad2b417be66c3710
        """)
    static let cbcCipher = Data(hex: """
        7649abac8119b246cee98e9b12e9197d 5086cb9b507219ee95db113a917678b2
        73bed6b8e3c1743b7116e69e22229516 3ff1caa1681fac09120eca307586e1a7
        """)

    @Test func cbcKnownAnswerAndChainCarriesAcrossCalls() throws {
        let whole = try AES128CBCStream(.encrypt, key: Self.cbcKey, iv: Self.cbcIV)
        #expect(try whole.update(Self.cbcPlain) == Self.cbcCipher)

        let pieces = try AES128CBCStream(.encrypt, key: Self.cbcKey, iv: Self.cbcIV)
        var joined = Data()
        for offset in stride(from: 0, to: 64, by: 16) {
            joined.append(try pieces.update(Self.cbcPlain.subdata(in: offset..<(offset + 16))))
        }
        #expect(joined == Self.cbcCipher)

        let decryptor = try AES128CBCStream(.decrypt, key: Self.cbcKey, iv: Self.cbcIV)
        #expect(try decryptor.update(Self.cbcCipher.prefix(32)) + decryptor.update(Self.cbcCipher.suffix(32)) == Self.cbcPlain)
    }

    @Test func digestsKnownAnswers() {
        #expect(Digest.md5(Data("abc".utf8)).hex == "900150983cd24fb0d6963f7d28e17f72")
        #expect(Digest.sha1(Data("abc".utf8)).hex == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(Digest.sha256(Data("abc".utf8)).hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

@Suite struct RecordLayerTests {
    static let keys = RecordKeys(key: Data(hex: "00112233445566778899aabbccddeeff"), iv: Data(hex: "0f0e0d0c0b0a09080706050403020100"))

    private func open(_ ciphertext: Data, chunk: Int, with opener: RecordOpener) throws -> Data {
        var cipher = InboundBuffer()
        var plain = InboundBuffer()
        var offset = 0
        while offset < ciphertext.count {
            let end = min(ciphertext.count, offset + chunk)
            cipher.append(ciphertext.subdata(in: offset..<end))
            offset = end
            try opener.open(from: &cipher, into: &plain)
        }
        #expect(cipher.isEmpty)
        return plain.drain()
    }

    @Test func rekeyHalvesAreUnwrappedIndependently() throws {
        let wrapKey = Data(hex: "000102030405060708090a0b0c0d0e0f")
        let key = Data(hex: "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf")
        let iv = Data(hex: "b0b1b2b3b4b5b6b7b8b9babbbcbdbebf")
        let body = Data(hex: "00000003") + (try AES128.encryptECB(key, key: wrapKey)) + (try AES128.encryptECB(iv, key: wrapKey))
        let unwrapped = try RecordKeys.unwrap(body, wrapKey: wrapKey)
        #expect(unwrapped.generation == 3)
        #expect(unwrapped.keys == RecordKeys(key: key, iv: iv))
        // Works on a slice that does not start at index zero.
        let padded = Data([0xFF]) + body
        #expect(try RecordKeys.unwrap(padded.dropFirst(), wrapKey: wrapKey).keys == RecordKeys(key: key, iv: iv))
        #expect(throws: CryptoError.self) { _ = try RecordKeys.unwrap(body.dropLast(), wrapKey: wrapKey) }
    }

    @Test func recordHasTheSpecifiedShape() throws {
        // Body of 4: 2 + 4 + filler + 20 rounds up to 32, so filler is 6.
        let message = Data([0x0a, 0x00, 0x00, 0x01])
        let sealed = try RecordSealer(keys: Self.keys).seal(message)
        #expect(sealed.count == 2 + 32)
        #expect(sealed.prefix(2) == Data([0x00, 0x20]))

        let clear = try AES128CBCStream(.decrypt, key: Self.keys.key, iv: Self.keys.iv).update(sealed.dropFirst(2))
        #expect(clear.prefix(2) == Data([0x00, 0x04]))
        #expect(clear.subdata(in: 2..<6) == message)
        #expect(clear.subdata(in: 6..<12) == Data(count: 6))
        // The trailer covers the big-endian sequence number, then everything before the trailer.
        #expect(clear.suffix(20) == Digest.sha1(Data([0, 0, 0, 0]) + clear.prefix(12)))
    }

    @Test(arguments: [0, 1, 9, 10, 11, 26, 27, 4096, 65_497, 65_498])
    func roundTripsSingleRecordSizes(_ length: Int) throws {
        let message = Data((0..<length).map { UInt8(truncatingIfNeeded: $0) })
        let sealed = try RecordSealer(keys: Self.keys).seal(message)
        let recordLength = Int(sealed[0]) << 8 | Int(sealed[1])
        #expect(recordLength % 16 == 0)
        #expect(recordLength == sealed.count - 2)
        #expect(recordLength <= 65_520)
        #expect(try open(sealed, chunk: sealed.count, with: RecordOpener(keys: Self.keys)) == message)
    }

    @Test func largeMessageSpansRecordsAndReassembles() throws {
        let message = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let sealed = try RecordSealer(keys: Self.keys).seal(message)
        // 200,000 bytes at 65,498 per record is four records.
        var count = 0
        var offset = 0
        while offset < sealed.count {
            offset += 2 + (Int(sealed[offset]) << 8 | Int(sealed[offset + 1]))
            count += 1
        }
        #expect(count == 4)
        #expect(try open(sealed, chunk: 1, with: RecordOpener(keys: Self.keys)) == message)
        #expect(try open(sealed, chunk: 7919, with: RecordOpener(keys: Self.keys)) == message)
    }

    @Test func consecutiveMessagesChainAndCount() throws {
        let sealer = try RecordSealer(keys: Self.keys)
        let opener = try RecordOpener(keys: Self.keys)
        let first = try sealer.seal(Data("one".utf8))
        let second = try sealer.seal(Data("one".utf8))
        // Same plaintext, different ciphertext: the chain and the sequence number both moved.
        #expect(first != second)
        #expect(try open(first + second, chunk: 5, with: opener) == Data("oneone".utf8))
    }

    @Test func outOfOrderRecordFailsIntegrity() throws {
        let sealer = try RecordSealer(keys: Self.keys)
        _ = try sealer.seal(Data("first".utf8))
        let second = try sealer.seal(Data("second".utf8))
        var cipher = InboundBuffer()
        var plain = InboundBuffer()
        cipher.append(second)
        #expect(throws: RecordError.integrityFailure(sequence: 0)) {
            try RecordOpener(keys: Self.keys).open(from: &cipher, into: &plain)
        }
        #expect(plain.isEmpty)
    }

    @Test func tamperingAnywhereYieldsNoPlaintext() throws {
        let sealed = try RecordSealer(keys: Self.keys).seal(Data("attack at dawn, bring snacks".utf8))
        for index in 2..<sealed.count {
            var tampered = sealed
            tampered[index] ^= 0x01
            var cipher = InboundBuffer()
            var plain = InboundBuffer()
            cipher.append(tampered)
            #expect(throws: RecordError.self, "byte \(index)") {
                try RecordOpener(keys: Self.keys).open(from: &cipher, into: &plain)
            }
            #expect(plain.isEmpty)
        }
    }

    @Test(arguments: [0, 16, 17, 31, 33])
    func misframedLengthIsRefusedBeforeDecrypting(_ length: Int) throws {
        var cipher = InboundBuffer()
        var plain = InboundBuffer()
        cipher.append(Data([UInt8(length >> 8), UInt8(length & 0xff)]) + Data(count: length))
        #expect(throws: RecordError.misframed(length: length)) {
            try RecordOpener(keys: Self.keys).open(from: &cipher, into: &plain)
        }
    }

    @Test func wrongKeyFailsIntegrity() throws {
        let sealed = try RecordSealer(keys: Self.keys).seal(Data("secret".utf8))
        var other = Self.keys
        other.key[0] ^= 0xFF
        var cipher = InboundBuffer()
        var plain = InboundBuffer()
        cipher.append(sealed)
        #expect(throws: RecordError.integrityFailure(sequence: 0)) {
            try RecordOpener(keys: other).open(from: &cipher, into: &plain)
        }
    }

    @Test func partialRecordWaitsWithoutAdvancingTheChain() throws {
        let sealer = try RecordSealer(keys: Self.keys)
        let opener = try RecordOpener(keys: Self.keys)
        let sealed = try sealer.seal(Data("patience".utf8))
        var cipher = InboundBuffer()
        var plain = InboundBuffer()
        cipher.append(sealed.dropLast())
        try opener.open(from: &cipher, into: &plain)
        try opener.open(from: &cipher, into: &plain)
        #expect(plain.isEmpty)
        cipher.append(sealed.suffix(1))
        try opener.open(from: &cipher, into: &plain)
        #expect(plain.drain() == Data("patience".utf8))
    }
}

@Suite struct DiffieHellmanLoginTests {
    // RFC 5054 appendix A, 1024-bit group.
    static let prime = Data(hex: """
        EEAF0AB9ADB38DD69C33F80AFA8FC5E86072618775FF3C0B9EA2314C9C256576D674DF7496EA81D3383B4813D692C6E0
        E0D5D8E250B98BE48E495C1D6089DAD15DC7D7B46154D6B6CE8EF4AD69B15D4982559B297BCF1885C529F566660E57EC
        68EDBC3C05726CC02FD4CBF4976EAA9AFD5138FE8376435B9FC61D2FC0EB06E3
        """)

    private func challenge(serverPrivate: BigUInt, generator: UInt16 = 2) -> (bytes: Data, parsed: DiffieHellmanLogin.Challenge) {
        let p = BigUInt(Self.prime)
        let serverPublic = BigUInt(generator).power(serverPrivate, modulus: p)
        var writer = WireWriter()
        writer.u16(generator)
        writer.u16(UInt16(Self.prime.count))
        writer.bytes(Self.prime)
        writer.bytes(Data(count: Self.prime.count - serverPublic.serialize().count) + serverPublic.serialize())
        var reader = WireReader(writer.data)
        return (writer.data, try! DiffieHellmanLogin.Challenge.parse(&reader))
    }

    @Test func serverRecoversCredentialsAndBothSidesAgreeOnTheKey() throws {
        let serverPrivate = BigUInt(Data(hex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
        let (_, challenge) = challenge(serverPrivate: serverPrivate)
        #expect(challenge.keyLength == 128)

        let response = try DiffieHellmanLogin.respond(to: challenge, username: "dev", password: "pässword", random: CountingRandom())
        #expect(response.message.count == 128 + 128)

        // The server's side of the exchange.
        let clientPublic = BigUInt(response.message.suffix(128))
        let shared = clientPublic.power(serverPrivate, modulus: BigUInt(Self.prime))
        let serialized = shared.serialize()
        let key = Digest.md5(Data(count: 128 - serialized.count) + serialized)
        #expect(key == response.wrapKey)
        let block = try AES128.decryptECB(response.message.prefix(128), key: key)
        #expect(String(decoding: block.prefix { $0 != 0 }, as: UTF8.self) == "dev")
        #expect(String(decoding: block.dropFirst(64).prefix { $0 != 0 }, as: UTF8.self) == "pässword")
    }

    @Test func sameInputsGiveSameBytesAndDifferentRandomDiffers() throws {
        let (_, challenge) = challenge(serverPrivate: 12345)
        let first = try DiffieHellmanLogin.respond(to: challenge, username: "a", password: "b", random: CountingRandom(start: 1))
        let again = try DiffieHellmanLogin.respond(to: challenge, username: "a", password: "b", random: CountingRandom(start: 1))
        let other = try DiffieHellmanLogin.respond(to: challenge, username: "a", password: "b", random: CountingRandom(start: 2))
        #expect(first == again)
        #expect(first.message != other.message)
        #expect(first.wrapKey != other.wrapKey)
    }

    @Test func credentialsMustFitTheirField() {
        let (_, challenge) = challenge(serverPrivate: 12345)
        let long = String(repeating: "x", count: 64)
        let fits = String(repeating: "x", count: 63)
        #expect(throws: DiffieHellmanLogin.LoginError.credentialTooLong) {
            _ = try DiffieHellmanLogin.respond(to: challenge, username: "u", password: long, random: CountingRandom())
        }
        #expect(throws: DiffieHellmanLogin.LoginError.credentialTooLong) {
            _ = try DiffieHellmanLogin.respond(to: challenge, username: long, password: "p", random: CountingRandom())
        }
        #expect(throws: Never.self) {
            _ = try DiffieHellmanLogin.respond(to: challenge, username: fits, password: fits, random: CountingRandom())
        }
    }

    @Test func degenerateServerParametersAreRefused() throws {
        // A public key of 1 would make the shared secret 1 whatever the viewer picks.
        var writer = WireWriter()
        writer.u16(2)
        writer.u16(128)
        writer.bytes(Self.prime)
        writer.bytes(Data(count: 127) + Data([1]))
        var reader = WireReader(writer.data)
        let weak = try DiffieHellmanLogin.Challenge.parse(&reader)
        #expect(throws: DiffieHellmanLogin.LoginError.invalidParameters) {
            _ = try DiffieHellmanLogin.respond(to: weak, username: "u", password: "p", random: CountingRandom())
        }
        // An even "prime".
        var even = WireWriter()
        even.u16(2)
        even.u16(128)
        even.bytes(Self.prime.dropLast() + Data([0xE2]))
        even.bytes(Data(count: 127) + Data([5]))
        var evenReader = WireReader(even.data)
        let evenChallenge = try DiffieHellmanLogin.Challenge.parse(&evenReader)
        #expect(throws: DiffieHellmanLogin.LoginError.invalidParameters) {
            _ = try DiffieHellmanLogin.respond(to: evenChallenge, username: "u", password: "p", random: CountingRandom())
        }
    }

    @Test func keyLengthOutsideAppleRangeIsMalformed() {
        var reader = WireReader(Data(hex: "0002 0020") + Data(count: 64))
        #expect(throws: WireError.malformed("Diffie-Hellman key of 32 bytes")) { try DiffieHellmanLogin.Challenge.parse(&reader) }
        var huge = WireReader(Data(hex: "0002 ffff"))
        #expect(throws: WireError.self) { try DiffieHellmanLogin.Challenge.parse(&huge) }
        var partial = WireReader(Data(hex: "0005 0200") + Data(count: 100))
        #expect(throws: WireError.truncated(needed: 4 + 512)) { try DiffieHellmanLogin.Challenge.parse(&partial) }
    }
}
