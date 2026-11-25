// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
@testable import ARDCrypto
import ARDTestSupport
import BigInt
import Foundation
import Testing

/// Hands out one fixed value, whatever is asked for: the viewer's SRP private key in the transcript.
private struct FixedRandom: RandomSource {
    var value: Data

    func bytes(_ count: Int) -> Data {
        value.prefix(count) + Data(count: max(0, count - value.count))
    }
}

/// An SRP transcript computed by an independent implementation (Python, whose login a Mac accepted)
/// with chosen private keys, so the Swift one can be compared byte for byte.
private enum Transcript {
    static let a = Data(hex: "030a11181f262d343b424950575e656c737a81888f969da4abb2b9c0c7ced5dce3eaf1f8ff060d141b222930373e454c535a61686f767d848b9299a0a7aeb5bc")
    static let salt = Data(hex: "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20")
    static let iterations: UInt64 = 1000
    static let B = Data(hex:
        "768da1fa71f01f8c1f533495f959d1856a728d17b733e442806413cf35aed4900517c78b2b2928b803744d3fdf8797dc" +
        "fca3041a2e85ef7fc3f295358183c7e577e264c9415e72561da18ea8160e6bd0c7c88678b78e1d9961e2c5845ff4baf3" +
        "0b2825d0a53ece12a29980a2ccfae8b63da4a0e0c05eda334d0e87ad9f4657c50bda399e0785aeb1999bcc2db3a9de6d" +
        "d55aca2bde3d7dff58f04576608b68b716a048ace74c0f0c76da3d1708aff6c7b481efb30c926ebcc0327403e2cce09c" +
        "6d323d5a37454fdef9f0c66e9e7e800a22cc179092b8c9255fe3a638f8bfa331fad5e7e58d4801e3971eaaee048d8a90" +
        "40e54da8f7cf54a833f5a8174df668a3e3815c51f48831c8e34711c544d2ff7bdfd6d1a70dfa94c4d396d9eb1c72384e" +
        "aaeada8baa8a6600e108d329d84ba681db68b4e311d5de26d4d958cd29e8ff420da822b9e542b30d89bedf3364a763d9" +
        "2a217f5de9fa61ffb8d2baf2ba0d7d2c8ebbc50046a169ec95c1bbeaa7bfc987f9eb4e4b31fb9b4314d81e65bc95ba22" +
        "bc8b875405e250065f3e9dc13dea1544c754b91e81a898e39f63b434b3e7ffb5bd5d7ae6911ed0e0a24bdc71af63f22f" +
        "0c7d5a355feddf3f06fd8a51915d8b2eaf8cacf50930a3d3c2c1a4545a91f04c1705dc540e198fdae683ef6f9fcfea3a" +
        "bcf57ba1b67281fcbf7f831c115f534d37ce72f3207c60cd822adafe1d9118ba"
    )
    static let A = Data(hex:
        "12c9695688297e723a06fa102a1bf81fe1012660e6922f0fb01f35dec08cd0a4ab8765baf6056fe9112b928e0d9d2675" +
        "e211341c118d1cd12430fd50688669796f7cce33f097ab6892e9b87acd603cb782d0d8d0ffac15beb5c37fc7dcc5cc2e" +
        "1d49fb4401ac5ee7fff10da4c5107e84005e24879fc9c74a51d8cc129947f702f2f6fbcff7033977f32e61627d10ab39" +
        "c304ef52819766edd03a5b9572be4e40b11b839cf46cdd10c525adb60ece9896d6a931bf3b09d673e5a6c9c0c479920c" +
        "d65480da28031bab6e0c348763ae1d1e14f94d7e63a9027f8d1eb8b1a0cdfc51e81522b62fda0a7bbecc6cc6bafe02cb" +
        "c05af1382a96fbdfb806acc57841b7da69cff94db65be91dc92c434ae80d395539a91b96ea93d0a7226b54d65dc59a25" +
        "b03fadb21b578de73cfac0b0e61dd6a3f847ccc8bd37b7267438f94eda4f1d8e3b12dbe2e521ca76e377ae5016d05096" +
        "d65d4f8fcc8ca3ce6a11e09a88ced3fb402dca66c09815559d1807a5bc9beed488b51b3397773bcd47ad51373cdf1e37" +
        "5882b98004c79d1b7af77961f86c8a2a3258796d23f0ef6e1d95269f94b63d59f4a65a16157a2e0fe2968a2e7ba9e051" +
        "6c59054d8618fd2ed021170c466f9750909ea60fb095c76f17c1d7f2b4813879f41679c9531bf5d64405dd44229e8882" +
        "7ae0c5ca7ab21408ca0a5486b52a67abcd6217336ad0e8b3d42486e08420d09d"
    )
    static let M1 = Data(hex: "902cd640d87fd5ea58d9c740f9ceb098a9e89bafd262b764acae711f09da1776f1f937d3a60fb5477375dcd5ba6054f8f7fb35effc2c33611cc059a08d2a01aa")
    static let M2 = Data(hex: "08453b2f3a8e39828cac0a1c863acdf2341c625dae5a72e0bf33343e44297c523f0111eb3d768da8272abf9ddededd8566b21e305cb88fae7229e5835677540e")
    static let wrapKey = Data(hex: "1a355091882c0b273358c8902e24e11b")
}

/// The same exchange over RFC 5054's 2048-bit group, as wayshare (Linux) serves it: computed by an
/// independent implementation (Python, following wayshare's server code) with the account's salt and
/// 20,000 iterations, a fixed server key and `Transcript.a`.
private enum Wayshare {
    static let salt = Data(hex: "f949d2020a8c85e1e4bbdbce4dbc9be5")
    static let iterations: UInt64 = 20_000
    static let B = Data(hex:
        "aa3f03b414dabd4f7efd001c46d62367609bb3a08248d37706e5ae937158650711fde362456972ca8df216843699f28a" +
        "3479edf2f30a006b1e620fea006a4c0df23c40bd153e20b9de2051bb1a9dfe463b537b8b63155100e8e522b4d388dd2e" +
        "6b465c8a0b275e7551c503b421dd9539162ebcf13969db3c2af01ac5285a373c1e4974d7ea7401f391839beb5bb9c0f3" +
        "d9b13a4452bed90fb08638fd7aa4f64fbd16786c989f209d07d93ea714986a5ee77cfff4a8d8a22996b893924c4a9a42" +
        "9787372d38202bc04a48197a29f64dc023af5e5b362f7e26be105b934e3a488337d642471bfce4fed3107a9604c71c0b" +
        "02b30bb855f0a9596913799c39a97bf0"
    )
    static let A = Data(hex:
        "11077707c98453512a53d8dfb8e9cb3946559b4ef13578a63637bc4eab1d4628f04ef8d26e3c9bb2443be98c6eba39d6" +
        "5c3aee34aa180f107421e4815284e35fa2f18e8d3247c24fe570555bec8a5d3d68f76df49d9b2553fdb546ddb461bd03" +
        "76cd70324cfbc40208c462a0877b96cf952349eaca0b767d46ab72343597e9629e87fb2ca10ee0982724101a299463b5" +
        "2ce203ba51d0037a52ca757e9558f619e60cdf44dc19706dca22b272935ca736cffbd6b165f6f494088ac1db1f0ff103" +
        "60014d054b7629c77e275c0dcaba1f7ccd51b3a2b5abd15199e4854960e49719fefc9280b104773a29646641d9ce2f94" +
        "b516d246b78c698371af5e02167cd5ba"
    )
    static let M1 = Data(hex: "8f157544ad6c8bfabe6471a158f880a32eac771181dffed737fcc3c26cdbe8f2070c0cfcf8b1d960e8c07512c268f5fc44abf9f75764ab10b8999733976ca61f")
    static let M2 = Data(hex: "ab3e2ddeb18ebaff23b90efed3f61b3405983b1fbd8d071247b84b36ffa8fb69adaae8c75c0c2f35dd756d005cc3dc18437ce64e7d72cbe6ef999c91f7f1ee2a")
    static let wrapKey = Data(hex: "d7508a2c36058801097268198a829f65")
    /// wayshare's options: a Mac's, and a buffer size.
    static let options = "mda=SHA-512,replay_detection,conf+int=ChaCha20-Poly1305,kdf=SALTED-SHA512-PBKDF2,maxbuffersize=65536"
}

/// A Mac's stored SRP record for an account whose password is "password": what
/// `dscl . -read /Users/<name> ShadowHashData` holds under SRP-RFC5054-4096-SHA512-PBKDF2.
private enum MacRecord {
    static let salt = Data(hex: "aa1126e638792cd3c1355147b5ce0949105acd5aecb6267556b3329e49dec004")
    static let iterations: UInt64 = 156250
    static let verifier = Data(hex:
        "a003cfea261abf926924d7f341a833ea9bd3e34fad62a522f80740094c26df08d9d8d1f8de974d2a03de631a1e79a222" +
        "1387787cf8195b6093e026e1884e6506997f0050514238b229c8d28406901003ff684368ab02cd5dc865a4c48020db61" +
        "8816fe32ebea6814e05dcc60981f3da13c74ec72487b690475de491b7c05ce2e326b662adcc99c0ebb4357e8ba72c012" +
        "4d0c0d27b602f0bcfb3dcea611b13bdaddf2f8c27da2df25048b7bb214f6ec4623f5dfa0494f8a8d53eb5bcde26987cc" +
        "44e954c7793379870b42863231cbefd52d97cd1f1d8cea657b7765e1f2c55385dbe3dd5677d603136409c25b095243b4" +
        "4946855991992cd789eb455f22d35d1c07739aeaaaed2e18444f14aea399a50f39444f57ce3d4bf522ae1ac0cebc3242" +
        "2182ffa4335fc6185d18c12da575869d07725fda8e6941273e8f9889aa377d099e9a53e25b43954c08677be498be835c" +
        "43dcaf20457a752dce7b081e48610c2cb0c20d0a2f49abb747910488a25ddad50fbdb9e437ef5f27dcdc3b7c5769f375" +
        "f6fe80e6f13e6ed4eb53ad3bb7e530dc6863a0a23148828eb15db9b150d03e9884c1720cd3495ed9adbb68d990edcf20" +
        "9d4c9e29bb71c842ddd7a669f4d7e91b74acba8e58192af878a39fbc2558903930f4d572b8ceeb0d29608a8ab0bddc0d" +
        "696637a6796a2eca2135382d1bd10fd1db23831487b6c9919478df6303cac1fa"
    )
}

private func challenge(B: Data = Transcript.B, salt: Data = Transcript.salt, iterations: UInt64 = Transcript.iterations,
                       options: String = "mda=SHA-512,replay_detection,conf+int=ChaCha20-Poly1305,kdf=SALTED-SHA512-PBKDF2",
                       modulus: Data? = nil, generator: Data = Data([5])) -> SRPLogin.Challenge {
    SRPLogin.Challenge(
        modulus: modulus ?? SRPLogin.pad(SRPLogin.modulus), generator: generator, salt: salt,
        serverPublicKey: B, iterations: iterations, options: options
    )
}

@Suite struct SRPLoginTests {
    @Test func matchesAnIndependentTranscriptByteForByte() throws {
        let response = try SRPLogin.respond(to: challenge(), password: "password", random: FixedRandom(value: Transcript.a))
        #expect(response.expectedServerProof == Transcript.M2)
        #expect(response.wrapKey == Transcript.wrapKey)
        // Message 3: lengths, A, M1, the options, an empty IV.
        var reader = WireReader(response.message)
        let outer = try reader.u32()
        let inner = try reader.u32()
        #expect(Int(outer) == response.message.count - 4)
        #expect(Int(inner) == response.message.count - 8)
        #expect(try reader.u16() == 512)
        #expect(try reader.take(512) == Transcript.A)
        #expect(try reader.u8() == 64)
        #expect(try reader.take(64) == Transcript.M1)
        #expect(String(decoding: try reader.take(Int(try reader.u16())), as: UTF8.self) == "mda=SHA-512,replay_detection,kdf=SALTED-SHA512-PBKDF2")
        #expect(try reader.u8() == 0)
        #expect(reader.isAtEnd)
    }

    /// The 2048-bit group, as wayshare offers it: every number padded to 256 bytes, not 512.
    @Test func matchesAWayshareTranscriptOverThe2048BitGroup() throws {
        let group = SRPLogin.rfc5054Group2048
        let offer = SRPLogin.Challenge(
            modulus: group.pad(group.modulus), generator: Data([2]), salt: Wayshare.salt,
            serverPublicKey: Wayshare.B, iterations: Wayshare.iterations, options: Wayshare.options
        )
        let response = try SRPLogin.respond(to: offer, password: "password", random: FixedRandom(value: Transcript.a))
        #expect(response.expectedServerProof == Wayshare.M2)
        #expect(response.wrapKey == Wayshare.wrapKey)
        var reader = WireReader(response.message)
        _ = try reader.u32()
        _ = try reader.u32()
        #expect(try reader.u16() == 256)
        #expect(try reader.take(256) == Wayshare.A)
        #expect(try reader.u8() == 64)
        #expect(try reader.take(64) == Wayshare.M1)
    }

    @Test func thePasswordKeyReproducesAMacsStoredVerifier() throws {
        let x = try SRPLogin.passwordKey(Data("password".utf8), salt: MacRecord.salt, iterations: MacRecord.iterations)
        let verifier = ModularPower.power(SRPLogin.generator, x, modulus: SRPLogin.modulus)
        #expect(SRPLogin.pad(verifier) == MacRecord.verifier)
        let wrong = try SRPLogin.passwordKey(Data("Password".utf8), salt: MacRecord.salt, iterations: MacRecord.iterations)
        #expect(SRPLogin.pad(ModularPower.power(SRPLogin.generator, wrong, modulus: SRPLogin.modulus)) != MacRecord.verifier)
    }

    @Test func theFirstMessageNamesTheAccountTwice() throws {
        let message = try SRPLogin.firstMessage(username: "dev")
        var expected = Data([36, 0, 0, 0, 0x11, 0, 0, 0, 0x0d, 0, 3])
        expected.append(Data("dev".utf8))
        expected.append(contentsOf: [0, 3])
        expected.append(Data("dev".utf8))
        expected.append(contentsOf: [0, 0, 0])
        #expect(message == expected)
        #expect(throws: SRPLogin.LoginError.credentialTooLong) { try SRPLogin.firstMessage(username: String(repeating: "x", count: 256)) }
        // wayshare, like Screen Sharing.app logging in to it, has the type byte only as the choice.
        #expect(try SRPLogin.firstMessage(username: "dev", repeatsType: false) == expected.dropFirst())
    }

    @Test func parsesTheChallengeAsAMacSendsIt() throws {
        var fields = WireWriter()
        fields.u8(0)
        let N = SRPLogin.pad(SRPLogin.modulus)
        fields.u16(UInt16(N.count)); fields.bytes(N)
        fields.u16(1); fields.u8(5)
        fields.u8(UInt8(Transcript.salt.count)); fields.bytes(Transcript.salt)
        fields.u16(UInt16(Transcript.B.count)); fields.bytes(Transcript.B)
        fields.u64(156_250)
        let options = Data("mda=SHA-512,replay_detection,conf+int=ChaCha20-Poly1305,kdf=SALTED-SHA512-PBKDF2".utf8)
        fields.u16(UInt16(options.count)); fields.bytes(options)
        var reader = WireReader(SRPLogin.framed(fields.data))
        let parsed = try SRPLogin.Challenge.parse(&reader)
        #expect(reader.isAtEnd)
        #expect(parsed == challenge(iterations: 156_250, modulus: N))
    }

    @Test func readsTheMacsProofOrItsRefusal() throws {
        var accepted = WireWriter()
        accepted.u8(64); accepted.bytes(Transcript.M2)
        accepted.u8(16); accepted.bytes(Data(repeating: 9, count: 16))
        accepted.u16(0); accepted.u32(0)
        var reader = WireReader(SRPLogin.framed(accepted.data) + Data([0, 0, 0, 0]))
        #expect(try SRPLogin.parseVerdict(&reader) == .accepted(serverProof: Transcript.M2))
        #expect(try reader.u32() == 0)
        var refusal = WireReader(Data([0, 0, 0, 1]))
        #expect(try SRPLogin.parseVerdict(&refusal) == .refused)
        #expect(refusal.isAtEnd)
    }

    @Test func aWrongProofFromTheMacIsCaught() throws {
        try SRPLogin.verify(serverProof: Transcript.M2, expected: Transcript.M2)
        var forged = Transcript.M2
        forged[forged.startIndex + 40] ^= 1
        #expect(throws: SRPLogin.LoginError.serverNotAuthenticated) { try SRPLogin.verify(serverProof: forged, expected: Transcript.M2) }
        #expect(throws: SRPLogin.LoginError.serverNotAuthenticated) { try SRPLogin.verify(serverProof: Transcript.M2.prefix(32), expected: Transcript.M2) }
    }

    @Test func weakOrForeignParametersAreRefused() {
        let random = FixedRandom(value: Transcript.a)
        func refused(_ challenge: SRPLogin.Challenge) -> Bool {
            do {
                _ = try SRPLogin.respond(to: challenge, password: "password", random: random)
                return false
            } catch {
                guard case .invalidParameters = error else { return false }
                return true
            }
        }
        // Another group: RFC 3526's 1536-bit prime would do for the arithmetic, but is not accepted.
        #expect(refused(challenge(modulus: Data(repeating: 0xff, count: 192))))
        #expect(refused(challenge(generator: Data([2]))))
        // RFC 5054's 2048-bit prime only with its own generator, and with the same checks on B.
        let group2048 = SRPLogin.rfc5054Group2048
        #expect(refused(challenge(B: Wayshare.B, modulus: group2048.pad(group2048.modulus), generator: Data([5]))))
        #expect(refused(challenge(B: Data(count: 256), modulus: group2048.pad(group2048.modulus), generator: Data([2]))))
        #expect(refused(challenge(options: "mda=SHA-1,replay_detection")))
        #expect(refused(challenge(options: "mda=SHA-512,replay_detection")))
        #expect(refused(challenge(iterations: 10)))
        #expect(refused(challenge(iterations: 1 << 40)))
        #expect(refused(challenge(salt: Data())))
        // B ≡ 0 would make the shared secret known to anyone.
        #expect(refused(challenge(B: Data(count: 512))))
        #expect(refused(challenge(B: SRPLogin.pad(SRPLogin.modulus))))
    }

    @Test func differentPrivateKeysGiveDifferentProofs() throws {
        let one = try SRPLogin.respond(to: challenge(), password: "password", random: FixedRandom(value: Transcript.a))
        let other = try SRPLogin.respond(to: challenge(), password: "password", random: FixedRandom(value: Data(repeating: 7, count: 64)))
        #expect(one.message != other.message)
        #expect(one.wrapKey != other.wrapKey)
    }
}


@Suite struct ModularPowerTests {
    private func random(bits: Int, using generator: inout some RandomNumberGenerator) -> BigUInt {
        BigUInt(Data((0..<(bits / 8)).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }

    /// Against BigInt's own general arithmetic, which is slow but simple, on random odd moduli of
    /// the sizes the logins use and some awkward ones.
    @Test(arguments: [64, 128, 192, 512, 1024])
    func agreesWithGeneralArithmetic(bits: Int) {
        var generator = SeededGenerator(seed: UInt64(bits))
        for _ in 0..<12 {
            var modulus = random(bits: bits, using: &generator) | 1
            modulus |= BigUInt(1) << (bits - 1)
            let base = random(bits: bits + 16, using: &generator)
            let exponent = random(bits: 64 + Int.random(in: 0...256, using: &generator) / 8 * 8, using: &generator)
            #expect(ModularPower.power(base, exponent, modulus: modulus) == base.power(exponent, modulus: modulus))
        }
    }

    @Test func edgeCases() {
        let modulus = BigUInt(1_000_003)
        #expect(ModularPower.power(12345, 0, modulus: modulus) == 1)
        #expect(ModularPower.power(0, 5, modulus: modulus) == 0)
        #expect(ModularPower.power(modulus + 2, 3, modulus: modulus) == 8)
        #expect(ModularPower.power(modulus - 1, 2, modulus: modulus) == 1)
        // A modulus whose top limb is all ones, the case that needs the final subtraction most.
        let wide = (BigUInt(1) << 256) - 189
        #expect(ModularPower.power(wide - 3, wide - 2, modulus: wide) == (wide - 3).power(wide - 2, modulus: wide))
    }

    /// One exponentiation of the size SRP does, against each group's known structure: g^(N-1) = 1,
    /// and N = 2q + 1 with g^q = N - 1 (g generates the whole group of a safe prime, as RFC 5054's do).
    @Test func fermatHoldsInTheSRPGroups() {
        for group in SRPLogin.groups {
            let N = group.modulus
            #expect(N.bitWidth == group.length * 8)
            #expect(ModularPower.power(group.generator, N - 1, modulus: N) == 1)
            #expect(ModularPower.power(group.generator, (N - 1) / 2, modulus: N) == N - 1)
        }
    }
}


/// SplitMix64, so damage is the same every run.
private func damaged(_ data: Data, _ generator: inout SeededGenerator) -> Data {
    var bytes = [UInt8](data)
    for _ in 0..<Int.random(in: 1...5, using: &generator) {
        guard !bytes.isEmpty else { break }
        let index = Int.random(in: 0..<bytes.count, using: &generator)
        switch Int.random(in: 0..<4, using: &generator) {
        case 0: bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        case 1: bytes.removeSubrange(index...)
        case 2: bytes.insert(UInt8.random(in: .min ... .max, using: &generator), at: index)
        default: for offset in index..<min(bytes.count, index + 4) { bytes[offset] = 0xff }
        }
    }
    return Data(bytes)
}

/// What a peer sends before and around the login is read before anything is authenticated; damaged
/// copies must be refused, never trap.
@Suite struct LoginHostileInputTests {
    @Test func loginChallengesSurviveDamage() {
        var generator = SeededGenerator(seed: 36)
        var fields = WireWriter()
        fields.u8(0)
        let N = SRPLogin.pad(SRPLogin.modulus)
        fields.u16(UInt16(N.count)); fields.bytes(N)
        fields.u16(1); fields.u8(5)
        fields.u8(32); fields.bytes(Data(repeating: 3, count: 32))
        fields.u16(512); fields.bytes(Data(repeating: 9, count: 512))
        fields.u64(156_250)
        let options = Data("mda=SHA-512,replay_detection,kdf=SALTED-SHA512-PBKDF2".utf8)
        fields.u16(UInt16(options.count)); fields.bytes(options)
        let challenge = SRPLogin.framed(fields.data)
        var dh = WireWriter()
        dh.u16(5); dh.u16(64); dh.bytes(Data(repeating: 0xab, count: 128))
        for _ in 0..<1500 {
            var reader = WireReader(damaged(challenge, &generator))
            _ = try? SRPLogin.Challenge.parse(&reader)
            var verdict = WireReader(damaged(challenge, &generator))
            _ = try? SRPLogin.parseVerdict(&verdict)
            var dhReader = WireReader(damaged(dh.data, &generator))
            _ = try? DiffieHellmanLogin.Challenge.parse(&dhReader)
        }
    }

    @Test func theRecordLayerRefusesDamageWithoutTrapping() throws {
        var generator = SeededGenerator(seed: 30)
        let keys = RecordKeys(key: Data(repeating: 1, count: 16), iv: Data(repeating: 2, count: 16))
        let sealed = try RecordSealer(keys: keys).seal(Data((0..<3000).map { UInt8(truncatingIfNeeded: $0) }))
        for _ in 0..<1500 {
            let opener = try RecordOpener(keys: keys)
            var ciphertext = InboundBuffer()
            ciphertext.append(damaged(sealed, &generator))
            var plaintext = InboundBuffer()
            try? opener.open(from: &ciphertext, into: &plaintext)
        }
    }
}
