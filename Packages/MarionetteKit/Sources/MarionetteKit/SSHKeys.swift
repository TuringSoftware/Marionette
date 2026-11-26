// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
public import Foundation
public import RemoteDesktopTransport
import Security
import SwiftSSH2
import Synchronization

// MARK: - Key files

public enum SSHKeyError: Error, Sendable, Hashable {
    /// The text is not a private key (a public key, or something else entirely).
    case notAPrivateKey
    /// A private key of a kind Marionette cannot log in with (`type` as the file names it).
    case unsupportedKeyType(String)
    case nameInUse(String)
    /// This device has no Secure Enclave, or it refused to make a key.
    case secureEnclaveUnavailable
    /// The Keychain refused (an `OSStatus`), or what it holds could not be read back (-1).
    case storage(code: Int32)

    /// The failure in words for the person importing or creating a key.
    public var message: String {
        switch self {
        case .notAPrivateKey:
            String(localized: "This isn’t an SSH private key. Paste the whole private key file, from “-----BEGIN” to the “-----END” line.", bundle: #bundle)
        case .unsupportedKeyType(let type):
            String(localized: "Marionette can’t use \(type) keys. Use an Ed25519, ECDSA or RSA key.", bundle: #bundle)
        case .nameInUse(let name):
            String(localized: "There is already a key named “\(name)”.", bundle: #bundle)
        case .secureEnclaveUnavailable:
            String(localized: "The Secure Enclave couldn’t make a key.", bundle: #bundle)
        case .storage(let code):
            String(localized: "The key couldn’t be saved in the Keychain (error \(code)).", bundle: #bundle)
        }
    }
}

/// The kinds of key Marionette makes.
public enum SSHKeyType: String, Sendable, Hashable, Codable, CaseIterable {
    case ed25519
    case ecdsa
    case rsa

    public var title: String {
        switch self {
        case .ed25519: "Ed25519"
        case .ecdsa: "ECDSA"
        case .rsa: "RSA"
        }
    }

    /// The sizes offered, in bits. Ed25519 has one.
    public var sizes: [Int] {
        switch self {
        case .ed25519: [256]
        case .ecdsa: [256, 384, 521]
        case .rsa: [1024, 2048, 3072, 4096]
        }
    }

    /// The size a new key of the type gets unless another is chosen.
    public var defaultSize: Int {
        switch self {
        case .ed25519, .ecdsa: 256
        case .rsa: 3072
        }
    }
}

/// A kind of key and its size. Older servers lack the newer kinds: Ed25519 needs OpenSSH 6.5,
/// ECDSA 5.7; RSA works everywhere.
public struct SSHKeyAlgorithm: Sendable, Hashable, Codable {
    public var type: SSHKeyType
    /// The size in bits: of the curve for Ed25519 and ECDSA, of the modulus for RSA.
    public var bits: Int

    public init(type: SSHKeyType, bits: Int? = nil) {
        self.type = type
        self.bits = bits.flatMap { type.sizes.contains($0) ? $0 : nil } ?? type.defaultSize
    }

    public static let ed25519 = SSHKeyAlgorithm(type: .ed25519)
    /// The only kind a Secure Enclave makes.
    public static let secureEnclave = SSHKeyAlgorithm(type: .ecdsa, bits: 256)

    /// "Ed25519", "ECDSA P-256", "RSA 3072".
    public var title: String {
        switch type {
        case .ed25519: type.title
        case .ecdsa, .rsa: "\(type.title) \(sizeTitle(bits))"
        }
    }

    /// A size as the strength picker shows it: "P-256" for a curve, "3072" for RSA.
    public func sizeTitle(_ bits: Int) -> String {
        type == .ecdsa ? "P-\(bits)" : "\(bits)"
    }

    /// RSA below 2048 bits can be broken with enough computing power.
    public var isRecommended: Bool { type != .rsa || bits >= 2048 }

    /// Why the choice is not recommended, for the person making the key.
    public var caution: String? {
        let size = String(bits)
        return isRecommended ? nil : String(localized: "A \(size)-bit RSA key can be broken. Use one only for a server that accepts nothing stronger.", bundle: #bundle)
    }

    var sshName: String {
        switch type {
        case .ed25519: "ssh-ed25519"
        case .ecdsa: "ecdsa-sha2-\(curveName)"
        case .rsa: "ssh-rsa"
        }
    }

    var curveName: String { "nistp\(bits)" }
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

    /// A new key without a passphrase, in OpenSSH format.
    public static func generate(_ algorithm: SSHKeyAlgorithm, comment: String = "") throws(SSHKeyError) -> SSHPrivateKeyFile {
        switch algorithm.type {
        case .ed25519:
            let key = Curve25519.Signing.PrivateKey()
            let publicBytes = key.publicKey.rawRepresentation
            return openSSH(
                type: "ssh-ed25519", publicFields: [publicBytes],
                privateFields: [publicBytes, key.rawRepresentation + publicBytes], comment: comment
            )
        case .ecdsa:
            let (point, scalar): (Data, Data) = switch algorithm.bits {
            case 384: P384.Signing.PrivateKey().withRepresentations
            case 521: P521.Signing.PrivateKey().withRepresentations
            default: P256.Signing.PrivateKey().withRepresentations
            }
            let curve = Data(algorithm.curveName.utf8)
            return openSSH(
                type: algorithm.sshName, publicFields: [curve, point],
                privateFields: [curve, point, mpint(scalar)], comment: comment
            )
        case .rsa:
            let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: algorithm.bits]
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
                  let der = SecKeyCopyExternalRepresentation(key, &error) as Data?,
                  // PKCS #1: version, n, e, d, p, q, d mod (p-1), d mod (q-1), q⁻¹ mod p.
                  let integers = DERReader.integers(inSequence: der), integers.count == 9
            else { throw .storage(code: Int32(truncatingIfNeeded: error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? -1)) }
            let (n, e, d, p, q, iqmp) = (integers[1], integers[2], integers[3], integers[4], integers[5], integers[8])
            return openSSH(type: "ssh-rsa", publicFields: [e, n], privateFields: [n, e, d, iqmp, p, q], comment: comment)
        }
    }

    /// A Secure Enclave key's public half as SSH names it, for one made by ``HardwareKeys``.
    static func hardwarePublicKey(x963 point: Data) -> Data {
        var publicKey = WireWriter()
        publicKey.string(Data(SSHKeyAlgorithm.secureEnclave.sshName.utf8))
        publicKey.string(Data(SSHKeyAlgorithm.secureEnclave.curveName.utf8))
        publicKey.string(point)
        return publicKey.data
    }

    /// An unencrypted OpenSSH private key file. The fields are the key type's own, as wire-format
    /// strings (an mpint is a string of its two's-complement bytes).
    private static func openSSH(type: String, publicFields: [Data], privateFields: [Data], comment: String) -> SSHPrivateKeyFile {
        let typeName = Data(type.utf8)
        var publicKey = WireWriter()
        publicKey.string(typeName)
        for field in publicFields { publicKey.string(field) }

        var secret = WireWriter()
        let check = UInt32.random(in: .min ... .max)
        secret.uint32(check)
        secret.uint32(check)
        secret.string(typeName)
        for field in privateFields { secret.string(field) }
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
        return SSHPrivateKeyFile(type: type, publicKey: publicKey.data, isEncrypted: false, comment: comment, text: armor(file.data))
    }

    /// An unsigned big-endian number as an mpint's bytes: no leading zeros, and one zero in front
    /// when the top bit is set.
    static func mpint(_ unsigned: some Collection<UInt8>) -> Data {
        var bytes = Data(unsigned.drop { $0 == 0 })
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return bytes
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

/// Reads the integers of a DER sequence, such as an RSA private key in PKCS #1 form. A DER integer's
/// bytes are already an mpint's.
private enum DERReader {
    static func integers(inSequence der: Data) -> [Data]? {
        var rest = der[...]
        guard rest.popFirst() == 0x30, let length = Self.length(&rest), rest.count == length else { return nil }
        var integers: [Data] = []
        while !rest.isEmpty {
            guard rest.popFirst() == 0x02, let length = Self.length(&rest), rest.count >= length else { return nil }
            integers.append(Data(rest.prefix(length)))
            rest = rest.dropFirst(length)
        }
        return integers
    }

    private static func length(_ rest: inout Data.SubSequence) -> Int? {
        guard let first = rest.popFirst() else { return nil }
        guard first & 0x80 != 0 else { return Int(first) }
        let count = Int(first & 0x7F)
        guard (1...4).contains(count), rest.count >= count else { return nil }
        let value = rest.prefix(count).reduce(0) { $0 << 8 | Int($1) }
        rest = rest.dropFirst(count)
        return value
    }
}

extension P256.Signing.PrivateKey {
    fileprivate var withRepresentations: (point: Data, scalar: Data) { (publicKey.x963Representation, rawRepresentation) }
}

extension P384.Signing.PrivateKey {
    fileprivate var withRepresentations: (point: Data, scalar: Data) { (publicKey.x963Representation, rawRepresentation) }
}

extension P521.Signing.PrivateKey {
    fileprivate var withRepresentations: (point: Data, scalar: Data) { (publicKey.x963Representation, rawRepresentation) }
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

/// Where a new key is kept, and who may use it.
public struct SSHKeyStorage: Sendable, Hashable, Codable {
    private var enclave: Bool
    private var secret: SecretProtection

    public init(isInSecureEnclave: Bool = false, protection: SecretProtection = .standard) {
        enclave = false
        secret = protection
        self.isInSecureEnclave = isInSecureEnclave
    }

    /// The private key is made in this device's Secure Enclave and never leaves it: it is an ECDSA
    /// P-256 key, and cannot be backed up, synchronised or restored. Turning it on takes the key out
    /// of backups and iCloud Keychain.
    public var isInSecureEnclave: Bool {
        get { enclave }
        set {
            enclave = newValue
            if newValue { secret.includedInBackups = false }
        }
    }

    /// Who may use the key and where copies of it go. Backups or iCloud Keychain take it out of the
    /// Secure Enclave, which keeps it on this device.
    public var protection: SecretProtection {
        get { secret }
        set {
            secret = newValue
            if newValue.includedInBackups || newValue.synchronizes { enclave = false }
        }
    }
}

extension SSHKeyStorage {
    /// What sets the key apart from one kept on this device alone, in a few words:
    /// "Backed Up · Face ID", "Secure Enclave". `nil` for a key kept on this device alone.
    public func summary(ownerCheck: OwnerCheck) -> String? {
        var parts: [String] = []
        if isInSecureEnclave { parts.append(String(localized: "Secure Enclave", bundle: #bundle)) }
        // iCloud Keychain implies backups.
        if protection.synchronizes {
            parts.append(String(localized: "iCloud Keychain", bundle: #bundle))
        } else if protection.includedInBackups {
            parts.append(String(localized: "Backed Up", bundle: #bundle))
        }
        if protection.requiresUserPresence { parts.append(ownerCheck.name) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

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
    public var storage: SSHKeyStorage

    public var id: String { name }

    /// "Ed25519", "RSA 3072", "ECDSA P-256", or "SSH Key" when the file does not say.
    public var typeName: String {
        switch type {
        case "ssh-ed25519": "Ed25519"
        case "ssh-rsa": rsaBits.map { "RSA \($0)" } ?? "RSA"
        case "ecdsa": "ECDSA"
        case _ where type.hasPrefix("ecdsa-sha2-nistp"): "ECDSA P-" + type.dropFirst("ecdsa-sha2-nistp".count)
        default: String(localized: "SSH Key", bundle: #bundle)
        }
    }

    /// The size of an RSA key's modulus, from its public key.
    private var rsaBits: Int? {
        guard let publicKey else { return nil }
        var reader = WireReader(publicKey)
        guard reader.string() != nil, reader.string() != nil, let modulus = reader.string() else { return nil }
        let bytes = modulus.drop { $0 == 0 }
        guard let first = bytes.first else { return nil }
        return (bytes.count - 1) * 8 + (8 - first.leadingZeroBitCount)
    }

    /// The line to add to `~/.ssh/authorized_keys` on a machine that should accept this key.
    public var authorizedKeysLine: String? {
        guard let publicKey else { return nil }
        let label = comment.isEmpty ? name : comment
        return "\(type) \(publicKey.base64EncodedString()) \(label)"
    }
}

/// How to sign in with a stored key.
public enum SSHLoginKey: Sendable {
    /// A private key file, which may still need its passphrase.
    case file(Data)
    /// A key that signs where it is kept.
    case signer(SSHKeySigner)
}

/// The user's SSH keys, kept in the Keychain (through a ``SecretStore``) and shared by every saved
/// computer that names one.
///
/// Each key is two secrets: the private key, kept as the user chose, and a description of it (its
/// kind, public key and storage), kept in the same places but never behind the owner check, so that
/// listing keys reads no private key and asks no one. A Secure Enclave key's private secret is the
/// enclave's handle to it, which is of use on this device only.
public final class SSHKeyStore: Sendable {
    private let secrets: any SecretStore
    /// Where Secure Enclave keys are made and used.
    public let hardware: any HardwareKeys
    /// Serialises adding and removing keys.
    private let lock = Mutex<Void>(())

    public init(secrets: any SecretStore, hardware: any HardwareKeys = SecureEnclaveKeys()) {
        self.secrets = secrets
        self.hardware = hardware
    }

    private static func infoKey(_ name: String) -> SecretKey { SecretKey(appWide: .sshKeyInfo, name: name) }
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

    /// Every stored key, sorted by name.
    public func all() throws(SSHKeyError) -> [SSHKeyInfo] {
        let names = try storing { try secrets.names(of: .sshKeyInfo) }
        // A name can appear twice when a key synchronised from another device meets one of this
        // device's: the first is shown.
        var seen = Set<String>()
        return names.compactMap { name in seen.insert(name).inserted ? key(named: name) : nil }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func key(named name: String) -> SSHKeyInfo? {
        guard let text = (try? secrets.secret(for: Self.infoKey(name))) ?? nil else { return nil }
        return try? JSONDecoder().decode(SSHKeyInfo.self, from: Data(text.utf8))
    }

    /// `base` if no key has that name yet, else "base 2", "base 3", …
    public func availableName(basedOn base: String) -> String {
        let taken = Set((try? secrets.names(of: .sshKeyInfo)) ?? [])
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = trimmed.isEmpty ? String(localized: "SSH Key", bundle: #bundle) : trimmed
        guard taken.contains(stem) else { return stem }
        var number = 2
        while taken.contains("\(stem) \(number)") { number += 1 }
        return "\(stem) \(number)"
    }

    /// The name a new key gets when it is given none.
    public static func defaultName(for algorithm: SSHKeyAlgorithm, storage: SSHKeyStorage) -> String {
        storage.isInSecureEnclave
            ? String(localized: "Secure Enclave Key", bundle: #bundle)
            : String(localized: "\(algorithm.title) Key", bundle: #bundle)
    }

    /// The name an imported key gets when it is given none.
    public static var defaultImportName: String { String(localized: "Imported Key", bundle: #bundle) }

    /// Stores a private key the user pasted or picked: OpenSSH format, or PEM (RSA, EC, PKCS#8).
    /// Without a name it gets an unused one.
    @discardableResult
    public func importKey(named name: String? = nil, text: String, protection: SecretProtection = .standard, now: Date = Date()) throws(SSHKeyError) -> SSHKeyInfo {
        let file = try SSHPrivateKeyFile(text: text)
        return try add(named: name, defaultName: Self.defaultImportName, now: now) { name in
            (file.text, Self.info(of: file, name: name, storage: SSHKeyStorage(protection: protection), now: now))
        }
    }

    /// Creates and stores a new key without a passphrase; the Keychain or the Secure Enclave
    /// protects it. A Secure Enclave key is always ECDSA P-256. Without a name it gets an unused one.
    @discardableResult
    public func generate(
        named name: String? = nil, algorithm: SSHKeyAlgorithm = .ed25519, storage: SSHKeyStorage = SSHKeyStorage(), now: Date = Date()
    ) throws(SSHKeyError) -> SSHKeyInfo {
        let algorithm = storage.isInSecureEnclave ? .secureEnclave : algorithm
        return try add(named: name, defaultName: Self.defaultName(for: algorithm, storage: storage), now: now) { name throws(SSHKeyError) in
            if storage.isInSecureEnclave {
                guard hardware.isAvailable else { throw .secureEnclaveUnavailable }
                let made: (handle: Data, publicKey: Data)
                do {
                    made = try hardware.makeKey(requiresUserPresence: storage.protection.requiresUserPresence)
                } catch {
                    throw .secureEnclaveUnavailable
                }
                let publicKey = SSHPrivateKeyFile.hardwarePublicKey(x963: made.publicKey)
                let info = SSHKeyInfo(
                    name: name, type: algorithm.sshName, publicKey: publicKey, fingerprint: SSHPrivateKeyFile.fingerprint(of: publicKey),
                    isEncrypted: false, comment: name, created: now, storage: storage
                )
                return (made.handle.base64EncodedString(), info)
            }
            let file = try SSHPrivateKeyFile.generate(algorithm, comment: name)
            return (file.text, Self.info(of: file, name: name, storage: storage, now: now))
        }
    }

    private static func info(of file: SSHPrivateKeyFile, name: String, storage: SSHKeyStorage, now: Date) -> SSHKeyInfo {
        SSHKeyInfo(
            name: name, type: file.type, publicKey: file.publicKey, fingerprint: file.fingerprint,
            isEncrypted: file.isEncrypted, comment: file.comment, created: now, storage: storage
        )
    }

    private func add(
        named rawName: String?, defaultName: String, now: Date, make: (String) throws(SSHKeyError) -> (secret: String, info: SSHKeyInfo)
    ) throws(SSHKeyError) -> SSHKeyInfo {
        try lock.withLock { _ throws(SSHKeyError) in
            let typed = rawName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = typed.isEmpty ? availableName(basedOn: defaultName) : typed
            guard !secrets.hasSecret(for: Self.infoKey(name)) else { throw .nameInUse(name) }
            let (secret, info) = try make(name)
            let protection = info.storage.protection
            let infoText = try storing { String(decoding: try JSONEncoder().encode(info), as: UTF8.self) }
            // The key first: a description must never point at nothing.
            try storing { try secrets.setSecret(secret, for: Self.key(name), protection: protection) }
            // A passphrase left behind by an earlier key of the same name is not this key's.
            try? secrets.removeSecret(for: Self.passphraseKey(name))
            do throws(SSHKeyError) {
                try storing { try secrets.setSecret(infoText, for: Self.infoKey(name), protection: protection.withoutUserPresence) }
            } catch {
                try? secrets.removeSecret(for: Self.key(name))
                throw error
            }
            return info
        }
    }

    /// Removes a key and its remembered passphrase, here and, for a key in iCloud Keychain, on the
    /// user's other devices. Computers that name it fall back to passwords.
    public func delete(named name: String) throws(SSHKeyError) {
        try lock.withLock { _ throws(SSHKeyError) in
            try storing { try secrets.removeSecret(for: Self.infoKey(name)) }
            try storing { try secrets.removeSecret(for: Self.key(name)) }
            try? secrets.removeSecret(for: Self.passphraseKey(name))
        }
    }

    /// The key to sign in with, unlocked through `access` if it requires the device owner. `nil` if
    /// there is no key of that name, or the owner did not agree.
    public func loginKey(named name: String, access: SecretAccess, reason: String) async -> SSHLoginKey? {
        guard let info = key(named: name) else { return nil }
        guard let secret = try? await secrets.unlockedSecret(for: Self.key(name), access: access, reason: reason) else { return nil }
        guard info.storage.isInSecureEnclave else { return .file(Data(secret.utf8)) }
        guard let handle = Data(base64Encoded: secret), let publicKey = info.publicKey else { return nil }
        // The enclave asks no one by itself: the owner agrees before the server is contacted.
        if info.storage.protection.requiresUserPresence, await !access.authenticate(reason: reason) { return nil }
        let hardware = hardware
        return .signer(SSHKeySigner(publicKey: publicKey) { data in
            hardware.sign(data, handle: handle, access: access).map(SSHAuthentication.ecdsaSignature(raw:))
        })
    }

    /// The private key file, for tests and tools. `nil` if there is none, or it needs the owner.
    public func privateKey(named name: String) throws(SSHKeyError) -> Data? {
        do {
            return try secrets.secret(for: Self.key(name)).map { Data($0.utf8) }
        } catch SecretStoreError.authenticationRequired {
            return nil
        } catch SecretStoreError.storeFailure(let code) {
            throw .storage(code: code)
        } catch {
            throw .storage(code: -1)
        }
    }

    /// How a passphrase remembered for the key is kept: as the key itself is.
    public func passphraseProtection(for name: String) -> SecretProtection {
        key(named: name)?.storage.protection ?? .thisDeviceOnly
    }

    /// Whether a passphrase is remembered for the key. The passphrase itself is only ever read by
    /// the ``PromptBroker``, when the key is used.
    public func hasRememberedPassphrase(for name: String) -> Bool {
        secrets.hasSecret(for: Self.passphraseKey(name))
    }

    public func forgetPassphrase(for name: String) {
        try? secrets.removeSecret(for: Self.passphraseKey(name))
    }
}
