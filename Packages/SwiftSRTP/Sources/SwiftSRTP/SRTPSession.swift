// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CLibSRTP
public import Foundation
import Synchronization

public enum SRTPError: Error, Sendable, Equatable {
    /// The master key is not 46 bytes (a 32-byte AES-256 key and a 14-byte salt).
    case invalidKeyLength(Int)
    /// The packet's authentication tag does not match: corrupted, forged, or wrong key.
    case authenticationFailed
    /// The packet was already received, or is older than the replay window.
    case replayed
    /// The packet is too short or malformed to process.
    case invalidPacket
    /// Any other failure, with libsrtp's status code.
    case library(status: UInt32)

    init(_ status: srtp_err_status_t) {
        switch status {
        case srtp_err_status_auth_fail: self = .authenticationFailed
        case srtp_err_status_replay_fail, srtp_err_status_replay_old: self = .replayed
        case srtp_err_status_bad_param, srtp_err_status_parse_err: self = .invalidPacket
        default: self = .library(status: status.rawValue)
        }
    }
}

/// One direction of SRTP and SRTCP under one master key, for any number of SSRCs.
///
/// Uses `AES_CM_256_HMAC_SHA1_80` (RFC 6188) for both RTP and RTCP. Each SSRC seen gets its own
/// replay window and rollover counter. Safe to share between threads; calls are serialised.
public final class SRTPSession: Sendable {
    public enum Direction: Sendable {
        /// Verifies and decrypts packets from the peer.
        case inbound
        /// Encrypts and signs packets for the peer.
        case outbound
    }

    public static let masterKeyLength = 46
    /// Bytes added to an RTP packet by protection.
    public static let rtpOverhead = 10
    /// Bytes added to an RTCP packet by protection: the index word and the tag.
    public static let rtcpOverhead = 14

    /// Room libsrtp may need past the packet when protecting: its largest tag and key identifier,
    /// plus the index word for RTCP. (Its header states these as macros Swift cannot import.)
    private static let maximumTrailer = 16 + 128
    private static let maximumRTCPTrailer = 4 + 16 + 128

    /// The libsrtp session. `@unchecked Sendable` because the pointer is only ever passed to libsrtp
    /// while `lock` is held, and libsrtp keeps no thread-affine state.
    private final class Handle: @unchecked Sendable {
        let pointer: OpaquePointer

        init(_ pointer: OpaquePointer) {
            self.pointer = pointer
        }

        deinit {
            srtp_dealloc(pointer)
        }
    }

    private let handle: Handle
    private let lock = Mutex(())

    /// libsrtp needs one process-wide initialisation, which also runs its cipher self-tests.
    private static let libraryStatus: srtp_err_status_t = srtp_init()

    /// - Parameters:
    ///   - masterKey: 32 bytes of key followed by 14 bytes of salt.
    ///   - replayWindow: How many packets back a late packet is still accepted (inbound only).
    ///     High-bitrate video sends thousands of packets a second, so the default is generous.
    public init(direction: Direction, masterKey: Data, replayWindow: Int = 2048) throws(SRTPError) {
        guard masterKey.count == Self.masterKeyLength else { throw .invalidKeyLength(masterKey.count) }
        guard Self.libraryStatus == srtp_err_status_ok else { throw SRTPError(Self.libraryStatus) }

        var policy = srtp_policy_t()
        srtp_crypto_policy_set_aes_cm_256_hmac_sha1_80(&policy.rtp)
        srtp_crypto_policy_set_aes_cm_256_hmac_sha1_80(&policy.rtcp)
        policy.ssrc.type = direction == .inbound ? ssrc_any_inbound : ssrc_any_outbound
        policy.window_size = UInt(min(max(replayWindow, 64), 0x7fff))
        policy.allow_repeat_tx = 0

        var created: srtp_t?
        var key = [UInt8](masterKey)
        let status = key.withUnsafeMutableBufferPointer { keyBytes -> srtp_err_status_t in
            policy.key = keyBytes.baseAddress
            return srtp_create(&created, &policy)
        }
        // libsrtp copies the key; do not leave a second copy lying in this array.
        key.withUnsafeMutableBytes { _ = $0.initializeMemory(as: UInt8.self, repeating: 0) }
        guard status == srtp_err_status_ok, let created else { throw SRTPError(status) }
        handle = Handle(created)
    }

    /// Verifies and decrypts one SRTP packet, returning the RTP packet.
    public func unprotect(_ packet: Data) throws(SRTPError) -> Data {
        var buffer = packet
        try unprotect(&buffer)
        return buffer
    }

    /// Verifies and decrypts one SRTP packet where it lies, leaving the RTP packet in its place.
    /// If it throws, the bytes are unchanged unless the packet passed authentication.
    public func unprotect(_ packet: inout Data) throws(SRTPError) {
        try transformInPlace(&packet, minimum: 12 + Self.rtpOverhead, srtp_unprotect)
    }

    /// Encrypts and signs one RTP packet, returning the SRTP packet.
    public func protect(_ packet: Data) throws(SRTPError) -> Data {
        try transform(packet, growth: Self.maximumTrailer, minimum: 12, srtp_protect)
    }

    /// Verifies and decrypts one SRTCP packet (possibly compound), returning the RTCP packet.
    public func unprotectRTCP(_ packet: Data) throws(SRTPError) -> Data {
        var buffer = packet
        try unprotectRTCP(&buffer)
        return buffer
    }

    /// Verifies and decrypts one SRTCP packet where it lies.
    public func unprotectRTCP(_ packet: inout Data) throws(SRTPError) {
        try transformInPlace(&packet, minimum: 8 + Self.rtcpOverhead, srtp_unprotect_rtcp)
    }

    /// Encrypts and signs one RTCP packet (possibly compound), returning the SRTCP packet.
    public func protectRTCP(_ packet: Data) throws(SRTPError) -> Data {
        try transform(packet, growth: Self.maximumRTCPTrailer, minimum: 8, srtp_protect_rtcp)
    }

    /// Forgets everything kept for one SSRC: its replay window and rollover counter. A stream
    /// that is over should be removed, since each SSRC that ever authenticated is otherwise kept,
    /// and searched for every packet, for the life of the session.
    public func removeStream(ssrc: UInt32) {
        let pointer = handle.pointer
        // libsrtp keys its streams by the SSRC as it is on the wire.
        lock.withLock { _ in _ = srtp_remove_stream(pointer, ssrc.bigEndian) }
    }

    /// Verifies and decrypts an SRTP packet from a sender that may have jumped ahead by more than
    /// half the sequence number space since its last packet here.
    ///
    /// The rollover counter is never sent; a receiver infers it from how far the sequence number
    /// moved (RFC 3711, 3.3.1), which cannot follow a jump of more than 2^15. libsrtp then rejects
    /// that packet and every later one as a replay or a forgery. A Mac jumps that far while a
    /// viewer's sockets are suspended in the background. When the usual guess fails, each counter
    /// from the stream's current one to `maximumRollovers` past it is tried; the 80-bit tag, which
    /// covers the counter, tells which is right. Each try costs one HMAC, so call this only after
    /// a silence. A sender further ahead, or a new SSRC, needs new keys (a new offer).
    public func unprotectAfterJump(_ packet: inout Data, maximumRollovers: Int = 16) throws(SRTPError) {
        var attempt = packet
        let firstError: SRTPError
        do {
            try unprotect(&attempt)
            packet = attempt
            return
        } catch {
            firstError = error
        }
        guard firstError == .replayed || firstError == .authenticationFailed, packet.count >= 12 + Self.rtpOverhead else { throw firstError }
        let base = packet.startIndex + 8
        let ssrc = packet[base..<(base + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let pointer = handle.pointer
        let recovered: Data? = lock.withLock { _ in
            var current: UInt32 = 0
            guard srtp_get_stream_roc(pointer, ssrc, &current) == srtp_err_status_ok else { return nil }
            // A pending counter of 0 means none; leave none behind, whatever happens.
            defer { _ = srtp_set_stream_roc(pointer, ssrc, 0) }
            for step in 0...UInt32(max(0, maximumRollovers)) {
                let (candidate, overflow) = current.addingReportingOverflow(step)
                guard !overflow else { break }
                // libsrtp cannot be told to assume a counter of 0; its own guess covered that.
                guard candidate != 0, srtp_set_stream_roc(pointer, ssrc, candidate) == srtp_err_status_ok else { continue }
                var trial = packet
                var length = Int32(trial.count)
                let status = trial.withUnsafeMutableBytes { srtp_unprotect(pointer, $0.baseAddress, &length) }
                if status == srtp_err_status_ok { return trial.prefix(Int(length)) }
            }
            return nil
        }
        guard let recovered else { throw firstError }
        packet = recovered
    }

    private func transformInPlace(
        _ packet: inout Data,
        minimum: Int,
        _ operation: (srtp_t?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>?) -> srtp_err_status_t
    ) throws(SRTPError) {
        guard packet.count >= minimum, packet.count <= 65_535 else { throw .invalidPacket }
        var length = Int32(packet.count)
        let pointer = handle.pointer
        let status = lock.withLock { _ in
            packet.withUnsafeMutableBytes { bytes in
                operation(pointer, bytes.baseAddress, &length)
            }
        }
        guard status == srtp_err_status_ok else { throw SRTPError(status) }
        packet = packet.prefix(Int(length))
    }

    private func transform(
        _ packet: Data,
        growth: Int,
        minimum: Int,
        _ operation: (srtp_t?, UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>?) -> srtp_err_status_t
    ) throws(SRTPError) -> Data {
        guard packet.count >= minimum, packet.count <= 65_535 else { throw .invalidPacket }
        var buffer = packet
        buffer.append(Data(count: growth))
        var length = Int32(packet.count)
        let pointer = handle.pointer
        let status = lock.withLock { _ in
            buffer.withUnsafeMutableBytes { bytes in
                operation(pointer, bytes.baseAddress, &length)
            }
        }
        guard status == srtp_err_status_ok else { throw SRTPError(status) }
        return buffer.prefix(Int(length))
    }
}
