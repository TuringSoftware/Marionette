// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import RemoteDesktopCore
@testable import RemoteDesktopTransport
import SwiftSSH2TestSupport
import Synchronization
import Testing

/// Answers prompts from a script and records what was asked.
private final class ScriptedPrompts: PromptHandler {
    private let state: Mutex<(answers: [PromptResponse], seen: [SessionPrompt])>

    init(_ answers: [PromptResponse]) {
        state = Mutex((answers, []))
    }

    var seen: [SessionPrompt] { state.withLock { $0.seen } }

    func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
        state.withLock { state in
            state.seen.append(prompt)
            return state.answers.isEmpty ? .cancel : state.answers.removeFirst()
        }
    }
}

@Suite(.serialized) struct SSHConnectionTests {
    static let server = Result { try LocalSSHServer() }
    var server: LocalSSHServer { get throws { try Self.server.get() } }

    private func login(key: String = "ed25519") throws -> SSHLogin {
        SSHLogin(server: Endpoint(host: "127.0.0.1", port: try server.port), username: try server.username, privateKey: try server.keys[key], keyName: key)
    }

    @Test func firstConnectionAsksAboutTheHostKeyAndLaterOnesDoNot() async throws {
        let store = InMemoryHostKeyStore()
        let prompts = ScriptedPrompts([.trustHostKey(remember: true)])
        let first = try await SSHConnection.establish(try login(), prompts: prompts, hostKeys: store)
        guard case .hostKey(let challenge) = try #require(prompts.seen.first), prompts.seen.count == 1 else {
            Issue.record("expected exactly one host-key prompt, saw \(prompts.seen)")
            return
        }
        #expect(challenge.status == .unknown)
        #expect(challenge.fingerprint == (try server.hostFingerprint))
        #expect(challenge.algorithm == "ssh-ed25519")
        #expect(first.hostKey.fingerprint == challenge.fingerprint)
        await first.close()

        let silent = ScriptedPrompts([])
        let second = try await SSHConnection.establish(try login(), prompts: silent, hostKeys: store)
        #expect(silent.seen.isEmpty)
        await second.close()
    }

    @Test func trustingOnceDoesNotRemember() async throws {
        let store = InMemoryHostKeyStore()
        let connection = try await SSHConnection.establish(try login(), prompts: ScriptedPrompts([.trustHostKey(remember: false)]), hostKeys: store)
        await connection.close()
        #expect(await store.knownKey(for: Endpoint(host: "127.0.0.1", port: try server.port)) == nil)
    }

    @Test func changedHostKeyIsFlaggedAndDecliningStopsTheConnection() async throws {
        let store = InMemoryHostKeyStore()
        let endpoint = Endpoint(host: "127.0.0.1", port: try server.port)
        await store.remember(KnownHostKey(algorithm: "ssh-ed25519", keyData: Data(repeating: 7, count: 51), fingerprint: "SHA256:previous"), for: endpoint)

        let declining = ScriptedPrompts([.cancel])
        await #expect(throws: SSHConnectionError.hostKeyRejected) {
            _ = try await SSHConnection.establish(try login(), prompts: declining, hostKeys: store)
        }
        guard case .hostKey(let challenge) = try #require(declining.seen.first) else {
            Issue.record("expected a host-key prompt")
            return
        }
        #expect(challenge.status == .changed(previousFingerprint: "SHA256:previous"))
        #expect(await store.knownKey(for: endpoint)?.fingerprint == "SHA256:previous")
        #expect(SSHConnectionError.hostKeyRejected.connectionFailure(server: endpoint) == .hostKeyRejected(host: "127.0.0.1"))
    }

    @Test func passphraseIsAskedForAndRetried() async throws {
        let prompts = ScriptedPrompts([.trustHostKey(remember: false), .passphrase("wrong"), .passphrase("open sesame")])
        let connection = try await SSHConnection.establish(try login(key: "ed25519-passphrase"), prompts: prompts, hostKeys: InMemoryHostKeyStore())
        let asked = prompts.seen.compactMap { prompt -> KeyPassphraseRequest? in
            if case .keyPassphrase(let request) = prompt { request } else { nil }
        }
        #expect(asked.map(\.attempt) == [1, 2])
        #expect(asked.first?.keyName == "ed25519-passphrase")
        await connection.close()
    }

    @Test func unauthorizedKeyWithNoOtherMethodFails() async throws {
        await #expect(throws: SSHConnectionError.authenticationFailed) {
            _ = try await SSHConnection.establish(try login(key: "stranger"), prompts: ScriptedPrompts([.trustHostKey(remember: false)]), hostKeys: InMemoryHostKeyStore())
        }
    }

    @Test func unreachableServerIsReportedAsSuch() async throws {
        let nowhere = SSHLogin(server: Endpoint(host: "127.0.0.1", port: freePort()), username: "nobody")
        do {
            _ = try await SSHConnection.establish(nowhere, prompts: ScriptedPrompts([]), hostKeys: InMemoryHostKeyStore(), connectTimeout: .seconds(3))
            Issue.record("connected to a closed port")
        } catch SSHConnectionError.unreachable {
            // Expected.
        }
    }

    @Test func aServerThatNeverSpeaksSSHTimesOut() async throws {
        // A tarpit, a proxy, or the user typing 5900 as the SSH port: TCP connects, then nothing.
        let silent = try await SilentServer()
        let login = SSHLogin(server: Endpoint(host: "127.0.0.1", port: silent.port), username: "nobody")
        let start = ContinuousClock.now
        let outcome = await outcome(within: .seconds(10)) {
            try await SSHConnection.establish(login, prompts: ScriptedPrompts([]), hostKeys: InMemoryHostKeyStore(), handshakeTimeout: .seconds(1))
        }
        #expect(outcome == .failed(.unreachable(.timedOut)))
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test func cancellingAnSSHConnectThatHangsEndsItAtOnce() async throws {
        let silent = try await SilentServer()
        let login = SSHLogin(server: Endpoint(host: "127.0.0.1", port: silent.port), username: "nobody")
        let attempt = Task { try await SSHConnection.establish(login, prompts: ScriptedPrompts([]), hostKeys: InMemoryHostKeyStore()) }
        try await Task.sleep(for: .milliseconds(300))
        let start = ContinuousClock.now
        attempt.cancel()
        let ended = await outcome(within: .seconds(5)) { try await attempt.value }
        #expect(ended == .failed(.cancelled))
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func aTunnelToADestinationThatNeverAnswersTimesOutAndTheConnectionCarriesOn() async throws {
        let echo = try EchoServer()
        let connection = try await SSHConnection.establish(try login(), prompts: ScriptedPrompts([.trustHostKey(remember: false)]), hostKeys: InMemoryHostKeyStore())
        let stream = try await connection.openStream(toHost: "127.0.0.1", port: echo.port)
        // 203.0.113.0/24 routes nowhere, so the SSH server's own connect hangs.
        let start = ContinuousClock.now
        await #expect(throws: TransportError.timedOut) {
            _ = try await connection.openStream(toHost: "203.0.113.1", port: 5900, timeout: .seconds(1))
        }
        #expect(ContinuousClock.now - start < .seconds(3))
        // The session is not left half-way through anything: what was open still works. (libssh2
        // opens one channel at a time, so a new one would wait for the server's answer.)
        try await stream.write(Data("still here".utf8))
        #expect(try await stream.read(upTo: 64) == Data("still here".utf8))
        await stream.close()
        let closing = ContinuousClock.now
        await connection.close()
        #expect(ContinuousClock.now - closing < .seconds(3))
    }

    @Test func filesGetTheirOwnConnectionWhenASessionRidesOnTheTunnel() async throws {
        let echo = try EchoServer()
        let connection = try await SSHConnection.establish(try login(), prompts: ScriptedPrompts([.trustHostKey(remember: false)]), hostKeys: InMemoryHostKeyStore())
        #expect(!connection.carriesStreams)
        let stream = try await connection.openStream(toHost: "127.0.0.1", port: echo.port)
        #expect(connection.carriesStreams)
        let dedicated = try #require(try await connection.openDedicated())
        #expect(dedicated.hostKey == connection.hostKey)
        #expect(try await dedicated.run("echo own").output == Data("own\n".utf8))
        let files = SFTPFileTransfer(connection: connection)
        #expect(try await files.list(directory: NSHomeDirectory()).isEmpty == false)
        try await stream.write(Data("ping".utf8))
        #expect(try await stream.read(upTo: 16) == Data("ping".utf8))
        await stream.close()
        await connection.close()
        await #expect(throws: (any Error).self) { _ = try await dedicated.run("true") }
    }

    @Test func tunnelProviderCarriesStreamsAndRefusesDatagrams() async throws {
        let echo = try EchoServer()
        let connection = try await SSHConnection.establish(try login(), prompts: ScriptedPrompts([.trustHostKey(remember: false)]), hostKeys: InMemoryHostKeyStore())
        let provider = SSHTunnelTransportProvider(connection: connection, peer: Endpoint(host: "mac.example", port: echo.port), hostFromServer: "127.0.0.1")
        #expect(provider.isTunnelled)
        #expect(!provider.supportsDatagrams)
        await #expect(throws: TransportError.self) { _ = try await provider.openDatagramChannel(DatagramOptions(remotePort: 5901)) }

        let stream = try await provider.openStream(port: echo.port)
        let payload = Data((0..<500_000).map { UInt8(truncatingIfNeeded: $0 &* 17) })
        async let echoed: Data = {
            var collected = Data()
            while collected.count < payload.count, let chunk = try await stream.read(upTo: 65_536) { collected.append(chunk) }
            return collected
        }()
        try await stream.write(payload)
        #expect(try await echoed == payload)
        await stream.close()

        await #expect(throws: TransportError.self) { _ = try await provider.openStream(port: freePort()) }
        let again = try await provider.openStream(port: echo.port)
        await again.close()
        await connection.close()
    }

    @Test func sftpFileTransferBrowsesUploadsAndDownloads() async throws {
        let connection = try await SSHConnection.establish(try login(), prompts: ScriptedPrompts([.trustHostKey(remember: false)]), hostKeys: InMemoryHostKeyStore())
        let files = SFTPFileTransfer(connection: connection)
        #expect(files.canBrowse)
        let home = NSHomeDirectory()
        let uploads = try await files.defaultUploadDirectory()
        #expect(uploads == home + "/Downloads" || uploads == home)

        let folder = try server.directory.appending(path: "transfer-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: folder.appending(path: "remote/sub"), withIntermediateDirectories: true)
        try Data("hidden".utf8).write(to: folder.appending(path: "remote/.hidden"))
        let payload = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 29) })
        let local = folder.appending(path: "report.bin")
        try payload.write(to: local)

        var last: TransferProgress?
        for try await progress in files.upload(from: local, toDirectory: folder.appending(path: "remote").path) { last = progress }
        #expect(last == TransferProgress(bytesTransferred: 1_500_000, totalBytes: 1_500_000))

        let listing = try await files.list(directory: folder.appending(path: "remote").path)
        #expect(listing.map(\.name).sorted() == [".hidden", "report.bin", "sub"])
        let report = try #require(listing.first { $0.name == "report.bin" })
        #expect(report.size == 1_500_000)
        #expect(report.path == folder.appending(path: "remote/report.bin").path)
        #expect(listing.first { $0.name == "sub" }?.isDirectory == true)

        let copy = folder.appending(path: "copy.bin")
        last = nil
        for try await progress in files.download(report.path, to: copy) { last = progress }
        #expect(last?.fraction == 1)
        #expect(try Data(contentsOf: copy) == payload)

        await #expect(throws: (any Error).self) {
            for try await _ in files.download(folder.appending(path: "remote/missing").path, to: copy) {}
        }
        await connection.close()
    }
}

/// Accepts TCP connections and never says a word.
private final class SilentServer: Sendable {
    let listener: NWListener
    let port: UInt16
    private let held: Held

    private final class Held: Sendable {
        let connections = Mutex<[NWConnection]>([])
    }

    init() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let held = Held()
        self.listener = listener
        self.held = held
        listener.newConnectionHandler = { connection in
            held.connections.withLock { $0.append(connection) }
            connection.start(queue: .global())
        }
        port = try await withCheckedThrowingContinuation { continuation in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let result: Result<UInt16, any Error>? = switch state {
                case .ready: .success(listener.port?.rawValue ?? 0)
                case .failed(let error): .failure(error)
                default: nil
                }
                if let result, resumed.withLock({ let was = $0; $0 = true; return !was }) { continuation.resume(with: result) }
            }
            listener.start(queue: .global())
        }
    }

    deinit {
        listener.cancel()
        for connection in held.connections.withLock({ $0 }) { connection.cancel() }
    }
}

private enum Outcome: Equatable {
    case connected
    case failed(SSHConnectionError)
    case stillWaiting
}

/// What an SSH connect came to within `limit`, without waiting longer for one that hangs: the
/// attempt runs on as an orphan if it does.
private func outcome(within limit: Duration, _ body: @escaping @Sendable () async throws -> SSHConnection) async -> Outcome {
    await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
        let once = Mutex<CheckedContinuation<Outcome, Never>?>(continuation)
        @Sendable func finish(_ outcome: Outcome) {
            once.withLock { pending in
                pending?.resume(returning: outcome)
                pending = nil
            }
        }
        Task {
            do {
                let connection = try await body()
                await connection.close()
                finish(.connected)
            } catch let error as SSHConnectionError {
                finish(.failed(error))
            } catch {
                finish(.failed(.failed(String(describing: error))))
            }
        }
        Task {
            try? await Task.sleep(for: limit)
            finish(.stillWaiting)
        }
    }
}
