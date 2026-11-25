// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
public import Foundation
import Synchronization

// MARK: - Key files

public enum SSHKeyError: Error, Sendable, Hashable {
    /// The text is not a private key (a public key, or something else entirely).
    case notAPrivateKey
    /// A private key of a kind Marionette cannot log in with (`type` as the file names it).
    case unsupportedKeyType(String)
    /// Key names must not be empty.
    case invalidName
    case nameInUse(String)
    /// The Keychain refused (an `OSStatus`), or what it holds could not be read back (-1).
    case storage(code: Int32)

    /// The failure in words for the person importing or creating a key.
    public var message: String {
        switch self {
        case .notAPrivateKey:
            String(localized: "This isn’t an SSH private key. Paste the whole private key file, from “-----BEGIN” to the “-----END” line.", bundle: #bundle)
        case .unsupportedKeyType(let type):
            String(localized: "Marionette can’t use \(type) keys. Use an Ed25519, ECDSA or RSA key.", bundle: #bundle)
        case .invalidName:
            String(localized: "Give the key a name.", bundle: #bundle)
        case .nameInUse(let name):
            String(localized: "There is already a key named “\(name)”.", bundle: #bundle)
        case .storage(let code):
            String(localized: "The key couldn’t be saved in the Keychain (error \(code)).", bundle: #bundle)
        }
    }
}

/// A private key file and what it reveals without its passphrase.
///
/// The OpenSSH format ("BEGIN OPENSSH PRIVATE KEY") carries the public key in the clear, so its type
/// and fingerprint are known even when the private half is encrypted. The older PEM formats do not;
/// for those only the kind of key is known.
public struct SSHPrivateKeyFile: Sendable, Hashable {
    /// The algorithm, as SSH names it ("ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256"), or a bare
    /// family name ("ecdsa", "") when a PEM file does not say more.
    public var type: String
    /// The public key in SSH wire format, when the file reveals it.
    public var publicKey: Data?
    /// Whether a passphrase is needed to use the key.
    public var isEncrypted: Bool
    /// The comment stored with the key ("user@host"). Empty when encrypted or absent.
    public var comment: String
    /// The file, with tidy line breaks, as it is handed to the SSH library.
    public var text: String

    private static let openSSHLabel = "OPENSSH PRIVATE KEY"
    private static let magic = Data("openssh-key-v1\0".utf8)

    /// Reads a pasted or imported private key. Line breaks lost in pasting are forgiven.
    public init(text: String) throws(SSHKeyError) {
        guard let begin = text.range(of: "-----BEGIN "),
              let labelEnd = text.range(of: "-----", range: begin.upperBound..<text.endIndex)
        else { throw .notAPrivateKey }
        let label = String(text[begin.upperBound..<labelEnd.lowerBound])
        guard let end = text.range(of: "-----END \(label)-----", range: labelEnd.upperBound..<text.endIndex) else {
            throw .notAPrivateKey
        }
        let body = text[labelEnd.upperBound..<end.lowerBound]

        switch label {
        case Self.openSSHLabel:
            let base64 = String(body.filter { !$0.isWhitespace })
            guard let data = Data(base64Encoded: base64) else { throw .notAPrivateKey }
            self = try Self.parseOpenSSH(data)
        case "RSA PRIVATE KEY", "EC PRIVATE KEY", "PRIVATE KEY", "ENCRYPTED PRIVATE KEY":
            type = switch label {
            case "RSA PRIVATE KEY": "ssh-rsa"
            case "EC PRIVATE KEY": "ecdsa"
            default: ""
            }
            publicKey = nil
            comment = ""
            let lines = body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { throw .notAPrivateKey }
            // PEM headers ("Proc-Type: 4,ENCRYPTED", "DEK-Info: …") are followed by an empty line.
            let headers = lines.prefix { $0.contains(":") }
            isEncrypted = label == "ENCRYPTED PRIVATE KEY" || headers.contains { $0.contains("ENCRYPTED") }
            var rebuilt = "-----BEGIN \(label)-----\n"
            if !headers.isEmpty { rebuilt += headers.joined(separator: "\n") + "\n\n" }
            rebuilt += lines.dropFirst(headers.count).joined(separator: "\n") + "\n-----END \(label)-----\n"
            self.text = rebuilt
        case "DSA PRIVATE KEY":
            throw .unsupportedKeyType("DSA")
        default:
            throw .notAPrivateKey
        }
    }

    private init(type: String, publicKey: Data?, isEncrypted: Bool, comment: String, text: String) {
        self.type = type
        self.publicKey = publicKey
        self.isEncrypted = isEncrypted
        self.comment = comment
        self.text = text
    }

    private static func parseOpenSSH(_ data: Data) throws(SSHKeyError) -> SSHPrivateKeyFile {
        guard data.starts(with: magic) else { throw .notAPrivateKey }
        var reader = WireReader(data.dropFirst(magic.count))
        guard let cipher = reader.string().flatMap({ String(data: $0, encoding: .utf8) }),
              reader.string() != nil, reader.string() != nil,
              reader.uint32() == 1,
              let publicKey = reader.string(),
              let privateSection = reader.string()
        else { throw .notAPrivateKey }
        var publicReader = WireReader(publicKey)
        guard let type = publicReader.string().flatMap({ String(data: $0, encoding: .utf8) }) else { throw .notAPrivateKey }
        guard privateFieldCount(type) != nil else { throw .unsupportedKeyType(type) }

        var comment = ""
        if cipher == "none" {
            // Two check integers, the key type, the type's own fields, then the comment.
            var secret = WireReader(privateSection)
            if secret.uint32() != nil, secret.uint32() != nil, secret.string() != nil, let fields = privateFieldCount(type) {
                var intact = true
                for _ in 0..<fields where secret.string() == nil { intact = false }
                if intact, let text = secret.string().flatMap({ String(data: $0, encoding: .utf8) }) { comment = text }
            }
        }
        return SSHPrivateKeyFile(
            type: type, publicKey: publicKey, isEncrypted: cipher != "none", comment: comment,
            text: armor(data)
        )
    }

    /// How many fields follow the type name in the private part of a key, for the kinds supported.
    private static func privateFieldCount(_ type: String) -> Int? {
        switch type {
        case "ssh-ed25519": 2
        case "ssh-rsa": 6
        case _ where type.hasPrefix("ecdsa-sha2-"): 3
        default: nil
        }
    }

    private static func armor(_ data: Data) -> String {
        let base64 = data.base64EncodedString()
        var lines: [Substring] = []
        var rest = Substring(base64)
        while !rest.isEmpty {
            lines.append(rest.prefix(70))
            rest = rest.dropFirst(70)
        }
        return "-----BEGIN \(openSSHLabel)-----\n" + lines.joined(separator: "\n") + "\n-----END \(openSSHLabel)-----\n"
    }

    /// A new Ed25519 key without a passphrase, in OpenSSH format.
    public static func generateEd25519(comment: String = "") -> SSHPrivateKeyFile {
        let key = Curve25519.Signing.PrivateKey()
        let seed = key.rawRepresentation
        let publicBytes = key.publicKey.rawRepresentation
        let type = Data("ssh-ed25519".utf8)

        var publicKey = WireWriter()
        publicKey.string(type)
        publicKey.string(publicBytes)

        var secret = WireWriter()
        let check = UInt32.random(in: .min ... .max)
        secret.uint32(check)
        secret.uint32(check)
        secret.string(type)
        secret.string(publicBytes)
        secret.string(seed + publicBytes)
        secret.string(Data(comment.utf8))
        // Padded to the cipher's block size (8 for "none") with 1, 2, 3, …
        var pad: UInt8 = 1
        while secret.data.count % 8 != 0 {
            secret.data.append(pad)
            pad += 1
        }

        var file = WireWriter()
        file.data.append(magic)
        file.string(Data("none".utf8))
        file.string(Data("none".utf8))
        file.string(Data())
        file.uint32(1)
        file.string(publicKey.data)
        file.string(secret.data)
        return SSHPrivateKeyFile(type: "ssh-ed25519", publicKey: publicKey.data, isEncrypted: false, comment: comment, text: armor(file.data))
    }

    /// "SHA256:" and the unpadded base64 digest of the public key, as `ssh-keygen -l` prints it.
    public var fingerprint: String? {
        publicKey.map(Self.fingerprint(of:))
    }

    static func fingerprint(of publicKey: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: publicKey)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
}

/// Reads the length-prefixed fields of SSH's wire format.
private struct WireReader {
    private var rest: Data

    init(_ data: Data) { rest = data }

    mutating func uint32() -> UInt32? {
        guard rest.count >= 4 else { return nil }
        let value = rest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        rest = rest.dropFirst(4)
        return value
    }

    mutating func string() -> Data? {
        guard let length = uint32(), rest.count >= Int(length) else { return nil }
        let value = Data(rest.prefix(Int(length)))
        rest = rest.dropFirst(Int(length))
        return value
    }
}

private struct WireWriter {
    var data = Data()

    mutating func uint32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(_ value: Data) {
        uint32(UInt32(value.count))
        data.append(value)
    }
}

// MARK: - Store

/// What the app shows about a stored SSH key. Never includes the private half.
public struct SSHKeyInfo: Sendable, Hashable, Codable, Identifiable {
    /// The user's name for the key; what ``ComputerConfiguration/Tunnel/keyName`` refers to.
    public var name: String
    /// See ``SSHPrivateKeyFile/type``.
    public var type: String
    public var publicKey: Data?
    public var fingerprint: String?
    public var isEncrypted: Bool
    public var comment: String
    public var created: Date

    public var id: String { name }

    /// "Ed25519", "RSA", "ECDSA P-256", or "SSH Key" when the file does not say.
    public var typeName: String {
        switch type {
        case "ssh-ed25519": "Ed25519"
        case "ssh-rsa": "RSA"
        case "ecdsa": "ECDSA"
        case _ where type.hasPrefix("ecdsa-sha2-nistp"): "ECDSA P-" + type.dropFirst("ecdsa-sha2-nistp".count)
        default: String(localized: "SSH Key", bundle: #bundle)
        }
    }

    /// The line to add to `~/.ssh/authorized_keys` on a machine that should accept this key.
    public var authorizedKeysLine: String? {
        guard let publicKey else { return nil }
        let label = comment.isEmpty ? name : comment
        return "\(type) \(publicKey.base64EncodedString()) \(label)"
    }
}

/// The user's SSH keys, kept in the Keychain (through a ``SecretStore``) and shared by every saved
/// computer that names one.
///
/// Each private key is its own secret; a separate index secret lists names and public halves, so
/// listing never reads private key material.
public final class SSHKeyStore: Sendable {
    private let secrets: any SecretStore
    /// Serialises changes to the index.
    private let lock = Mutex<Void>(())

    private static let indexKey = SecretKey(appWide: .sshKeyIndex, name: "index")

    public init(secrets: any SecretStore) {
        self.secrets = secrets
    }

    private static func key(_ name: String) -> SecretKey { SecretKey(appWide: .sshPrivateKey, name: name) }
    private static func passphraseKey(_ name: String) -> SecretKey { SecretKey(appWide: .keyPassphrase, name: name) }

    private func storing<T>(_ body: () throws -> T) throws(SSHKeyError) -> T {
        do {
            return try body()
        } catch SecretStoreError.storeFailure(let code) {
            throw .storage(code: code)
        } catch {
            throw .storage(code: -1)
        }
    }

    private func readIndex() throws(SSHKeyError) -> [SSHKeyInfo] {
        guard let text = try storing({ try secrets.secret(for: Self.indexKey) }) else { return [] }
        return try storing { try JSONDecoder().decode([SSHKeyInfo].self, from: Data(text.utf8)) }
    }

    private func writeIndex(_ index: [SSHKeyInfo]) throws(SSHKeyError) {
        try storing {
            let data = try JSONEncoder().encode(index)
            try secrets.setSecret(String(decoding: data, as: UTF8.self), for: Self.indexKey)
        }
    }

    /// Every stored key, sorted by name.
    public func all() throws(SSHKeyError) -> [SSHKeyInfo] {
        try readIndex().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func key(named name: String) -> SSHKeyInfo? {
        (try? readIndex())?.first { $0.name == name }
    }

    /// `base` if no key has that name yet, else "base 2", "base 3", …
    public func availableName(basedOn base: String) -> String {
        let taken = Set(((try? readIndex()) ?? []).map(\.name))
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = trimmed.isEmpty ? String(localized: "SSH Key", bundle: #bundle) : trimmed
        guard taken.contains(stem) else { return stem }
        var number = 2
        while taken.contains("\(stem) \(number)") { number += 1 }
        return "\(stem) \(number)"
    }

    /// Stores a private key the user pasted or picked: OpenSSH format, or PEM (RSA, EC, PKCS#8).
    @discardableResult
    public func importKey(named name: String, text: String, now: Date = Date()) throws(SSHKeyError) -> SSHKeyInfo {
        try add(try SSHPrivateKeyFile(text: text), named: name, now: now)
    }

    /// Creates and stores a new Ed25519 key without a passphrase; the Keychain protects it.
    @discardableResult
    public func generateEd25519(named name: String, now: Date = Date()) throws(SSHKeyError) -> SSHKeyInfo {
        try add(SSHPrivateKeyFile.generateEd25519(comment: name.trimmingCharacters(in: .whitespacesAndNewlines)), named: name, now: now)
    }

    private func add(_ file: SSHPrivateKeyFile, named rawName: String, now: Date) throws(SSHKeyError) -> SSHKeyInfo {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .invalidName }
        let info = SSHKeyInfo(
            name: name, type: file.type, publicKey: file.publicKey, fingerprint: file.fingerprint,
            isEncrypted: file.isEncrypted, comment: file.comment, created: now
        )
        return try lock.withLock { _ throws(SSHKeyError) in
            var index = try readIndex()
            guard !index.contains(where: { $0.name == name }) else { throw .nameInUse(name) }
            // The key first: an entry in the index must never point at nothing.
            try storing { try secrets.setSecret(file.text, for: Self.key(name)) }
            // A passphrase left behind by an earlier key of the same name is not this key's.
            try? secrets.removeSecret(for: Self.passphraseKey(name))
            index.append(info)
            try writeIndex(index)
            return info
        }
    }

    /// Removes a key and its remembered passphrase. Computers that name it fall back to passwords.
    public func delete(named name: String) throws(SSHKeyError) {
        try lock.withLock { _ throws(SSHKeyError) in
            var index = try readIndex()
            index.removeAll { $0.name == name }
            try writeIndex(index)
            try storing { try secrets.removeSecret(for: Self.key(name)) }
            try? secrets.removeSecret(for: Self.passphraseKey(name))
        }
    }

    /// The private key file, for logging in. `nil` if there is no key of that name.
    public func privateKey(named name: String) throws(SSHKeyError) -> Data? {
        try storing { try secrets.secret(for: Self.key(name)) }.map { Data($0.utf8) }
    }

    /// Whether a passphrase is remembered for the key. The passphrase itself is only ever read by
    /// the ``PromptBroker``, when the key is used.
    public func hasRememberedPassphrase(for name: String) -> Bool {
        ((try? secrets.secret(for: Self.passphraseKey(name))) ?? nil) != nil
    }

    public func forgetPassphrase(for name: String) {
        try? secrets.removeSecret(for: Self.passphraseKey(name))
    }
}
