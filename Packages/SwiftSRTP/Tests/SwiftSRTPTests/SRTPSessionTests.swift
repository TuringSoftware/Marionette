// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CommonCrypto
import CryptoKit
import Foundation
import SwiftSRTP
import Testing

/// An independent implementation of RFC 3711 / RFC 6188 for one packet, written straight from the
/// RFCs on top of Apple's AES and HMAC, to check the wrapped library against.
enum ReferenceSRTP {
    static func aesCTR(key: Data, counter: Data, length: Int) -> Data {
        var cryptor: CCCryptorRef?
        key.withUnsafeBytes { keyBytes in
            counter.withUnsafeBytes { ivBytes in
                _ = CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    ivBytes.baseAddress, keyBytes.baseAddress, keyBytes.count, nil, 0, 0,
                    CCModeOptions(kCCModeOptionCTR_BE), &cryptor
                )
            }
        }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: length)
        var moved = 0
        let zeros = Data(count: length)
        output.withUnsafeMutableBytes { out in
            zeros.withUnsafeBytes { input in
                _ = CCCryptorUpdate(cryptor, input.baseAddress, length, out.baseAddress, length, &moved)
            }
        }
        return output
    }

    /// RFC 3711 §4.3.1 with a key derivation rate of zero.
    static func derive(masterKey: Data, masterSalt: Data, label: UInt8, length: Int) -> Data {
        var x = [UInt8](masterSalt) // 14 bytes
        x[7] ^= label // key_id = label || 48-bit r(=0), right-aligned in 112 bits
        return aesCTR(key: masterKey, counter: Data(x + [0, 0]), length: length)
    }

    static func xor(_ a: Data, _ b: Data) -> Data {
        Data(zip(a, b).map { $0 ^ $1 })
    }

    static func protect(rtp: Data, master: Data, rolloverCounter: UInt32 = 0) -> Data {
        let masterKey = master.prefix(32)
        let masterSalt = master.suffix(14)
        let encryptionKey = derive(masterKey: masterKey, masterSalt: masterSalt, label: 0, length: 32)
        let authenticationKey = derive(masterKey: masterKey, masterSalt: masterSalt, label: 1, length: 20)
        let salt = derive(masterKey: masterKey, masterSalt: masterSalt, label: 2, length: 14)

        let sequence = UInt16(rtp[2]) << 8 | UInt16(rtp[3])
        let ssrc = rtp.subdata(in: 8..<12)
        let index = UInt64(rolloverCounter) << 16 | UInt64(sequence)
        // IV = (salt * 2^16) XOR (SSRC * 2^64) XOR (index * 2^16)
        var iv = [UInt8](salt) + [0, 0]
        for (offset, byte) in ssrc.enumerated() { iv[4 + offset] ^= byte }
        for shift in 0..<6 { iv[13 - shift] ^= UInt8(truncatingIfNeeded: index >> (8 * UInt64(shift))) }

        let header = rtp.prefix(12)
        let payload = rtp.dropFirst(12)
        let encrypted = xor(Data(payload), aesCTR(key: encryptionKey, counter: Data(iv), length: payload.count))
        var authenticated = Data(header) + encrypted
        var roc = rolloverCounter.bigEndian
        let tagInput = authenticated + Data(bytes: &roc, count: 4)
        let tag = Data(HMAC<Insecure.SHA1>.authenticationCode(for: tagInput, using: SymmetricKey(data: authenticationKey))).prefix(10)
        authenticated.append(tag)
        return authenticated
    }
}

func rtpPacket(sequence: UInt16, timestamp: UInt32 = 1000, ssrc: UInt32 = 0xCAFE_BABE, payloadType: UInt8 = 100, payload: Data = Data((0..<40).map { UInt8($0) })) -> Data {
    var packet = Data([0x80, payloadType, UInt8(sequence >> 8), UInt8(sequence & 0xff)])
    for value in [timestamp, ssrc] {
        packet.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }
    packet.append(payload)
    return packet
}

func receiverReport(ssrc: UInt32) -> Data {
    Data([0x80, 201, 0x00, 0x01, UInt8(ssrc >> 24), UInt8(ssrc >> 16 & 0xff), UInt8(ssrc >> 8 & 0xff), UInt8(ssrc & 0xff)])
}

let testKey = Data((0..<46).map { UInt8(truncatingIfNeeded: 0x11 &* ($0 &+ 3)) })

@Suite struct SRTPSessionTests {
    @Test func outputMatchesIndependentImplementation() throws {
        let sender = try SRTPSession(direction: .outbound, masterKey: testKey)
        for sequence in [UInt16(1), 2, 500, 65_535] {
            let packet = rtpPacket(sequence: sequence, payload: Data((0..<173).map { UInt8(truncatingIfNeeded: $0 &* 5) }))
            #expect(try sender.protect(packet) == ReferenceSRTP.protect(rtp: packet, master: testKey), "sequence \(sequence)")
        }
    }

    @Test func acceptsPacketsMadeByTheIndependentImplementation() throws {
        let receiver = try SRTPSession(direction: .inbound, masterKey: testKey)
        let packet = rtpPacket(sequence: 77)
        #expect(try receiver.unprotect(ReferenceSRTP.protect(rtp: packet, master: testKey)) == packet)
    }

    @Test func roundTripsAcrossSSRCs() throws {
        let sender = try SRTPSession(direction: .outbound, masterKey: testKey)
        let receiver = try SRTPSession(direction: .inbound, masterKey: testKey)
        // Four strips of a display arrive on consecutive SSRCs, each with its own numbering.
        for ssrc in UInt32(1000)..<1004 {
            for sequence in UInt16(10)..<20 {
                let packet = rtpPacket(sequence: sequence, ssrc: ssrc)
                let protected = try sender.protect(packet)
                #expect(protected.count == packet.count + SRTPSession.rtpOverhead)
                #expect(try receiver.unprotect(protected) == packet)
            }
        }
    }

    @Test func rejectsReplayTamperingAndWrongKey() throws {
        let sender = try SRTPSession(direction: .outbound, masterKey: testKey)
        let receiver = try SRTPSession(direction: .inbound, masterKey: testKey)
        let protected = try sender.protect(rtpPacket(sequence: 5))
        _ = try receiver.unprotect(protected)
        #expect(throws: SRTPError.replayed) { _ = try receiver.unprotect(protected) }

        let next = try sender.protect(rtpPacket(sequence: 6))
        for index in [0, 3, 12, next.count - 11, next.count - 1] {
            var tampered = next
            tampered[index] ^= 0x40
            #expect(throws: SRTPError.self, "byte \(index)") { _ = try receiver.unprotect(tampered) }
        }
        // The untampered packet is still accepted afterwards: failures do not advance the window.
        #expect(try receiver.unprotect(next) == rtpPacket(sequence: 6))

        var otherKey = testKey
        otherKey[0] ^= 1
        let stranger = try SRTPSession(direction: .inbound, masterKey: otherKey)
        #expect(throws: SRTPError.authenticationFailed) { _ = try stranger.unprotect(try sender.protect(rtpPacket(sequence: 7))) }
    }

    @Test func toleratesReorderingWithinTheWindowOnly() throws {
        let sender = try SRTPSession(direction: .outbound, masterKey: testKey)
        let receiver = try SRTPSession(direction: .inbound, masterKey: testKey, replayWindow: 128)
        var protected: [Data] = []
        for sequence in UInt16(0)..<400 { protected.append(try sender.protect(rtpPacket(sequence: sequence))) }
        _ = try receiver.unprotect(protected[0])
        _ = try receiver.unprotect(protected[399])
        // 100 behind the newest is inside a 128-packet window; 300 behind is not.
        #expect(try receiver.unprotect(protected[299]) == rtpPacket(sequence: 299))
        #expect(throws: SRTPError.replayed) { _ = try receiver.unprotect(protected[99]) }
    }

    @Test func survivesSequenceNumberRollover() throws {
        let sender = try SRTPSession(direction: .outbound, masterKey: testKey)
        let receiver = try SRTPSession(direction: .inbound, masterKey: testKey)
        var sequence: UInt16 = 65_000
        // 70,000 packets: the 16-bit sequence wraps and the rollover counter must follow on both sides.
        for count in 0..<70_000 {
            let packet = rtpPacket(sequence: sequence, timestamp: UInt32(count), payload: Data([UInt8(truncatingIfNeeded: count)]))
            let protected = try sender.protect(packet)
            if count == 1000 {
                // Past the first wrap the rollover counter is 1, which the reference must reproduce.
                #expect(sequence == 464)
                #expect(protected == ReferenceSRTP.protect(rtp: packet, master: testKey, rolloverCounter: 1))
            }
            #expect(try receiver.unprotect(protected) == packet)
            sequence &+= 1
        }
    }

    @Test func rtcpRoundTripAndReplay() throws {
        let sender = try SRTPSession(direction: .outbound, masterKey: testKey)
        let receiver = try SRTPSession(direction: .inbound, masterKey: testKey)
        let report = receiverReport(ssrc: 0x0102_0304)
        let first = try sender.protectRTCP(report)
        let second = try sender.protectRTCP(report)
        #expect(first.count == report.count + SRTPSession.rtcpOverhead)
        // The header stays readable; the SRTCP index after the body increments.
        #expect(first.prefix(8) == report.prefix(8))
        #expect(first != second)
        #expect(try receiver.unprotectRTCP(first) == report)
        #expect(try receiver.unprotectRTCP(second) == report)
        #expect(throws: SRTPError.replayed) { _ = try receiver.unprotectRTCP(first) }
        var tampered = try sender.protectRTCP(report)
        tampered[tampered.count - 1] ^= 1
        #expect(throws: SRTPError.authenticationFailed) { _ = try receiver.unprotectRTCP(tampered) }
    }

    @Test func rejectsBadKeysAndRunts() throws {
        #expect(throws: SRTPError.invalidKeyLength(30)) { _ = try SRTPSession(direction: .inbound, masterKey: Data(count: 30)) }
        let receiver = try SRTPSession(direction: .inbound, masterKey: testKey)
        #expect(throws: SRTPError.invalidPacket) { _ = try receiver.unprotect(Data(count: 5)) }
        #expect(throws: SRTPError.invalidPacket) { _ = try receiver.unprotectRTCP(Data(count: 10)) }
        #expect(throws: SRTPError.self) { _ = try receiver.unprotect(Data(count: 60)) }
    }

    @Test func unprotectsInPlaceAndFromSlices() throws {
        let sender = try SRTPSession(direction: .outbound, masterKey: testKey)
        let receiver = try SRTPSession(direction: .inbound, masterKey: testKey)
        let packet = rtpPacket(sequence: 3)
        // A datagram that sits inside a larger buffer, as a parsed slice does.
        let surrounded = Data([0xEE, 0xEE]) + (try sender.protect(packet)) + Data([0xEE])
        var inPlace = surrounded[2..<(surrounded.count - 1)]
        try receiver.unprotect(&inPlace)
        #expect(inPlace == packet)
        var report = try sender.protectRTCP(receiverReport(ssrc: 9))
        try receiver.unprotectRTCP(&report)
        #expect(report == receiverReport(ssrc: 9))
        var forged = try sender.protect(rtpPacket(sequence: 4))
        forged[forged.count - 1] ^= 1
        let before = forged
        #expect(throws: SRTPError.authenticationFailed) { try receiver.unprotect(&forged) }
        #expect(forged == before)
    }

    @Test func aRemovedStreamIsForgotten() throws {
        let sender = try SRTPSession(direction: .outbound, masterKey: testKey)
        let receiver = try SRTPSession(direction: .inbound, masterKey: testKey)
        let protected = try sender.protect(rtpPacket(sequence: 5, ssrc: 42))
        _ = try receiver.unprotect(protected)
        #expect(throws: SRTPError.replayed) { _ = try receiver.unprotect(protected) }
        receiver.removeStream(ssrc: 42)
        // Its replay window went with it; other streams are untouched, and removing twice is harmless.
        #expect(try receiver.unprotect(protected) == rtpPacket(sequence: 5, ssrc: 42))
        receiver.removeStream(ssrc: 7)
        receiver.removeStream(ssrc: 7)
    }

    @Test func aJumpOfMoreThanHalfTheNumberSpaceIsFollowedOnlyByTryingRolloverCounters() throws {
        func packet(index: UInt64) -> (clear: Data, protected: Data) {
            let clear = rtpPacket(sequence: UInt16(truncatingIfNeeded: index), timestamp: UInt32(truncatingIfNeeded: index))
            return (clear, ReferenceSRTP.protect(rtp: clear, master: testKey, rolloverCounter: UInt32(index >> 16)))
        }
        for jump in [UInt64(40_000), 50_000, 200_000] {
            let receiver = try SRTPSession(direction: .inbound, masterKey: testKey)
            // A stream well into its second time round the numbering, reached in steps it can follow.
            let start: UInt64 = 0x1_9000
            for index in stride(from: UInt64(0), to: start, by: 0x4000) { _ = try receiver.unprotect(packet(index: index).protected) }
            for index in start..<(start + 10) { _ = try receiver.unprotect(packet(index: index).protected) }
            let after = start + 9 + jump
            // RFC 3711's guess reads the packet as an old one, so libsrtp alone turns it away.
            #expect(throws: SRTPError.self, "jump \(jump)") { _ = try receiver.unprotect(packet(index: after).protected) }
            var jumped = packet(index: after).protected
            try receiver.unprotectAfterJump(&jumped)
            #expect(jumped == packet(index: after).clear)
            // From there the ordinary guess follows the stream again.
            for index in (after + 1)..<(after + 5) {
                #expect(try receiver.unprotect(packet(index: index).protected) == packet(index: index).clear)
            }
        }
        // Further ahead than the counters tried is beyond help, and leaves the stream as it was.
        let receiver = try SRTPSession(direction: .inbound, masterKey: testKey)
        for index in stride(from: UInt64(0), through: 0x1_9000, by: 0x4000) { _ = try receiver.unprotect(packet(index: index).protected) }
        _ = try receiver.unprotect(packet(index: 0x1_9000).protected)
        var far = packet(index: 0x1_9000 + 40 * 65_536).protected
        #expect(throws: SRTPError.self) { try receiver.unprotectAfterJump(&far, maximumRollovers: 16) }
        #expect(try receiver.unprotect(packet(index: 0x1_9001).protected) == packet(index: 0x1_9001).clear)
    }

    @Test func isSafeToUseFromManyThreads() async throws {
        let sender = try SRTPSession(direction: .outbound, masterKey: testKey)
        let receiver = try SRTPSession(direction: .inbound, masterKey: testKey)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for ssrc in UInt32(1)...8 {
                group.addTask {
                    for sequence in UInt16(0)..<500 {
                        let packet = rtpPacket(sequence: sequence, ssrc: ssrc)
                        let recovered = try receiver.unprotect(try sender.protect(packet))
                        #expect(recovered == packet)
                    }
                }
            }
            try await group.waitForAll()
        }
    }
}
