// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
public import RemoteDesktopCore
import SwiftSSH2
import Synchronization

/// File transfer with a remote machine over SFTP, for any session whose machine has SSH on.
public final class SFTPFileTransfer: FileTransfer {
    private let connection: SSHConnection
    private let client = Mutex<SFTPClient?>(nil)

    public init(connection: SSHConnection) {
        self.connection = connection
    }

    public var canBrowse: Bool { true }

    /// One SFTP subsystem for the life of the connection, started on first use.
    ///
    /// When a remote-desktop session rides on the same SSH connection, SFTP gets a connection of its
    /// own if the login can be repeated without the user: over a shared one, an upload queues in
    /// front of the session's input (at 2 Mbit/s, a megabyte is four seconds). Falls back to the
    /// shared connection.
    private func sftp() async throws -> SFTPClient {
        if let existing = client.withLock({ $0 }) { return existing }
        var carrier = connection
        if connection.carriesStreams {
            do {
                if let dedicated = try await connection.openDedicated() { carrier = dedicated }
            } catch {
                transportLog.notice("SFTP shares the session's SSH connection: a second one failed (\(String(describing: error), privacy: .public))")
            }
        }
        let opened = try await carrier.openSFTP()
        return client.withLock { stored in
            if let stored { return stored }
            stored = opened
            return opened
        }
    }

    public func defaultUploadDirectory() async throws -> String {
        let sftp = try await sftp()
        let home = try await sftp.resolve(".")
        let downloads = home + "/Downloads"
        if (try? await sftp.attributes(of: downloads))?.isDirectory == true { return downloads }
        return home
    }

    public func list(directory: String) async throws -> [RemoteFileEntry] {
        let sftp = try await sftp()
        let base = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        return try await sftp.list(directory.isEmpty ? "." : directory)
            // Hidden files are kept: the browser decides whether to show them.
            .filter { $0.name != "." && $0.name != ".." }
            .map { entry in
                RemoteFileEntry(
                    path: base + "/" + entry.name, name: entry.name,
                    isDirectory: entry.attributes.isDirectory, size: entry.attributes.isDirectory ? nil : entry.attributes.size,
                    modified: entry.attributes.modified
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func upload(from localFile: URL, toDirectory remoteDirectory: String) -> AsyncThrowingStream<TransferProgress, any Error> {
        transfer { sftp, report in
            let size = (try? FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? NSNumber)?.uint64Value
            let directory = remoteDirectory.hasSuffix("/") ? String(remoteDirectory.dropLast()) : remoteDirectory
            try await sftp.upload(localFile, to: directory + "/" + localFile.lastPathComponent) { bytes in
                report(TransferProgress(bytesTransferred: bytes, totalBytes: size))
            }
        }
    }

    public func download(_ remotePath: String, to localFile: URL) -> AsyncThrowingStream<TransferProgress, any Error> {
        transfer { sftp, report in
            let size = try await sftp.attributes(of: remotePath).size
            try await sftp.download(remotePath, to: localFile) { bytes in
                report(TransferProgress(bytesTransferred: bytes, totalBytes: size))
            }
        }
    }

    /// Runs a transfer as a stream of progress. Dropping the stream cancels the transfer.
    private func transfer(
        _ body: @escaping @Sendable (SFTPClient, @escaping @Sendable (TransferProgress) -> Void) async throws -> Void
    ) -> AsyncThrowingStream<TransferProgress, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let sftp = try await self.sftp()
                    try await body(sftp) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
