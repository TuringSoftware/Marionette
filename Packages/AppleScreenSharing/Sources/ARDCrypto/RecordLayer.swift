// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import ARDProtocol
public import Foundation

/// The AES-128 key and IV a rekey installs. Both directions start from this pair and diverge as
/// each side's chain advances.
public struct RecordKeys: Sendable, Equatable {
    public var key: Data
    public var iv: Data

    public init(key: Data, iv: Data) {
        self.key = key
        self.iv = iv
    }

    /// Length of a rekey rectangle's body: a generation word, a wrapped key, a wrapped IV.
    public static let rekeyLength = 36

    /// Recovers the keys from a rekey body. Each half is one AES block decrypted on its own under
    /// the key the login produced.
    public static func unwrap(_ body: Data, wrapKey: Data) throws(CryptoError) -> (generation: UInt32, keys: RecordKeys) {
        guard body.count == rekeyLength else { throw .failure("rekey body of \(body.count) bytes") }
        let base = body.startIndex
        let generation = body[base..<(base + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let key = try AES128.decryptECB(body.subdata(in: (base + 4)..<(base + 20)), key: wrapKey)
        let iv = try AES128.decryptECB(body.subdata(in: (base + 20)..<(base + 36)), key: wrapKey)
        return (generation, RecordKeys(key: key, iv: iv))
    }
}

public enum RecordError: Error, Sendable, Equatable {
    /// A record's length is not a whole number of blocks, or too short to hold a record.
    case misframed(length: Int)
    /// The integrity check failed: corruption, tampering, or a lost or repeated record.
    case integrityFailure(sequence: UInt32)
    case crypto(CryptoError)
}

/// Record geometry shared by both directions.
///
///     u16 ciphertext_len
///     AES-128-CBC( u16 body_len || body || filler || SHA1(u32 seq || everything before it) )
enum RecordFormat {
    static let block = AES128.blockSize
    static let trailer = 20
    static let bodyLengthField = 2
    /// Largest ciphertext the length prefix can describe, in whole blocks.
    static let maximumCiphertext = Int(UInt16.max) / block * block
    static let maximumBody = maximumCiphertext - bodyLengthField - trailer

    static func filler(forBody length: Int) -> Int {
        (block - (bodyLengthField + length + trailer) % block) % block
    }

    static let minimumCiphertext = bodyLengthField + filler(forBody: 0) + trailer

    static func trailer(sequence: UInt32, covering plaintext: Data) -> Data {
        var input = Data(capacity: 4 + plaintext.count)
        withUnsafeBytes(of: sequence.bigEndian) { input.append(contentsOf: $0) }
        input.append(plaintext)
        return Digest.sha1(input)
    }
}

/// Wraps outgoing messages in records. Not thread-safe: seal and transmit in one critical section,
/// because a record only decrypts in the order it was sealed.
public final class RecordSealer {
    private let cipher: AES128CBCStream
    private var sequence: UInt32 = 0

    public init(keys: RecordKeys) throws(CryptoError) {
        cipher = try AES128CBCStream(.encrypt, key: keys.key, iv: keys.iv)
    }

    /// One complete message as one or more records.
    public func seal(_ message: Data) throws(CryptoError) -> Data {
        var output = Data(capacity: message.count + 64)
        var offset = message.startIndex
        repeat {
            let length = min(RecordFormat.maximumBody, message.endIndex - offset)
            try appendRecord(message.subdata(in: offset..<(offset + length)), to: &output)
            offset += length
        } while offset < message.endIndex
        return output
    }

    private func appendRecord(_ body: Data, to output: inout Data) throws(CryptoError) {
        var plaintext = Data(capacity: RecordFormat.bodyLengthField + body.count + RecordFormat.block + RecordFormat.trailer)
        plaintext.append(UInt8(body.count >> 8))
        plaintext.append(UInt8(truncatingIfNeeded: body.count))
        plaintext.append(body)
        plaintext.append(Data(count: RecordFormat.filler(forBody: body.count)))
        plaintext.append(RecordFormat.trailer(sequence: sequence, covering: plaintext))
        sequence &+= 1
        let ciphertext = try cipher.update(plaintext)
        output.append(UInt8(ciphertext.count >> 8))
        output.append(UInt8(truncatingIfNeeded: ciphertext.count))
        output.append(ciphertext)
    }
}

/// Unwraps incoming records back into the byte stream they carry. Not thread-safe.
public final class RecordOpener {
    private let cipher: AES128CBCStream
    private var sequence: UInt32 = 0

    public init(keys: RecordKeys) throws(CryptoError) {
        cipher = try AES128CBCStream(.decrypt, key: keys.key, iv: keys.iv)
    }

    /// Moves every complete record in `ciphertext` into `plaintext`. A partial record stays where it
    /// is until the rest arrives. Messages may span records, so the result is a stream, not messages.
    public func open(from ciphertext: inout InboundBuffer, into plaintext: inout InboundBuffer) throws(RecordError) {
        while true {
            let record: Data?
            do {
                record = try ciphertext.parse { (reader: inout WireReader) throws(WireError) -> Data in
                    let length = Int(try reader.u16())
                    guard length % RecordFormat.block == 0, length >= RecordFormat.minimumCiphertext else {
                        throw .malformed("\(length)")
                    }
                    return try reader.take(length)
                }
            } catch .malformed(let text) {
                throw .misframed(length: Int(text) ?? -1)
            } catch {
                return // unreachable: truncation is reported as nil
            }
            guard let record else { return }
            plaintext.append(try decrypt(record))
        }
    }

    private func decrypt(_ record: Data) throws(RecordError) -> Data {
        let clear: Data
        do {
            // Only reached with a whole record in hand: decrypting advances the chain for good.
            clear = try cipher.update(record)
        } catch {
            throw .crypto(error)
        }
        let current = sequence
        sequence &+= 1
        let covered = clear.count - RecordFormat.trailer
        let bodyLength = Int(clear[clear.startIndex]) << 8 | Int(clear[clear.startIndex + 1])
        guard bodyLength <= covered - RecordFormat.bodyLengthField else {
            throw .integrityFailure(sequence: current)
        }
        let expected = RecordFormat.trailer(sequence: current, covering: clear.prefix(covered))
        // Compared in constant time so a forger learns nothing from how early a mismatch is found.
        var difference: UInt8 = 0
        for (a, b) in zip(expected, clear.suffix(RecordFormat.trailer)) { difference |= a ^ b }
        guard difference == 0 else { throw .integrityFailure(sequence: current) }
        return clear.subdata(in: (clear.startIndex + 2)..<(clear.startIndex + 2 + bodyLength))
    }
}
