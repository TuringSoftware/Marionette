// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// Security type 36 as a Mac's screensharingd serves it. The message framing and options were found by
// our own probes of a Mac and its log; the arithmetic is SRP-6a as corecrypto's `ccsrp` computes it
// by default, and the exchange is the SASL SRP mechanism of Cyrus SASL (Carnegie Mellon University's
// libsasl, as Apple ships it in passwordserver_sasl). Those sources were read as documentation;
// no code is taken from them. See Docs/protocol/apple-screen-sharing.md.

import ARDProtocol
import BigInt
import CommonCrypto
public import Foundation

/// Security type 36: SRP-6a over RFC 5054's 4096-bit group (2048-bit for wayshare) with SHA-512, the
/// password first stretched with PBKDF2.
///
/// Unlike type 30 it proves both ends: the Mac learns that the viewer knows the password without
/// seeing it, and the viewer checks that the Mac holds the account's verifier, so a machine in the
/// middle can neither read the password nor pass as the Mac.
///
/// The exchange, after the viewer picks type 36:
/// 1. viewer: `36`, a `u32` length, and a SASL SRP buffer `{ utf8(U) utf8(I) utf8(sid) os(cn) }` with
///    the account name as both U and I (servers that are not Macs, such as wayshare, want no `36`);
/// 2. Mac: a `u32` length and a buffer `{ 0 mpi(N) mpi(g) os(salt) mpi(B) u64(iterations) utf8(L) }`;
///    an account that does not exist gets made-up values, and the proof simply fails later;
/// 3. viewer: a `u32` length and `{ mpi(A) os(M1) utf8(o) os(cIV) }`;
/// 4. Mac: a `u32` length and `{ os(M2) os(sIV) utf8(sid) u32(ttl) }`, then the result word; or, for
///    a wrong proof, the result word alone.
///
/// A SASL buffer is itself a `u32` length and its fields: `mpi` a `u16` length and big-endian bytes,
/// `os` a `u8` length, `utf8` a `u16` length, `u64` eight bytes.
public enum SRPLogin {
    /// An SRP group: a safe prime and its generator.
    struct Group: Sendable {
        var modulus: BigUInt
        var generator: BigUInt
        /// N's length in bytes, to which every padded number is widened.
        var length: Int

        init(hex: String, generator: BigUInt) {
            modulus = BigUInt(hex, radix: 16)!
            self.generator = generator
            length = hex.count / 2
        }

        func pad(_ value: BigUInt) -> Data {
            DiffieHellmanLogin.leftPadded(value.serialize(), to: length)
        }
    }

    /// RFC 5054 appendix A, the 4096-bit group, whose generator is 5: what a Mac offers.
    static let modulusHex = [
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74",
        "020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437",
        "4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED",
        "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05",
        "98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB",
        "9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B",
        "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718",
        "3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33",
        "A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7",
        "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864",
        "D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2",
        "08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D7",
        "88719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8",
        "DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2",
        "233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA9",
        "93B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF",
    ].joined()
    static let rfc5054Group4096 = Group(hex: modulusHex, generator: 5)
    static let modulus = rfc5054Group4096.modulus
    static let generator = rfc5054Group4096.generator
    static let length = rfc5054Group4096.length

    /// RFC 5054 appendix A, the 2048-bit group, whose generator is 2: what wayshare offers.
    static let rfc5054Group2048 = Group(hex: [
        "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050",
        "A37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50",
        "E8083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B8",
        "55F97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773B",
        "CA97B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F87748",
        "544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6",
        "AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB6",
        "94B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73",
    ].joined(), generator: 2)

    /// The only groups this client accepts, each exactly as RFC 5054 gives it: a machine in the
    /// middle must not be able to offer a weak or doctored one. The smaller group makes a captured
    /// proof somewhat cheaper to guess against than the Mac's, but the PBKDF2 floor dominates that
    /// cost. RFC 5054's 3072-bit group is left out: no known server uses it.
    static let groups = [rfc5054Group4096, rfc5054Group2048]

    /// What this viewer asks for. A Mac refuses a login that does not ask for replay detection
    /// ("abort: SRP not using replay detection") or does not name the key derivation ("Error
    /// initializing security layer"). Neither layer is applied afterwards: the session's records
    /// are the AES ones that follow the rekey.
    public static let options = "mda=SHA-512,replay_detection,kdf=SALTED-SHA512-PBKDF2"

    /// Bounds on the stretching a Mac may ask for. Below the floor a machine in the middle could make
    /// guessing the password from a captured proof cheap; above the ceiling the login would hang.
    static let iterationRange: ClosedRange<UInt64> = 1_000...20_000_000

    public enum LoginError: Error, Sendable, Equatable {
        case credentialTooLong
        /// The Mac offered parameters this client refuses: another group, a degenerate key, an
        /// unsupported digest or an implausible iteration count.
        case invalidParameters(String)
        /// The Mac's proof does not match. It does not hold this account's verifier: whatever
        /// answered is not the Mac, or the account changed underneath the login.
        case serverNotAuthenticated
        case crypto(CryptoError)
    }

    // MARK: Messages

    /// Message 1. A Mac reads the type byte a second time in front of it and closes the connection
    /// without it; wayshare, and Screen Sharing.app when it logs in to wayshare, have it only once,
    /// as the choice of type, so `repeatsType` is for Macs only.
    public static func firstMessage(username: String, repeatsType: Bool = true) throws(LoginError) -> Data {
        guard username.utf8.count <= 255 else { throw .credentialTooLong }
        var fields = WireWriter()
        utf8(username, into: &fields)
        utf8(username, into: &fields)
        utf8("", into: &fields)
        fields.u8(0)
        var message = WireWriter()
        if repeatsType { message.u8(SecurityType.srp.rawValue) }
        message.bytes(framed(fields.data))
        return message.data
    }

    public struct Challenge: Sendable, Equatable {
        public var modulus: Data
        public var generator: Data
        public var salt: Data
        public var serverPublicKey: Data
        public var iterations: UInt64
        public var options: String

        /// Message 2. Reads the outer length and the buffer inside it.
        public static func parse(_ reader: inout WireReader) throws(WireError) -> Challenge {
            var buffer = try SRPLogin.unframe(&reader)
            guard try buffer.u8() == 0 else { throw .malformed("SRP challenge offers to reuse a session") }
            let modulus = try mpi(&buffer)
            let generator = try mpi(&buffer)
            let salt = try buffer.take(Int(try buffer.u8()))
            let serverPublicKey = try mpi(&buffer)
            let iterations = try buffer.u64()
            let options = String(decoding: try buffer.take(Int(try buffer.u16())), as: UTF8.self)
            return Challenge(modulus: modulus, generator: generator, salt: salt, serverPublicKey: serverPublicKey, iterations: iterations, options: options)
        }
    }

    public struct Response: Sendable, Equatable {
        /// Message 3.
        public var message: Data
        /// The proof the Mac must answer with.
        public var expectedServerProof: Data
        /// The key the session's rekey is wrapped under: the first 16 bytes of SHA-256 of K.
        public var wrapKey: Data
    }

    /// The Mac's answer to message 3.
    public enum Verdict: Sendable, Equatable {
        /// The Mac accepted the proof and sent its own. The result word follows.
        case accepted(serverProof: Data)
        /// The Mac refused the proof: a wrong password. This was the result word itself.
        case refused
    }

    /// Message 4, or the bare result word a Mac sends instead when it refuses the proof.
    public static func parseVerdict(_ reader: inout WireReader) throws(WireError) -> Verdict {
        let length = try reader.u32()
        // A real answer is at least 76 bytes; a result word is a small number with nothing after it.
        guard length >= 8 else { return .refused }
        var outer = try reader.sub(Int(length))
        var buffer = try unframe(inner: &outer)
        let proof = try buffer.take(Int(try buffer.u8()))
        return .accepted(serverProof: proof)
    }

    // MARK: The arithmetic

    public static func respond(
        to challenge: Challenge, password: String, random: any RandomSource
    ) throws(LoginError) -> Response {
        let offeredModulus = BigUInt(challenge.modulus)
        let offeredGenerator = BigUInt(challenge.generator)
        guard let group = groups.first(where: { $0.modulus == offeredModulus && $0.generator == offeredGenerator }) else {
            throw .invalidParameters("the server offered an SRP group other than RFC 5054's 2048- or 4096-bit one")
        }
        let N = group.modulus
        let generator = group.generator
        let pad = group.pad
        let offered = Set(challenge.options.split(separator: ",").map { $0.lowercased() })
        guard offered.contains("mda=sha-512"), offered.contains("kdf=salted-sha512-pbkdf2") else {
            throw .invalidParameters("the server offered SRP options \(challenge.options)")
        }
        guard iterationRange.contains(challenge.iterations) else {
            throw .invalidParameters("the server asked for \(challenge.iterations) rounds of PBKDF2")
        }
        guard !challenge.salt.isEmpty else { throw .invalidParameters("empty salt") }
        let B = BigUInt(challenge.serverPublicKey)
        guard B % N != 0, B < N else { throw .invalidParameters("degenerate server key") }
        let password = Data(password.utf8)
        guard password.count <= 1024 else { throw .credentialTooLong }

        let x = try passwordKey(password, salt: challenge.salt, iterations: challenge.iterations)
        let k = BigUInt(Digest.sha512(pad(N) + pad(generator)))

        var a = BigUInt(random.bytes(64))
        if a == 0 { a = 1 }
        let A = ModularPower.power(generator, a, modulus: N)
        let paddedA = pad(A)
        let paddedB = pad(B)
        let u = BigUInt(Digest.sha512(paddedA + paddedB))
        guard u != 0 else { throw .invalidParameters("degenerate scrambling parameter") }

        // S = (B - k·g^x)^(a + u·x) mod N
        let kgx = (k * ModularPower.power(generator, x, modulus: N)) % N
        let base = (B + N - kgx) % N
        let S = ModularPower.power(base, a + u * x, modulus: N)
        let K = Digest.sha512(pad(S))

        // corecrypto's M with an empty user name, as screensharingd computes it.
        let hashN = Digest.sha512(pad(N))
        let hashG = Digest.sha512(pad(generator))
        let mixed = Data(zip(hashN, hashG).map { $0 ^ $1 })
        let M1 = Digest.sha512(mixed + Digest.sha512(Data()) + challenge.salt + paddedA + paddedB + K)
        let M2 = Digest.sha512(paddedA + M1 + K)

        var fields = WireWriter()
        fields.u16(UInt16(paddedA.count))
        fields.bytes(paddedA)
        fields.u8(UInt8(M1.count))
        fields.bytes(M1)
        utf8(options, into: &fields)
        fields.u8(0)
        return Response(message: framed(fields.data), expectedServerProof: M2, wrapKey: Digest.sha256(K).prefix(16))
    }

    /// Checks the Mac's proof in constant time.
    public static func verify(serverProof: Data, expected: Data) throws(LoginError) {
        guard serverProof.count == expected.count else { throw .serverNotAuthenticated }
        var difference: UInt8 = 0
        for (left, right) in zip(serverProof, expected) { difference |= left ^ right }
        guard difference == 0 else { throw .serverNotAuthenticated }
    }

    /// x = SHA-512(salt ‖ SHA-512(":" ‖ PBKDF2-HMAC-SHA512(password, salt, iterations, 128))). The
    /// user name is left out, as in the verifiers macOS stores (checked against one).
    static func passwordKey(_ password: Data, salt: Data, iterations: UInt64) throws(LoginError) -> BigUInt {
        var stretched = [UInt8](repeating: 0, count: 128)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), passwordBytes.count,
                    saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), UInt32(iterations),
                    &stretched, stretched.count
                )
            }
        }
        guard status == kCCSuccess else { throw .crypto(.failure("PBKDF2 failed: \(status)")) }
        let inner = Digest.sha512(Data(":".utf8) + Data(stretched))
        return BigUInt(Digest.sha512(salt + inner))
    }

    // MARK: Wire helpers

    static func pad(_ value: BigUInt) -> Data {
        DiffieHellmanLogin.leftPadded(value.serialize(), to: length)
    }

    static func utf8(_ text: String, into writer: inout WireWriter) {
        let bytes = Data(text.utf8)
        writer.u16(UInt16(bytes.count))
        writer.bytes(bytes)
    }

    static func mpi(_ reader: inout WireReader) throws(WireError) -> Data {
        let count = Int(try reader.u16())
        guard count <= length else { throw .malformed("SRP number of \(count) bytes") }
        return try reader.take(count)
    }

    /// A SASL buffer inside the outer length a Mac puts around every SRP message.
    static func framed(_ fields: Data) -> Data {
        var writer = WireWriter(capacity: fields.count + 8)
        writer.u32(UInt32(fields.count + 4))
        writer.u32(UInt32(fields.count))
        writer.bytes(fields)
        return writer.data
    }

    static func unframe(_ reader: inout WireReader) throws(WireError) -> WireReader {
        let length = Int(try reader.u32())
        guard length <= 1 << 16 else { throw .malformed("SRP message of \(length) bytes") }
        var outer = try reader.sub(length)
        return try unframe(inner: &outer)
    }

    static func unframe(inner outer: inout WireReader) throws(WireError) -> WireReader {
        let inner = Int(try outer.u32())
        guard inner == outer.remaining else { throw .malformed("SRP buffer of \(inner) bytes in \(outer.remaining)") }
        return try outer.sub(inner)
    }
}
