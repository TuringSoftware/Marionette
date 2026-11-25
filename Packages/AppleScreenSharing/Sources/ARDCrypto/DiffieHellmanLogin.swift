// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import ARDProtocol
import BigInt
public import Foundation

/// Security type 30: a Diffie-Hellman exchange whose shared secret encrypts the account's name and
/// password. It hides the password from a passive listener, but nothing in it proves which machine
/// the viewer is talking to.
public enum DiffieHellmanLogin {
    /// What the Mac sends after the viewer picks type 30.
    public struct Challenge: Sendable, Equatable {
        public var generator: UInt16
        public var prime: Data
        public var serverPublicKey: Data

        public var keyLength: Int { prime.count }

        /// Key lengths Apple's viewer accepts, in bytes.
        static let keyLengths = 64...1024

        public static func parse(_ reader: inout WireReader) throws(WireError) -> Challenge {
            let generator = try reader.u16()
            let length = Int(try reader.u16())
            guard keyLengths.contains(length) else { throw .malformed("Diffie-Hellman key of \(length) bytes") }
            return Challenge(generator: generator, prime: try reader.take(length), serverPublicKey: try reader.take(length))
        }
    }

    public struct Response: Sendable, Equatable {
        /// The encrypted credential block followed by the viewer's public key.
        public var message: Data
        /// The key later rekeys are wrapped under.
        public var wrapKey: Data
    }

    public enum LoginError: Error, Sendable, Equatable {
        /// The name or password does not fit the 63 bytes the exchange allows each.
        case credentialTooLong
        /// The server's parameters are unusable (even prime, generator or public key out of range).
        case invalidParameters
        case crypto(CryptoError)
    }

    static let credentialFieldLength = 64
    /// Bytes of private exponent. Short exponents are sound in a safe-prime group and keep the
    /// exchange fast; 512 bits is well over twice the group's strength.
    static let privateKeyLength = 64

    public static func respond(
        to challenge: Challenge,
        username: String,
        password: String,
        random: any RandomSource
    ) throws(LoginError) -> Response {
        let name = Array(username.utf8)
        let secret = Array(password.utf8)
        guard name.count < credentialFieldLength, secret.count < credentialFieldLength else {
            throw .credentialTooLong
        }

        let prime = BigUInt(challenge.prime)
        let generator = BigUInt(challenge.generator)
        let serverPublic = BigUInt(challenge.serverPublicKey)
        guard prime > 3, prime & 1 == 1, generator > 1, generator < prime - 1,
              serverPublic > 1, serverPublic < prime - 1
        else { throw .invalidParameters }

        let privateKey = BigUInt(random.bytes(privateKeyLength)) | 1
        let publicKey = ModularPower.power(generator, privateKey, modulus: prime)
        let shared = ModularPower.power(serverPublic, privateKey, modulus: prime)
        let wrapKey = Digest.md5(leftPadded(shared.serialize(), to: challenge.keyLength))

        let encrypted = try sealCredentials(username: username, password: password, key: wrapKey, random: random)
        return Response(message: encrypted + leftPadded(publicKey.serialize(), to: challenge.keyLength), wrapKey: wrapKey)
    }

    /// The 128-byte credential block: name at 0 and password at 64, each NUL-terminated, the rest
    /// random so equal credentials do not produce equal blocks; AES-128-ECB under `key`. The type-30
    /// login sends it, and so does a session-select request to log in as oneself, under whichever
    /// key the login produced.
    public static func sealCredentials(username: String, password: String, key: Data, random: any RandomSource) throws(LoginError) -> Data {
        let name = Array(username.utf8)
        let secret = Array(password.utf8)
        guard name.count < credentialFieldLength, secret.count < credentialFieldLength else {
            throw .credentialTooLong
        }
        var block = random.bytes(credentialFieldLength * 2)
        block.replaceSubrange(0..<name.count, with: name)
        block[name.count] = 0
        block.replaceSubrange(credentialFieldLength..<(credentialFieldLength + secret.count), with: secret)
        block[credentialFieldLength + secret.count] = 0
        do {
            return try AES128.encryptECB(block, key: key)
        } catch {
            throw .crypto(error)
        }
    }

    static func leftPadded(_ data: Data, to length: Int) -> Data {
        data.count >= length ? data.suffix(length) : Data(count: length - data.count) + data
    }
}

/// The Mac's side of security type 30, for tools and tests that stand in for a Mac.
public struct DiffieHellmanServer: Sendable {
    /// The challenge to send: generator, key length, prime, public key.
    public let challenge: Data
    /// Bytes of the viewer's answer: the encrypted credential block and its public key.
    public var responseLength: Int { 128 + Self.length }

    private let privateKey: BigUInt
    static let length = 512

    public init(random: any RandomSource = SystemRandomSource()) {
        privateKey = BigUInt(random.bytes(64)) | 1
        let publicKey = ModularPower.power(SRPLogin.generator, privateKey, modulus: SRPLogin.modulus)
        var writer = WireWriter()
        writer.u16(5)
        writer.u16(UInt16(Self.length))
        writer.bytes(SRPLogin.pad(SRPLogin.modulus))
        writer.bytes(SRPLogin.pad(publicKey))
        challenge = writer.data
    }

    /// Reads the viewer's answer: its name, password, and the key the rekey is wrapped under.
    public func accept(_ response: Data) throws(CryptoError) -> (username: String, password: String, wrapKey: Data) {
        guard response.count == responseLength else { throw .failure("type 30 answer of \(response.count) bytes") }
        let viewerKey = BigUInt(response.suffix(Self.length))
        let shared = ModularPower.power(viewerKey, privateKey, modulus: SRPLogin.modulus)
        let wrapKey = Digest.md5(SRPLogin.pad(shared))
        let block = try AES128.decryptECB(response.prefix(128), key: wrapKey)
        func field(_ range: Range<Int>) -> String {
            String(decoding: block[range].prefix { $0 != 0 }, as: UTF8.self)
        }
        return (field(0..<64), field(64..<128), wrapKey)
    }
}
