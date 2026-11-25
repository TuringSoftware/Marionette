// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDCrypto
import ARDProtocol
import Darwin
import Foundation

/// Stands between a viewer (Apple's Screen Sharing.app) and a Mac, and records what they say.
///
/// The viewer connects here as if this were the Mac and logs in with type 30, which this side can
/// read; the proxy then logs in to the Mac with the same name and password. Everything after the
/// logins is passed through: in clear up to the switch to the record layer, then decrypted from
/// one side, written down, and encrypted again for the other. Media travels directly between the
/// Mac and the viewer, which share this machine's address.
///
/// Output, in `--output` (a directory): `viewer-to-mac.bin` and `mac-to-viewer.bin`, the plaintext
/// of each direction end to end, and `log.txt`, which says when each chunk arrived and where it
/// starts in its file.
func runProxy(_ arguments: Arguments) throws {
    let listenPort = UInt16(arguments.option("listen") ?? "55900") ?? 55900
    let root = URL(fileURLWithPath: arguments.option("output") ?? "proxy-capture")
    let listener = try Socket.listen(port: listenPort)
    print("waiting for viewers on 127.0.0.1:\(listenPort); captures go to \(root.path)")
    // Screen Sharing.app drops its first connection while it asks about a login it cannot verify,
    // then connects again; every connection gets a folder of its own.
    var number = 0
    while true {
        let viewer = try listener.accept()
        number += 1
        let output = root.appendingPathComponent(String(format: "%02d", number))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let recorder = try ProxyRecorder(directory: output)
        recorder.note("viewer connected")
        do {
            try relay(viewer: viewer, arguments: arguments, recorder: recorder)
        } catch {
            recorder.note("connection \(number) ended: \(error)")
            viewer.close()
        }
    }
}

private func relay(viewer: Socket, arguments: Arguments, recorder: ProxyRecorder) throws {

    // The viewer's side: this proxy is the Mac.
    try viewer.write(Data("RFB 003.889\n".utf8))
    let viewerVersion = try viewer.read(exactly: 12)
    recorder.note("viewer version \(String(decoding: viewerVersion, as: UTF8.self).trimmingCharacters(in: .newlines))")
    try viewer.write(Data([1, 30]))
    let chosen = try viewer.read(exactly: 1)[0]
    guard chosen == 30 else { throw Failure("the viewer chose login type \(chosen)") }
    let server = DiffieHellmanServer()
    try viewer.write(server.challenge)
    let (username, password, viewerWrapKey) = try server.accept(try viewer.read(exactly: server.responseLength))
    recorder.note("viewer logged in as \(username)")

    // The Mac's side: this proxy is the viewer.
    let mac = try Socket.connect(host: arguments.host, port: arguments.port)
    let macVersion = try mac.read(exactly: 12)
    try mac.write(macVersion)
    let count = Int(try mac.read(exactly: 1)[0])
    let offered = [UInt8](try mac.read(exactly: count))
    recorder.note("the Mac offers login types \(offered)")
    let macWrapKey: Data
    if offered.contains(36) {
        try mac.write(SRPLogin.firstMessage(username: username))
        let challenge = try SRPLogin.Challenge.parse(from: mac)
        let response = try SRPLogin.respond(to: challenge, password: password, random: SystemRandomSource())
        try mac.write(response.message)
        switch try SRPLogin.readVerdict(from: mac) {
        case .refused:
            try viewer.write(Data([0, 0, 0, 1]))
            throw Failure("the Mac refused the password")
        case .accepted(let proof):
            try SRPLogin.verify(serverProof: proof, expected: response.expectedServerProof)
        }
        macWrapKey = response.wrapKey
    } else {
        throw Failure("the Mac does not offer SRP")
    }
    let result = try mac.read(exactly: 4)
    try viewer.write(result)
    guard result == Data([0, 0, 0, 0]) else { throw Failure("the Mac refused the login") }
    recorder.note("logged in to the Mac; passing the rest through")

    let viewerKeys = RecordKeys(key: SystemRandomSource().bytes(16), iv: SystemRandomSource().bytes(16))
    let macKeys = KeyHandOver()

    // Mac → viewer: clear until the Mac's rekey, then records.
    let macToViewer = Thread {
        do {
            // The rekey's header is the same in both sessions, so it passes through as it is; only
            // its 36-byte body, the wrapped keys, is replaced.
            let marker = Data([0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x04, 0x4f])
            var clear = try passClear(from: mac, to: viewer, through: marker, direction: .macToViewer, recorder: recorder)
            while clear.count < 36 { clear.append(try mac.read(upTo: 65536)) }
            do {
                let (_, keys) = try RecordKeys.unwrap(Data(clear.prefix(36)), wrapKey: macWrapKey)
                macKeys.set(keys)
                // The viewer gets keys of this proxy's own, wrapped under its login's key.
                var body = Data([0, 0, 0, 1])
                body.append(try AES128.encryptECB(viewerKeys.key, key: viewerWrapKey))
                body.append(try AES128.encryptECB(viewerKeys.iv, key: viewerWrapKey))
                try viewer.write(body)
                recorder.note("record layer up on both sides")
                let opener = try RecordOpener(keys: keys)
                let sealer = try RecordSealer(keys: viewerKeys)
                var ciphertext = InboundBuffer()
                ciphertext.append(Data(clear.dropFirst(36)))
                while true {
                    var plaintext = InboundBuffer()
                    try opener.open(from: &ciphertext, into: &plaintext)
                    let chunk = plaintext.drain()
                    if !chunk.isEmpty {
                        recorder.record(.macToViewer, chunk, clear: false)
                        try viewer.write(try sealer.seal(chunk))
                    }
                    ciphertext.append(try mac.read(upTo: 1 << 18))
                }
            }
        } catch {
            recorder.note("Mac → viewer ended: \(error)")
            viewer.close()
            mac.close()
        }
    }

    // Viewer → Mac: clear through SetEncryption(2), then records once the keys are known.
    let viewerToMac = Thread {
        do {
            let marker = Data([0x12, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00])
            // ClientInit, then, if the Mac asked, the session-select answer. Its last 128 bytes
            // are credentials encrypted under the login's key, so they are re-encrypted here.
            let clientInit = try viewer.read(exactly: 1)
            recorder.record(.viewerToMac, clientInit, clear: true)
            try mac.write(clientInit)
            // Answers start with a zero length byte; the prelude starts with ViewerInfo (0x21). After
            // a refusal the viewer may answer again, so answers are passed on until the prelude.
            var next = try viewer.read(exactly: 1)
            while next[0] == 0 {
                let lengthLow = try viewer.read(exactly: 1)
                let length = Int(lengthLow[0])
                var answer = try viewer.read(exactly: length)
                recorder.record(.viewerToMac, next + lengthLow + answer, clear: true)
                recorder.note("session-select answer, \(length) bytes: " + answer.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " "))
                if length >= 128 {
                    let sealed = answer.suffix(128)
                    let plain = try AES128.decryptECB(Data(sealed), key: viewerWrapKey)
                    recorder.note("credentials (ECB under the login key): " + plain.map { String(format: "%02x", $0) }.joined(separator: " "))
                    answer.replaceSubrange((answer.endIndex - 128)..<answer.endIndex, with: try AES128.encryptECB(plain, key: macWrapKey))
                }
                try mac.write(next + lengthLow + answer)
                next = try viewer.read(exactly: 1)
            }
            recorder.record(.viewerToMac, next, clear: true)
            try mac.write(next)
            let rest = try passClear(from: viewer, to: mac, through: marker, direction: .viewerToMac, recorder: recorder)
            do {
                var ciphertext = InboundBuffer()
                ciphertext.append(rest)
                let keys = macKeys.wait()
                let opener = try RecordOpener(keys: viewerKeys)
                let sealer = try RecordSealer(keys: keys)
                while true {
                    var plaintext = InboundBuffer()
                    try opener.open(from: &ciphertext, into: &plaintext)
                    let chunk = plaintext.drain()
                    if !chunk.isEmpty {
                        recorder.record(.viewerToMac, chunk, clear: false)
                        try mac.write(try sealer.seal(try rewrapEvents(chunk, candidates: [(viewerWrapKey, macWrapKey), (viewerKeys.key, keys.key)], recorder: recorder)))
                    }
                    ciphertext.append(try viewer.read(upTo: 65536))
                }
            }
        } catch {
            recorder.note("viewer → Mac ended: \(error)")
            viewer.close()
            mac.close()
        }
    }
    macToViewer.start()
    viewerToMac.start()
    while !macToViewer.isFinished || !viewerToMac.isFinished {
        Thread.sleep(forTimeInterval: 0.2)
        if recorder.isEnded { break }
    }
    print("session ended; \(recorder.summary)")
}

/// Passes clear bytes on as they come until `marker` has gone by, and returns whatever followed
/// it in the same read. Nothing is held back: a pause that leaves a marker-like tail unsent would
/// stall the other side (the Mac's session-select block ends in zeros, as the rekey header begins).
private func passClear(from source: Socket, to sink: Socket, through marker: Data, direction: ProxyRecorder.Direction, recorder: ProxyRecorder) throws -> Data {
    var window = Data()
    while true {
        let chunk = try source.read(upTo: 65536)
        let searchable = window + chunk
        if let found = searchable.range(of: marker) {
            let through = found.upperBound - window.count
            recorder.record(direction, Data(chunk.prefix(through)), clear: true)
            try sink.write(Data(chunk.prefix(through)))
            return Data(chunk.dropFirst(through))
        }
        recorder.record(direction, chunk, clear: true)
        try sink.write(chunk)
        window = Data(searchable.suffix(marker.count - 1))
    }
}

/// Apple's viewer sends input as `0x10` messages: a kind byte and one AES block encrypted under
/// the key its login produced. The two logins here produce different keys, so each block is
/// decrypted with the viewer's, written down, and encrypted again with the Mac's.
private func rewrapEvents(_ chunk: Data, candidates: [(viewer: Data, mac: Data)], recorder: ProxyRecorder) throws -> Data {
    let bytes = [UInt8](chunk)
    guard !bytes.isEmpty, bytes.count % 18 == 0,
          stride(from: 0, to: bytes.count, by: 18).allSatisfy({ bytes[$0] == 0x10 })
    else {
        if bytes.first == 0x10 { recorder.note("unparsed 0x10 chunk of \(bytes.count) bytes") }
        return chunk
    }
    var output = Data()
    for start in stride(from: 0, to: bytes.count, by: 18) {
        let block = Data(bytes[(start + 2)..<(start + 18)])
        var rewrapped: Data?
        for (index, pair) in candidates.enumerated() {
            let plain = try AES128.decryptECB(block, key: pair.viewer)
            let hex = plain.map { String(format: "%02x", $0) }.joined(separator: " ")
            let marked = plain[plain.startIndex] == 0xff || plain[plain.startIndex + 10] == 0xff
            recorder.note(String(format: "event %02x key %d%@: ", bytes[start + 1], index, marked ? " ✓" : "") + hex)
            if marked, rewrapped == nil { rewrapped = try AES128.encryptECB(plain, key: pair.mac) }
        }
        output.append(contentsOf: bytes[start..<(start + 2)])
        output.append(rewrapped ?? block)
    }
    return output
}

/// Hands the Mac's record keys from the thread that reads them to the one that needs them.
private final class KeyHandOver: @unchecked Sendable {
    private let condition = NSCondition()
    private var keys: RecordKeys?

    func set(_ value: RecordKeys) {
        condition.lock()
        keys = value
        condition.broadcast()
        condition.unlock()
    }

    func wait() -> RecordKeys {
        condition.lock()
        defer { condition.unlock() }
        while keys == nil { condition.wait() }
        return keys!
    }
}

private final class ProxyRecorder: @unchecked Sendable {
    enum Direction: String {
        case viewerToMac = "viewer→Mac"
        case macToViewer = "Mac→viewer"
    }

    private let lock = NSLock()
    private let log: FileHandle
    private let files: [Direction: FileHandle]
    private var offsets: [Direction: Int] = [.viewerToMac: 0, .macToViewer: 0]
    private let started = Date()
    private var ended = false

    init(directory: URL) throws {
        func handle(_ name: String) throws -> FileHandle {
            let url = directory.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return try FileHandle(forWritingTo: url)
        }
        log = try handle("log.txt")
        files = [.viewerToMac: try handle("viewer-to-mac.bin"), .macToViewer: try handle("mac-to-viewer.bin")]
    }

    var isEnded: Bool { lock.withLock { ended } }
    var summary: String { lock.withLock { "\(offsets[.viewerToMac]!) bytes from the viewer, \(offsets[.macToViewer]!) from the Mac" } }

    private func line(_ text: String) {
        let stamp = String(format: "%8.3f", Date().timeIntervalSince(started))
        log.write(Data("\(stamp) \(text)\n".utf8))
        print("\(stamp) \(text)")
    }

    func note(_ text: String) {
        lock.withLock {
            if text.contains("ended") { ended = true }
            line(text)
        }
    }

    func record(_ direction: Direction, _ data: Data, clear: Bool) {
        lock.withLock {
            let offset = offsets[direction]!
            files[direction]!.write(data)
            offsets[direction]! += data.count
            let head = data.prefix(24).map { String(format: "%02x", $0) }.joined(separator: " ")
            line("\(direction.rawValue) \(clear ? "clear" : "record") @\(offset) \(data.count) bytes: \(head)")
        }
    }
}

/// A blocking TCP socket: enough for a tool that talks to one peer per thread.
final class Socket: @unchecked Sendable {
    let descriptor: Int32

    init(descriptor: Int32) {
        self.descriptor = descriptor
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func listen(port: UInt16) throws -> Socket {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else { throw Failure("cannot listen on \(port): \(String(cString: strerror(errno)))") }
        return Socket(descriptor: descriptor)
    }

    func accept() throws -> Socket {
        let accepted = Darwin.accept(descriptor, nil, nil)
        guard accepted >= 0 else { throw Failure("accept failed: \(String(cString: strerror(errno)))") }
        return Socket(descriptor: accepted)
    }

    static func connect(host: String, port: UInt16) throws -> Socket {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr(host)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw Failure("cannot reach \(host):\(port): \(String(cString: strerror(errno)))") }
        return Socket(descriptor: descriptor)
    }

    func read(upTo count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        let got = Darwin.read(descriptor, &buffer, count)
        guard got > 0 else { throw Failure(got == 0 ? "closed" : "read failed: \(String(cString: strerror(errno)))") }
        return Data(buffer.prefix(got))
    }

    func read(exactly count: Int) throws -> Data {
        var collected = Data()
        while collected.count < count { collected.append(try read(upTo: count - collected.count)) }
        return collected
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let wrote = Darwin.write(descriptor, bytes.baseAddress! + sent, bytes.count - sent)
                guard wrote > 0 else { throw Failure("write failed: \(String(cString: strerror(errno)))") }
                sent += wrote
            }
        }
    }

    func close() {
        shutdown(descriptor, SHUT_RDWR)
    }
}

private extension SRPLogin.Challenge {
    static func parse(from socket: Socket) throws -> SRPLogin.Challenge {
        let head = try socket.read(exactly: 4)
        let length = head.reduce(0) { $0 << 8 | Int($1) }
        var reader = WireReader(head + (try socket.read(exactly: length)))
        return try SRPLogin.Challenge.parse(&reader)
    }
}

private extension SRPLogin {
    static func readVerdict(from socket: Socket) throws -> Verdict {
        let head = try socket.read(exactly: 4)
        let length = head.reduce(0) { $0 << 8 | Int($1) }
        guard length >= 8 else { return .refused }
        var reader = WireReader(head + (try socket.read(exactly: length)))
        return try SRPLogin.parseVerdict(&reader)
    }
}
