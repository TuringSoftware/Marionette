// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CLibSSH2
public import Foundation

/// One channel of an SSH session, as a byte stream. A tunnel opened with
/// ``SSHSession/openTunnel(toHost:port:)`` is one, and can itself carry another SSH session.
public final class SSHChannel: SSHTransport, @unchecked Sendable {
    // @unchecked: `isFreed` is only touched on the session's queue.
    let session: SSHSession
    let channel: LibraryPointer
    private var isFreed = false

    init(session: SSHSession, channel: LibraryPointer) {
        self.session = session
        self.channel = channel
    }

    deinit {
        guard !isFreed else { return }
        let (session, channel) = (session, channel)
        session.queue.async {
            // A channel dies with its session; only a live session still owns this one.
            if session.pointer != nil { libssh2_channel_free(channel.raw) }
        }
    }

    public func read(upTo maxLength: Int) async throws -> Data? {
        try await read(upTo: maxLength, stream: 0, waits: true)
    }

    /// Reads from the channel's ordinary data (stream 0) or its error stream (stream 1). With
    /// `waits` false, returns empty data when nothing has arrived yet. `nil` means the stream ended.
    func read(upTo maxLength: Int, stream: Int32, waits: Bool) async throws -> Data? {
        let channel = channel
        return try await session.perform(abandonable: true) { session -> Step<Data?> in
            guard session.pointer != nil else { return .failed(.disconnected) }
            var buffer = [CChar](repeating: 0, count: max(1, min(maxLength, 1 << 16)))
            let count = marionette_ssh2_channel_read(channel.raw, stream, &buffer, buffer.count)
            if count > 0 {
                return .done(buffer.withUnsafeBytes { Data($0.prefix(count)) })
            }
            if count == 0 || count == Int(LIBSSH2_ERROR_EAGAIN) {
                if libssh2_channel_eof(channel.raw) != 0 { return .done(nil) }
                return waits ? .again : .done(Data())
            }
            if count == Int(LIBSSH2_ERROR_CHANNEL_CLOSED) { return .done(nil) }
            return .failed(.library(code: Int32(count), message: session.lastErrorMessage()))
        }
    }

    /// The receive window the channel was opened with: the most the server may send ahead of what
    /// is read, which is how much stale picture a tunnel can hold.
    func initialReceiveWindow() async throws -> UInt32 {
        let channel = channel
        return try await session.perform(abandonable: true) { session -> Step<UInt32> in
            guard session.pointer != nil else { return .failed(.disconnected) }
            var initial: UInt = 0
            libssh2_channel_window_read_ex(channel.raw, nil, &initial)
            return .done(UInt32(clamping: initial))
        }
    }

    /// Returns once the server has sent something since `count` was read from the session's
    /// arrival counter; at once if it already has.
    func waitForArrival(after count: UInt64) async throws {
        try await session.perform(abandonable: true) { session -> Step<Void> in
            session.arrivals != count ? .done(()) : .again
        }
    }

    public func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let channel = channel
        let progress = Progress()
        try await session.perform(abandonable: true) { session -> Step<Void> in
            guard session.pointer != nil else { return .failed(.disconnected) }
            while progress.offset < data.count {
                // Do not outrun the link: wait for what is queued to drain.
                if session.isOutboundCongested { return .again }
                let written = data.withUnsafeBytes { bytes in
                    marionette_ssh2_channel_write(
                        channel.raw,
                        bytes.bindMemory(to: CChar.self).baseAddress! + progress.offset,
                        bytes.count - progress.offset
                    )
                }
                if written > 0 {
                    progress.offset += written
                    session.flushOutbound()
                } else if written == Int(LIBSSH2_ERROR_EAGAIN) || written == 0 {
                    // The peer's receive window is full; it reopens with a message from the peer.
                    return .again
                } else {
                    return .failed(.library(code: Int32(written), message: session.lastErrorMessage()))
                }
            }
            return .done(())
        }
    }

    /// Tells the peer no more data will be sent, while still reading what it sends.
    public func finishWriting() async throws {
        let channel = channel
        try await session.perform(abandonable: false) { session -> Step<Void> in
            guard session.pointer != nil else { return .done(()) }
            return libssh2_channel_send_eof(channel.raw) == LIBSSH2_ERROR_EAGAIN ? .again : .done(())
        }
    }

    /// Closes the channel. A peer that has gone quiet never confirms the close, so after a short
    /// grace this returns and the close finishes, or dies with the session, in the background.
    public func close() async {
        let channel = channel
        let closed = Flag()
        let session = session
        _ = try? await session.cancelling(after: SSHSession.closeGrace) { [self] in
            try await session.perform(.finishInBackground({ _ in })) { [self] session -> Step<Void> in
                guard !isFreed else { return .done(()) }
                guard session.pointer != nil else {
                    isFreed = true
                    return .done(())
                }
                if !closed.isSet {
                    if libssh2_channel_close(channel.raw) == LIBSSH2_ERROR_EAGAIN { return .again }
                    closed.isSet = true
                }
                if libssh2_channel_free(channel.raw) == LIBSSH2_ERROR_EAGAIN { return .again }
                isFreed = true
                return .done(())
            }
        }
    }

    /// State carried between attempts of one call; used only on the session's queue.
    private final class Progress: @unchecked Sendable {
        var offset = 0
    }

    private final class Flag: @unchecked Sendable {
        var isSet = false
    }
}
