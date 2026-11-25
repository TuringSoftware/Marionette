// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import AppleScreenSharing
import ARDProtocol
import Foundation

/// Experiments with native file transfer over a bare connection, without any drag:
/// `--send FILE --to DIR` pushes a file, `--fetch PATH` asks for one. Prints what the Mac answers.
func runTransfer(_ arguments: Arguments) async throws {
    let (connection, _) = try await connect(arguments)
    var nextID: UInt32 = 1
    if let file = arguments.option("send") {
        let url = URL(fileURLWithPath: file)
        let data = try Data(contentsOf: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = FileTransferDate((attributes[.modificationDate] as? Date) ?? Date())
        let id = nextID
        nextID += 1
        let directory = arguments.option("to") ?? "~/Downloads"
        var messages: [FileTransferMessage.Body] = [
            .destination(path: directory),
            .summary(FileTransferSummary(singleFile: 1, totalBytes: UInt64(data.count), allocatedBytes: UInt64((data.count + 4095) / 4096 * 4096), fileCount: 1, folderCount: 0)),
            .item(FileTransferItem(
                kind: .file, name: url.lastPathComponent, depth: 0, mode: 0o100644, dataSize: UInt64(data.count),
                created: modified, contentModified: modified, attributesModified: modified, accessed: modified
            )),
        ]
        // --short N: announce the whole file but stop after N bytes, as a cancelled upload would.
        let limit = Int(arguments.option("short") ?? "") ?? data.count
        var offset = 0
        while offset < limit {
            let end = min(limit, offset + FileTransferMessage.chunkSize)
            messages.append(.data(data.subdata(in: offset..<end)))
            offset = end
        }
        messages.append(.end)
        for body in messages {
            connection.send(FileTransferMessage(transferID: id, body: body).encoded())
        }
        print("sent \(url.lastPathComponent) (\(limit) of \(data.count) bytes) to \(directory) as transfer \(id)")
        if arguments.flags.contains("again") {
            // A second, complete transfer right behind: does the first one's state get in its way?
            var complete = Array(messages.prefix(3))
            var position = 0
            while position < data.count {
                let end = min(data.count, position + FileTransferMessage.chunkSize)
                complete.append(.data(data.subdata(in: position..<end)))
                position = end
            }
            complete.append(.end)
            for body in complete { connection.send(FileTransferMessage(transferID: id + 1, body: body).encoded()) }
            print("sent it again, complete, as transfer \(id + 1)")
        }
    }
    if let path = arguments.option("fetch") {
        connection.send(FileTransferMessage(transferID: 7, body: .fetch(path: path)).encoded())
        print("asked for \(path) as transfer 7")
    }

    let deadline = ContinuousClock.now + .seconds(Double(arguments.option("wait") ?? "") ?? 8)
    var received = Data()
    while ContinuousClock.now < deadline {
        let event = try await withThrowingTaskGroup(of: ServerEvent?.self) { group in
            group.addTask { try await connection.nextEvent() }
            group.addTask {
                try await Task.sleep(until: deadline)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let event else { break }
        switch event {
        case .fileTransfer(let message):
            switch message.body {
            case .data(let bytes):
                received.append(bytes)
                print("file \(message.transferID): data \(bytes.count) bytes")
            case .unknown(let command, let bytes):
                print("file \(message.transferID): command \(command): \(bytes.map { String(format: "%02x", $0) }.joined(separator: " "))")
            default:
                print("file \(message.transferID): \(message.body)")
            }
        case .drag(let drag):
            print("drag: token \(drag.token), \(drag.compressed.count) bytes, \((try? drag.fileURLs()) ?? [])")
        case .dropDestination(let drop):
            print("drop: token \(drop.token) → \(drop.path)")
        case .status(let status) where status != .heartbeat:
            print("status \(status.rawValue)")
        default:
            break
        }
    }
    if !received.isEmpty, let output = arguments.option("output") {
        try received.write(to: URL(fileURLWithPath: output))
        print("wrote \(received.count) bytes to \(output)")
    }
    await connection.close()
}
