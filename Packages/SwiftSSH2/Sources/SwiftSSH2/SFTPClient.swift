// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CLibSSH2
public import Foundation

public struct SFTPAttributes: Sendable, Hashable {
    public var size: UInt64?
    public var isDirectory: Bool
    public var isSymbolicLink: Bool
    /// POSIX permission bits, without the file type.
    public var permissions: UInt16?
    public var modified: Date?

    init(_ raw: LIBSSH2_SFTP_ATTRIBUTES) {
        size = raw.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0 ? raw.filesize : nil
        let hasPermissions = raw.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS) != 0
        let type = raw.permissions & UInt(LIBSSH2_SFTP_S_IFMT)
        isDirectory = hasPermissions && type == UInt(LIBSSH2_SFTP_S_IFDIR)
        isSymbolicLink = hasPermissions && type == UInt(LIBSSH2_SFTP_S_IFLNK)
        permissions = hasPermissions ? UInt16(raw.permissions & 0o7777) : nil
        modified = raw.flags & UInt(LIBSSH2_SFTP_ATTR_ACMODTIME) != 0 ? Date(timeIntervalSince1970: TimeInterval(raw.mtime)) : nil
    }
}

public struct SFTPEntry: Sendable, Hashable {
    public var name: String
    public var attributes: SFTPAttributes
}

/// File access over an SSH session.
public final class SFTPClient: @unchecked Sendable {
    // @unchecked: `isShutDown` is only touched on the session's queue.
    private let session: SSHSession
    private let sftp: LibraryPointer
    private var isShutDown = false

    /// Bytes moved per request. Larger than libssh2's own packet size, so it pipelines.
    static let chunkSize = 1 << 17

    init(session: SSHSession, sftp: LibraryPointer) {
        self.session = session
        self.sftp = sftp
    }

    deinit {
        guard !isShutDown else { return }
        let (session, sftp) = (session, sftp)
        session.queue.async {
            if session.pointer != nil { libssh2_sftp_shutdown(sftp.raw) }
        }
    }

    private func failure(_ session: SSHSession) -> SSHError {
        let code = session.lastError()
        if code == LIBSSH2_ERROR_SFTP_PROTOCOL {
            return .sftp(SFTPStatus(code: UInt(libssh2_sftp_last_error(sftp.raw))))
        }
        return .library(code: code, message: session.lastErrorMessage())
    }

    /// Runs a call that returns zero on success.
    private func status(_ call: @escaping @Sendable () -> Int32) async throws {
        try await session.perform(abandonable: false) { [self] session -> Step<Void> in
            guard session.pointer != nil else { return .failed(.disconnected) }
            let result = call()
            if result == LIBSSH2_ERROR_EAGAIN { return .again }
            return result == 0 ? .done(()) : .failed(failure(session))
        }
    }

    private func open(_ call: @escaping @Sendable () -> OpaquePointer?) async throws -> LibraryPointer {
        try await session.perform(abandonable: false) { [self] session -> Step<LibraryPointer> in
            guard session.pointer != nil else { return .failed(.disconnected) }
            if let handle = call() { return .done(LibraryPointer(raw: handle)) }
            return session.lastError() == LIBSSH2_ERROR_EAGAIN ? .again : .failed(failure(session))
        }
    }

    private func closeHandle(_ handle: LibraryPointer) async {
        _ = try? await session.perform(abandonable: false) { session -> Step<Void> in
            guard session.pointer != nil else { return .done(()) }
            return libssh2_sftp_close_handle(handle.raw) == LIBSSH2_ERROR_EAGAIN ? .again : .done(())
        }
    }

    // MARK: Directories and metadata

    /// The entries of a directory, without "." and "..".
    public func list(_ path: String) async throws -> [SFTPEntry] {
        let sftp = sftp
        let handle = try await open { marionette_ssh2_sftp_opendir(sftp.raw, path) }
        var entries: [SFTPEntry] = []
        do {
            while true {
                let entry = try await session.perform(abandonable: false) { [self] session -> Step<SFTPEntry?> in
                    guard session.pointer != nil else { return .failed(.disconnected) }
                    var name = [CChar](repeating: 0, count: 1024)
                    var attributes = LIBSSH2_SFTP_ATTRIBUTES()
                    let length = marionette_ssh2_sftp_readdir(handle.raw, &name, name.count - 1, &attributes)
                    if length == LIBSSH2_ERROR_EAGAIN { return .again }
                    if length == 0 { return .done(nil) }
                    if length < 0 { return .failed(failure(session)) }
                    let text = name.withUnsafeBytes { String(decoding: $0.prefix(Int(length)), as: UTF8.self) }
                    return .done(SFTPEntry(name: text, attributes: SFTPAttributes(attributes)))
                }
                guard let entry else { break }
                if entry.name != ".", entry.name != ".." { entries.append(entry) }
            }
        } catch {
            await closeHandle(handle)
            throw error
        }
        await closeHandle(handle)
        return entries
    }

    public func attributes(of path: String) async throws -> SFTPAttributes {
        let sftp = sftp
        return try await session.perform(abandonable: false) { [self] session -> Step<SFTPAttributes> in
            guard session.pointer != nil else { return .failed(.disconnected) }
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            let result = marionette_ssh2_sftp_stat(sftp.raw, path, &attributes)
            if result == LIBSSH2_ERROR_EAGAIN { return .again }
            return result == 0 ? .done(SFTPAttributes(attributes)) : .failed(failure(session))
        }
    }

    /// The absolute form of a path as the server sees it. `"."` gives the home directory.
    public func resolve(_ path: String) async throws -> String {
        let sftp = sftp
        return try await session.perform(abandonable: false) { [self] session -> Step<String> in
            guard session.pointer != nil else { return .failed(.disconnected) }
            var target = [CChar](repeating: 0, count: 4096)
            let length = marionette_ssh2_sftp_realpath(sftp.raw, path, &target, UInt32(target.count - 1))
            if length == LIBSSH2_ERROR_EAGAIN { return .again }
            if length < 0 { return .failed(failure(session)) }
            return .done(target.withUnsafeBytes { String(decoding: $0.prefix(Int(length)), as: UTF8.self) })
        }
    }

    public func makeDirectory(_ path: String, permissions: UInt16 = 0o755) async throws {
        let sftp = sftp
        try await status { marionette_ssh2_sftp_mkdir(sftp.raw, path, Int(permissions)) }
    }

    public func removeDirectory(_ path: String) async throws {
        let sftp = sftp
        try await status { marionette_ssh2_sftp_rmdir(sftp.raw, path) }
    }

    public func removeFile(_ path: String) async throws {
        let sftp = sftp
        try await status { marionette_ssh2_sftp_unlink(sftp.raw, path) }
    }

    public func rename(_ source: String, to destination: String) async throws {
        let sftp = sftp
        try await status { marionette_ssh2_sftp_rename(sftp.raw, source, destination) }
    }

    // MARK: Transfers

    /// Copies a remote file to a local one. `progress` is called with the bytes copied so far.
    /// Cancelling the task stops the transfer and removes the partial local file.
    public func download(_ remotePath: String, to localFile: URL, progress: @Sendable (UInt64) -> Void = { _ in }) async throws {
        let sftp = sftp
        let handle = try await open { marionette_ssh2_sftp_open(sftp.raw, remotePath, UInt(LIBSSH2_FXF_READ), 0) }
        var succeeded = false
        do {
            FileManager.default.createFile(atPath: localFile.path, contents: nil)
            let output = try FileHandle(forWritingTo: localFile)
            defer {
                try? output.close()
                if !succeeded { try? FileManager.default.removeItem(at: localFile) }
            }
            var total: UInt64 = 0
            progress(0)
            while true {
                try Task.checkCancellation()
                let chunk = try await session.perform(abandonable: false) { [self] session -> Step<Data?> in
                    guard session.pointer != nil else { return .failed(.disconnected) }
                    var buffer = [CChar](repeating: 0, count: Self.chunkSize)
                    let count = libssh2_sftp_read(handle.raw, &buffer, buffer.count)
                    if count == Int(LIBSSH2_ERROR_EAGAIN) { return .again }
                    if count == 0 { return .done(nil) }
                    if count < 0 { return .failed(failure(session)) }
                    return .done(buffer.withUnsafeBytes { Data($0.prefix(count)) })
                }
                guard let chunk else { break }
                try output.write(contentsOf: chunk)
                total += UInt64(chunk.count)
                progress(total)
            }
            succeeded = true
        } catch {
            await closeHandle(handle)
            throw error
        }
        await closeHandle(handle)
    }

    /// Copies a local file to a remote path, replacing what is there.
    public func upload(_ localFile: URL, to remotePath: String, permissions: UInt16 = 0o644, progress: @Sendable (UInt64) -> Void = { _ in }) async throws {
        let input = try FileHandle(forReadingFrom: localFile)
        defer { try? input.close() }
        let sftp = sftp
        let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
        let handle = try await open { marionette_ssh2_sftp_open(sftp.raw, remotePath, flags, Int(permissions)) }
        do {
            var total: UInt64 = 0
            progress(0)
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: Self.chunkSize), !chunk.isEmpty else { break }
                let offset = Offset()
                try await session.perform(abandonable: false) { [self] session -> Step<Void> in
                    guard session.pointer != nil else { return .failed(.disconnected) }
                    while offset.value < chunk.count {
                        if session.isOutboundCongested { return .again }
                        let written = chunk.withUnsafeBytes { bytes in
                            libssh2_sftp_write(handle.raw, bytes.bindMemory(to: CChar.self).baseAddress! + offset.value, bytes.count - offset.value)
                        }
                        if written == Int(LIBSSH2_ERROR_EAGAIN) { return .again }
                        if written < 0 { return .failed(failure(session)) }
                        offset.value += written
                        session.flushOutbound()
                    }
                    return .done(())
                }
                total += UInt64(chunk.count)
                progress(total)
            }
        } catch {
            await closeHandle(handle)
            throw error
        }
        await closeHandle(handle)
    }

    /// Ends the SFTP subsystem. The SSH session stays open.
    public func close() async {
        let sftp = sftp
        _ = try? await session.perform(abandonable: false) { [self] session -> Step<Void> in
            guard !isShutDown, session.pointer != nil else { return .done(()) }
            if libssh2_sftp_shutdown(sftp.raw) == LIBSSH2_ERROR_EAGAIN { return .again }
            isShutDown = true
            return .done(())
        }
    }

    private final class Offset: @unchecked Sendable {
        var value = 0
    }
}
