// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

@testable import ARDProtocol
@testable import AppleScreenSharing
import ARDCrypto
import CoreVideo
import Foundation
import RemoteDesktopConformance
import RemoteDesktopCore
import Synchronization
import Testing

/// Answers credential prompts from a list of passwords and remembers the questions.
private final class PasswordList: PromptHandler {
    let username: String
    let passwords: Mutex<[String?]>
    let asked = Mutex<[CredentialRequest]>([])

    init(username: String = "tester", _ passwords: [String?]) {
        self.username = username
        self.passwords = Mutex(passwords)
    }

    func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
        guard case .credentials(let request) = prompt else { return .cancel }
        asked.withLock { $0.append(request) }
        let next: String?? = passwords.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        guard let next, let password = next else { return .cancel }
        return .credentials(username: username, password: password)
    }
}

/// Signs in as "tester" and answers session-select prompts from a list, remembering them.
private final class SessionChoices: PromptHandler {
    let choices: Mutex<[SessionChoice?]>
    let asked = Mutex<[SessionSelectRequest]>([])

    init(_ choices: [SessionChoice?]) {
        self.choices = Mutex(choices)
    }

    func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
        switch prompt {
        case .credentials(let request):
            return request.attempt > 1 ? .cancel : .credentials(username: "tester", password: "s3cret")
        case .sessionSelect(let request):
            asked.withLock { $0.append(request) }
            let next: SessionChoice?? = choices.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            guard let next, let choice = next else { return .cancel }
            return .sessionChoice(choice)
        default:
            return .cancel
        }
    }
}

/// Blue, green and red of every pixel of a frame.
private func colours(of frame: DisplayFrame) -> [[UInt8]] {
    frame.surface.withUnsafeBuffer { buffer in
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var output: [[UInt8]] = []
        for y in 0..<frame.pixelSize.height {
            for x in 0..<frame.pixelSize.width {
                let pixel = base + y * stride + x * 4
                output.append([pixel[0], pixel[1], pixel[2]])
            }
        }
        return output
    }
}

private func expected(width: Int, height: Int, generation: (Int, Int) -> Int = { _, _ in 0 }) -> [[UInt8]] {
    var output: [[UInt8]] = []
    for y in 0..<height {
        for x in 0..<width {
            output.append(Array(ScriptedMac.pixel(x: x, y: y, generation: generation(x, y)).prefix(3)))
        }
    }
    return output
}

/// The Apple back end against a Mac scripted in this process: every step of a Standard-mode
/// session, and the failures a real Mac cannot be made to produce on demand.
@Suite struct ScriptedMacTests {
    static func standardRequest(_ transport: ScriptedMacTransport) -> ConnectionRequest {
        var options = SessionOptions(mode: .require(.standard))
        options.quality = .full
        return ConnectionRequest(options: options, transport: transport, prompts: StaticPromptHandler(username: "tester", password: "s3cret"))
    }

    private func request(
        _ transport: ScriptedMacTransport, quality: QualityPreset = .full, password: String = "s3cret",
        prompts: (any PromptHandler)? = nil, requiresEncryption: Bool = false,
        progress: @escaping @Sendable (ConnectionPhase) -> Void = { _ in }
    ) -> ConnectionRequest {
        var options = SessionOptions(mode: .require(.standard))
        options.quality = quality
        options.requiresEncryption = requiresEncryption
        return ConnectionRequest(
            options: options, transport: transport,
            prompts: prompts ?? StaticPromptHandler(username: "tester", password: password), progress: progress
        )
    }

    @Test(arguments: BackendConformance.allChecks)
    func standardModeConformsToTheSessionContract(check: BackendConformance.Check) async throws {
        let transport = ScriptedMacTransport()
        let suite = BackendConformance(backend: AppleScreenSharingBackend(), timeout: .seconds(10)) {
            var options = SessionOptions(mode: .require(.standard))
            options.quality = .full
            return ConnectionRequest(options: options, transport: transport, prompts: StaticPromptHandler(username: "tester", password: "s3cret"))
        }
        try await suite.run(check)
    }

    @Test func logsInSetsUpEncryptionAndShowsTheMacsPixelsExactly() async throws {
        let transport = ScriptedMacTransport()
        let phases = Mutex<[ConnectionPhase]>([])
        let session = try await AppleScreenSharingBackend().connect(request(transport) { phase in phases.withLock { $0.append(phase) } })
        let mac = transport.latest

        #expect(session.info.mode == .standard)
        #expect(session.info.remoteName == "Scripted Mac")
        #expect(phases.withLock { $0 } == [.reachingHost, .negotiating, .authenticating, .preparingDisplays])
        let seen = mac.record.withLock { $0 }
        #expect(seen.logins.map(\.username) == ["tester"])
        #expect(seen.logins.map(\.password) == ["s3cret"])
        #expect(seen.isEncrypted)
        // The prelude goes in clear and in this order; a Mac ignores parts of it otherwise.
        #expect(seen.prelude == [.framed(type: 0x21, length: 62), .mode(1), .autoPasteboard, .encryption(command: 1), .encryption(command: 2)])
        #expect(seen.messages.first == .setPixelFormat)
        #expect(seen.messages.contains(.updateRequest(incremental: false, x: 0, y: 0, width: 64, height: 48)))

        let display = try #require(session.layout.displays.first)
        #expect(display.id == DisplayID(77))
        #expect(display.pixelSize == PixelSize(width: 64, height: 48))
        #expect(display.scale == 2)
        let frame = try #require(await session.frames(for: display.id).next())
        #expect(colours(of: frame) == expected(width: 64, height: 48))
        await session.disconnect()
    }

    @Test func aRepaintedRectangleChangesOnlyItsPixelsAndSaysWhere() async throws {
        let transport = ScriptedMacTransport()
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let display = try #require(session.layout.displays.first)
        let frames = session.frames(for: display.id)
        _ = await frames.next()

        // Three in a row: each is a later chunk of the one compression stream.
        transport.latest.repaint(x: 8, y: 4, width: 16, height: 10, generation: 1)
        var frame = try #require(await frames.next())
        #expect(frame.damage.bounds == PixelRect(x: 8, y: 4, width: 16, height: 10))
        transport.latest.repaint(x: 40, y: 30, width: 5, height: 7, generation: 2)
        frame = try #require(await frames.next())
        #expect(frame.damage.bounds == PixelRect(x: 40, y: 30, width: 5, height: 7))
        transport.latest.repaint(x: 0, y: 0, width: 64, height: 1, generation: 3)
        frame = try #require(await frames.next())
        #expect(colours(of: frame) == expected(width: 64, height: 48) { x, y in
            if y == 0 { return 3 }
            if (8..<24).contains(x), (4..<14).contains(y) { return 1 }
            if (40..<45).contains(x), (30..<37).contains(y) { return 2 }
            return 0
        })
        await session.disconnect()
    }

    /// Every boundary in the stream falls between two reads at some point when the Mac's bytes
    /// arrive one at a time: inside the login, across the switch to records, inside a record's
    /// length, its body, and the compressed picture.
    @Test func survivesTheMacsBytesArrivingOneAtATime() async throws {
        let transport = ScriptedMacTransport(chunkLimit: 1)
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let display = try #require(session.layout.displays.first)
        let frames = session.frames(for: display.id)
        #expect(colours(of: try #require(await frames.next())) == expected(width: 64, height: 48))
        transport.latest.repaint(x: 3, y: 3, width: 20, height: 20, generation: 5)
        let frame = try #require(await frames.next())
        #expect(colours(of: frame) == expected(width: 64, height: 48) { x, y in (3..<23).contains(x) && (3..<23).contains(y) ? 5 : 0 })
        await session.disconnect()
    }

    @Test(arguments: [2, 3, 7, 61, 4096])
    func survivesAnyReadSize(chunk: Int) async throws {
        let transport = ScriptedMacTransport(chunkLimit: chunk)
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let display = try #require(session.layout.displays.first)
        #expect(colours(of: try #require(await session.frames(for: display.id).next())) == expected(width: 64, height: 48))
        await session.disconnect()
    }

    @Test func adaptiveQualityIsAskedForAndDecoded() async throws {
        let transport = ScriptedMacTransport()
        let session = try await AppleScreenSharingBackend().connect(request(transport, quality: .adaptive))
        let mac = transport.latest
        // The tiles come first in the list, so a Mac codes the picture with them.
        let lists: [[Int32]] = mac.record.withLock { $0.messages.compactMap { if case .encodings(let list) = $0 { list } else { nil } } }
        let pictureCodecs = try #require(lists.first).filter { [Encoding.zlib.rawValue, Encoding.appleAdaptive.rawValue, Encoding.zrle.rawValue].contains($0) }
        #expect(pictureCodecs == [Encoding.appleAdaptive.rawValue, Encoding.zlib.rawValue])

        let display = try #require(session.layout.displays.first)
        let frames = session.frames(for: display.id)
        let white = try #require(await frames.next())
        #expect(colours(of: white).allSatisfy { $0 == [255, 255, 255] })

        // Switching to Full asks for zlib first and for the whole screen again, which then is exact.
        let quality = try #require(session.capabilities.quality.value)
        try await quality.setPreset(.full)
        var exact: DisplayFrame?
        for _ in 0..<5 {
            guard let next = await frames.next() else { break }
            exact = next
            if colours(of: next) == expected(width: 64, height: 48) { break }
        }
        #expect(colours(of: try #require(exact)) == expected(width: 64, height: 48))
        let after: [[Int32]] = mac.record.withLock { $0.messages.compactMap { if case .encodings(let list) = $0 { list } else { nil } } }
        #expect(after.count == 2)
        #expect(after.last?.contains(Encoding.appleAdaptive.rawValue) == false)
        await session.disconnect()
    }

    @Test func aWrongPasswordIsAskedForAgainOnANewConnection() async throws {
        let transport = ScriptedMacTransport()
        let prompts = PasswordList(["wrong", "s3cret"])
        let session = try await AppleScreenSharingBackend().connect(request(transport, prompts: prompts))
        let asked = prompts.asked.withLock { $0 }
        #expect(asked.map(\.attempt) == [1, 2])
        #expect(asked.first?.previousFailure == nil)
        #expect(asked.last?.previousFailure != nil)
        #expect(asked.first?.context == .remoteDesktop(host: "scripted-mac.test"))
        // A refused login ends the connection, so the second try is a second one.
        #expect(transport.macs.withLock { $0.count } == 2)
        #expect(transport.macs.withLock { $0.first!.record.withLock { $0.logins.map(\.password) } } == ["wrong"])
        await session.disconnect()
    }

    @Test func threeWrongPasswordsEndAsAnAuthenticationFailure() async {
        let prompts = PasswordList(["a", "b", "c", "d"])
        await #expect(throws: ConnectionFailure.self) {
            _ = try await AppleScreenSharingBackend().connect(request(ScriptedMacTransport(), prompts: prompts))
        }
        do {
            _ = try await AppleScreenSharingBackend().connect(request(ScriptedMacTransport(), prompts: PasswordList(["a", "b", "c", "d"])))
        } catch {
            guard case .authenticationFailed = error else {
                Issue.record("failed as \(error)")
                return
            }
        }
        #expect(prompts.asked.withLock { $0.count } == 3)
    }

    @Test func decliningThePasswordCancels() async {
        await #expect(throws: ConnectionFailure.cancelled) {
            _ = try await AppleScreenSharingBackend().connect(request(ScriptedMacTransport(), prompts: PasswordList([nil])))
        }
    }

    @Test func aPasswordTooLongForTheExchangeIsRefusedWithoutBeingSent() async throws {
        let transport = ScriptedMacTransport()
        let prompts = PasswordList([String(repeating: "x", count: 64), "s3cret"])
        let session = try await AppleScreenSharingBackend().connect(request(transport, prompts: prompts))
        #expect(prompts.asked.withLock { $0.last?.previousFailure?.contains("64") } == true)
        #expect(transport.macs.withLock { $0.flatMap { $0.record.withLock { $0.logins.map(\.password) } } } == ["s3cret"])
        await session.disconnect()
    }

    // MARK: SRP

    private static let offersSRP: ScriptedMac.Options = {
        var options = ScriptedMac.Options()
        options.securityTypes = [30, 33, 36, 35]
        return options
    }()

    /// Where a Mac offers SRP it is used, and the whole session runs on the key it agrees: the
    /// rekey is wrapped under SHA-256 of SRP's session key.
    @Test func srpIsChosenWhereOfferedAndCarriesTheSession() async throws {
        let transport = ScriptedMacTransport(options: Self.offersSRP)
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let mac = transport.latest
        #expect(mac.record.withLock { $0.srpLogins.map(\.proofAccepted) } == [true])
        #expect(mac.record.withLock { $0.srpLogins.map(\.username) } == ["tester"])
        #expect(mac.record.withLock { $0.logins.isEmpty }, "the weaker login was used as well")
        #expect(session.info.securityDescription.contains("SRP"))
        #expect(session.info.isServerAuthenticated && session.info.isEncrypted)
        let display = try #require(session.layout.displays.first)
        #expect(colours(of: try #require(await session.frames(for: display.id).next())) == expected(width: 64, height: 48))
        await session.disconnect()
    }

    /// screensharingd reads SRP's first message according to what came with the type byte, and on
    /// macOS 15.6 never recovers from misreading it: the viewer sends both in one write.
    @Test func theSRPLoginTypeAndFirstMessageAreReadTogether() async throws {
        var options = Self.offersSRP
        options.loopsOnAMisreadFirstMessage = true
        let transport = ScriptedMacTransport(options: options)
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let mac = transport.latest
        #expect(!mac.record.withLock { $0.misreadFirstMessage })
        #expect(mac.record.withLock { $0.srpLogins.map(\.proofAccepted) } == [true])
        await session.disconnect()
    }

    /// A writer held up for a while, as on a busy device, still sends the type and message 1 so
    /// that the Mac reads them right.
    @Test func aHeldUpWriterStillSendsAFirstMessageTheMacReadsRight() async throws {
        /// Stalls once, at the first write after the version, for longer than a viewer might pause
        /// after the login type, then catches up.
        final class HeldUp: ByteStream {
            let base: any ByteStream
            private let writes = Mutex(0)
            init(base: any ByteStream) { self.base = base }
            func read(upTo maxLength: Int) async throws -> Data? { try await base.read(upTo: maxLength) }
            func write(_ data: Data) async throws {
                if writes.withLock({ $0 += 1; return $0 }) == 2 { try await Task.sleep(for: .milliseconds(400)) }
                try await base.write(data)
            }
            func close() async { await base.close() }
        }
        var options = Self.offersSRP
        options.loopsOnAMisreadFirstMessage = true
        let transport = ScriptedMacTransport(options: options)
        let connection = ARDConnection(stream: HeldUp(base: try await transport.openStream(port: 5900)))
        _ = try await connection.logIn(username: "tester", password: "s3cret")
        #expect(!transport.latest.record.withLock { $0.misreadFirstMessage })
        #expect(transport.latest.record.withLock { $0.srpLogins.map(\.proofAccepted) } == [true])
        await connection.close()
    }

    /// The Mac modelled above misreads what a Mac misreads, so the test before this one means
    /// something: the type byte alone followed by message 1 is read either way they arrive.
    @Test(arguments: [true, false])
    func theTypeAloneThenMessageOneIsMisreadOnlyWhenTheyArriveTogether(together: Bool) async throws {
        var options = Self.offersSRP
        options.loopsOnAMisreadFirstMessage = true
        let transport = ScriptedMacTransport(options: options)
        let stream = try await transport.openStream(port: 5900)
        var version = Data()
        while version.count < 12, let chunk = try await stream.read(upTo: 12 - version.count) { version.append(chunk) }
        try await stream.write(version)
        var offered = Data()
        while offered.count < 1 + Int(offered.first ?? 0) {
            guard let chunk = try await stream.read(upTo: 64) else { break }
            offered.append(chunk)
        }
        let message = try SRPLogin.firstMessage(username: "tester")
        if together {
            try await stream.write(Data([36]) + message)
        } else {
            try await stream.write(Data([36]))
            try await Task.sleep(for: .milliseconds(100))
            try await stream.write(message)
        }
        // The Mac answers message 1 with its challenge, or closes the connection.
        let answer = try await stream.read(upTo: 4)
        #expect((answer == nil) == together)
        #expect(transport.latest.record.withLock { $0.misreadFirstMessage } == together)
        await stream.close()
    }

    @Test func aWrongPasswordOverSRPIsAskedForAgain() async throws {
        let transport = ScriptedMacTransport(options: Self.offersSRP)
        let prompts = PasswordList(["wrong", "s3cret"])
        let session = try await AppleScreenSharingBackend().connect(request(transport, prompts: prompts))
        #expect(prompts.asked.withLock { $0.map(\.attempt) } == [1, 2])
        let results = transport.macs.withLock { $0.flatMap { $0.record.withLock { $0.srpLogins.map(\.proofAccepted) } } }
        #expect(results == [false, true])
        await session.disconnect()
    }

    /// Something that accepts the proof but cannot prove itself does not hold the account's
    /// verifier: the login stops there, and the password is not tried on the weaker login.
    @Test func aMacThatCannotProveItselfIsRefusedWithoutFallingBack() async {
        var options = Self.offersSRP
        options.forgesSRPProof = true
        let transport = ScriptedMacTransport(options: options)
        do {
            _ = try await AppleScreenSharingBackend().connect(request(transport))
            Issue.record("connected to something that could not prove it is the Mac")
        } catch {
            #expect(error == .serverNotAuthenticated(detail: ARDError.serverNotAuthenticatedExplanation))
        }
        #expect(transport.macs.withLock { $0.count } == 1)
        #expect(transport.macs.withLock { $0.allSatisfy { $0.record.withLock { $0.logins.isEmpty } } })
    }

    /// A Mac known to offer SRP that offers only type 30 now: something stripped the offer. When
    /// asked to, the login stops before the password goes anywhere.
    @Test func aLoginThatCannotProveTheMacIsRefusedWhenProofIsRequired() async {
        let transport = ScriptedMacTransport()
        var request = request(transport)
        request.options.requiresServerAuthentication = true
        do {
            _ = try await AppleScreenSharingBackend().connect(request)
            Issue.record("logged in without the Mac proving itself")
        } catch {
            guard case .unsupportedServer = error else {
                Issue.record("failed as \(error)")
                return
            }
        }
        #expect(transport.macs.withLock { $0.allSatisfy { $0.record.withLock { $0.logins.isEmpty } } })
    }

    /// A Mac that offers only the classic VNC password is reached with it, as a last resort: the
    /// session runs in clear, says so, and offers no High Performance, whose keys would travel in clear.
    @Test func aVNCPasswordAloneGivesASessionInClear() async throws {
        var options = ScriptedMac.Options()
        options.securityTypes = [2]
        let transport = ScriptedMacTransport(options: options)
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let mac = transport.latest
        #expect(mac.record.withLock { $0.vncPasswordLogins } == [true])
        #expect(!mac.record.withLock { $0.isEncrypted })
        #expect(!session.info.isEncrypted)
        #expect(session.info.securityDescription.contains("not encrypted"))
        #expect(!mac.record.withLock { $0.messages.contains { if case .encryption = $0 { true } else { false } } })
        let display = try #require(session.layout.displays.first)
        #expect(colours(of: try #require(await session.frames(for: display.id).next())) == expected(width: 64, height: 48))
        await session.disconnect()

        await #expect(throws: ConnectionFailure.modeUnavailable(mode: .highPerformance, reason: .notPermitted)) {
            _ = try await AppleScreenSharingBackend().connect(ConnectionRequest(
                options: SessionOptions(mode: .require(.highPerformance)), transport: ScriptedMacTransport(options: options, supportsDatagrams: true),
                prompts: StaticPromptHandler(username: "tester", password: "s3cret")
            ))
        }
    }

    /// The VNC password is never chosen over an account login, nor after a failed one.
    @Test func aVNCPasswordIsOnlyALastResort() async throws {
        var options = ScriptedMac.Options()
        options.securityTypes = [30, 2]
        let transport = ScriptedMacTransport(options: options)
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        #expect(transport.latest.record.withLock { $0.vncPasswordLogins.isEmpty && $0.isEncrypted })
        await session.disconnect()

        options.securityTypes = [30, 36, 2]
        options.forgesSRPProof = true
        let impostor = ScriptedMacTransport(options: options)
        await #expect(throws: ConnectionFailure.serverNotAuthenticated(detail: ARDError.serverNotAuthenticatedExplanation)) {
            _ = try await AppleScreenSharingBackend().connect(request(impostor))
        }
        #expect(impostor.macs.withLock { $0.allSatisfy { $0.record.withLock { $0.vncPasswordLogins.isEmpty && $0.logins.isEmpty } } })
    }

    // MARK: Servers of Apple's protocol that are not Macs

    private static let wayshare: ScriptedMac.Options = {
        var options = ScriptedMac.Options()
        options.securityTypes = [36]
        options.isWayshare = true
        return options
    }()

    @Test func aMacIsToldFromOtherServersByItsLogins() {
        #expect(ARDConnection.isMac(offering: [.diffieHellman, .rsa, .srp, .kerberos]))
        #expect(ARDConnection.isMac(offering: [.diffieHellman, .rsa, .srp, .vncPassword, .kerberos]))
        #expect(!ARDConnection.isMac(offering: [.srp]))
    }

    /// wayshare (Linux) frames SRP and its initialisation its own way and uses the 2048-bit group;
    /// started with `--stream-encryption` it runs the session in records as a Mac does, and proves
    /// itself as a Mac does. Its keyboard is X11's, so Option goes as Alt.
    @Test func wayshareIsLoggedInToWithSRPAndRunsInRecords() async throws {
        let transport = ScriptedMacTransport(options: Self.wayshare)
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let server = transport.latest
        #expect(server.record.withLock { $0.srpLogins.map(\.proofAccepted) } == [true])
        #expect(session.info.isServerAuthenticated && session.info.isEncrypted)
        let display = try #require(session.layout.displays.first)
        #expect(colours(of: try #require(await session.frames(for: display.id).next())) == expected(width: 64, height: 48))

        session.input.send(.key(KeyEvent(key: .leftOption, phase: .down)))
        session.input.send(.key(KeyEvent(key: .leftOption, phase: .up)))
        func keys() -> [ScriptedMac.Received] {
            server.record.withLock { $0.messages.filter { if case .key = $0 { true } else { false } } }
        }
        await until("the key", timeout: .seconds(5)) { keys().count >= 2 }
        // Meta, a Mac's Option, is Command to wayshare.
        #expect(keys() == [.key(keysym: 0xffe9, isDown: true), .key(keysym: 0xffe9, isDown: false)])
        await session.disconnect()
    }

    /// Without `--stream-encryption` wayshare leaves the session, typing included, in clear. That is
    /// the server's choice: the session goes ahead, says it is not encrypted, and offers no High
    /// Performance, whose keys would travel in clear.
    @Test func aServerThatWillNotEncryptTheSessionGivesASessionInClear() async throws {
        var options = Self.wayshare
        options.wayshareEncrypts = false
        let transport = ScriptedMacTransport(options: options)
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let mac = transport.latest
        #expect(mac.record.withLock { $0.srpLogins.map(\.proofAccepted) } == [true])
        #expect(!mac.record.withLock { $0.isEncrypted })
        #expect(!session.info.isEncrypted)
        #expect(session.info.isServerAuthenticated, "SRP still proved the server")
        #expect(session.info.securityDescription.contains("not encrypted"))
        let display = try #require(session.layout.displays.first)
        #expect(colours(of: try #require(await session.frames(for: display.id).next())) == expected(width: 64, height: 48))
        await session.disconnect()
    }

    // MARK: Encryption cannot be talked away

    /// A Mac always offers to encrypt the session after a login with a key. The list of messages
    /// that says so comes after the login, outside its proof, so one without it was changed on the
    /// way: nothing more is sent.
    @Test func aMacThatSaysItWillNotEncryptIsRefused() async {
        var options = ScriptedMac.Options()
        options.stripsSetEncryption = true
        let transport = ScriptedMacTransport(options: options)
        await #expect(throws: ConnectionFailure.notEncrypted(detail: "the Mac says it will not encrypt the session, which a Mac always does")) {
            _ = try await AppleScreenSharingBackend().connect(request(transport))
        }
        #expect(transport.macs.withLock { $0.allSatisfy { $0.record.withLock { $0.prelude.isEmpty && $0.messages.isEmpty } } })
    }

    /// A computer whose sessions were encrypted before: a Mac now offering only the classic VNC
    /// password, which agrees no key, gets no login at all.
    @Test func whereEncryptionIsRequiredAVNCPasswordIsNotUsed() async {
        var options = ScriptedMac.Options()
        options.securityTypes = [2]
        let transport = ScriptedMacTransport(options: options)
        let error = await #expect(throws: ConnectionFailure.self) {
            _ = try await AppleScreenSharingBackend().connect(request(transport, requiresEncryption: true))
        }
        guard case .notEncrypted = error else {
            Issue.record("expected notEncrypted, got \(String(describing: error))")
            return
        }
        #expect(transport.macs.withLock { $0.allSatisfy { $0.record.withLock { $0.vncPasswordLogins.isEmpty } } })
    }

    /// The same for a server that will not encrypt the session: refused after the login, before the
    /// prelude or anything typed.
    @Test func whereEncryptionIsRequiredAServerInClearIsRefused() async {
        var options = Self.wayshare
        options.wayshareEncrypts = false
        let transport = ScriptedMacTransport(options: options)
        await #expect(throws: ConnectionFailure.notEncrypted(detail: "the server will not encrypt the session")) {
            _ = try await AppleScreenSharingBackend().connect(request(transport, requiresEncryption: true))
        }
        #expect(transport.macs.withLock { $0.allSatisfy { $0.record.withLock { $0.prelude.isEmpty && $0.messages.isEmpty } } })
    }

    /// A server that is not a Mac says so in its first words: it is left to another back end
    /// before anything is sent to it or asked of the user.
    @Test func aServerThatIsNotAMacIsAnotherProtocolAndNothingIsAsked() async {
        final class Refusing: PromptHandler {
            let asked = Mutex(0)
            func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
                asked.withLock { $0 += 1 }
                return .cancel
            }
        }
        var options = ScriptedMac.Options()
        options.version = "RFB 003.008\n"
        let prompts = Refusing()
        do {
            _ = try await AppleScreenSharingBackend().connect(request(ScriptedMacTransport(options: options), prompts: prompts))
            Issue.record("connected to a plain VNC server as if it were a Mac")
        } catch {
            guard case .otherProtocol = error else {
                Issue.record("failed as \(error)")
                return
            }
        }
        #expect(prompts.asked.withLock { $0 } == 0)
    }

    @Test func aMacWithNoLoginThisClientKnowsIsUnsupported() async {
        var options = ScriptedMac.Options()
        options.securityTypes = [35]
        do {
            _ = try await AppleScreenSharingBackend().connect(request(ScriptedMacTransport(options: options)))
            Issue.record("connected without a usable login")
        } catch {
            guard case .unsupportedServer = error else {
                Issue.record("failed as \(error)")
                return
            }
        }
    }

    @Test func aRefusalBeforeTheLoginCarriesTheMacsReason() async {
        var options = ScriptedMac.Options()
        options.refusal = "Too many viewers."
        await #expect(throws: ConnectionFailure.permissionDenied(detail: "Too many viewers.")) {
            _ = try await AppleScreenSharingBackend().connect(request(ScriptedMacTransport(options: options)))
        }
    }

    @Test func aMacThatAnswersInThePlainFormIsUnsupported() async {
        var options = ScriptedMac.Options()
        options.answersInPlainForm = true
        do {
            _ = try await AppleScreenSharingBackend().connect(request(ScriptedMacTransport(options: options)))
            Issue.record("connected without Apple's extended initialisation")
        } catch {
            guard case .unsupportedServer = error else {
                Issue.record("failed as \(error)")
                return
            }
        }
    }

    @Test func aMacThatGoesQuietDuringTheLoginTimesOut() async {
        struct Silent: TransportProvider {
            let peer = Endpoint(host: "silent.test", port: 5900)
            let isTunnelled = false
            let supportsDatagrams = false
            func openStream(port: UInt16) async throws -> any ByteStream { PipeStream.pair().client }
            func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel { throw TransportError.unsupported(detail: "") }
        }
        var backend = AppleScreenSharingBackend()
        backend.handshakeTimeout = .milliseconds(300)
        let started = ContinuousClock.now
        await #expect(throws: ConnectionFailure.timedOut(phase: .negotiating)) {
            _ = try await backend.connect(ConnectionRequest(
                options: SessionOptions(mode: .require(.standard)), transport: Silent(), prompts: StaticPromptHandler(username: "tester", password: "s3cret")
            ))
        }
        // Well short of the twenty seconds it would otherwise wait. (Not a tight bound: the other
        // tests' logins keep every core busy in an unoptimised build.)
        #expect(ContinuousClock.now - started < .seconds(12))
    }

    @Test func highPerformanceIsNotOfferedThroughATunnel() async {
        await #expect(throws: ConnectionFailure.modeUnavailable(mode: .highPerformance, reason: .tunnelled)) {
            _ = try await AppleScreenSharingBackend().connect(ConnectionRequest(
                options: SessionOptions(mode: .require(.highPerformance)), transport: ScriptedMacTransport(isTunnelled: true),
                prompts: StaticPromptHandler(username: "tester", password: "s3cret")
            ))
        }
    }

    @Test func automaticModeThroughATunnelIsStandardWithoutSound() async throws {
        var options = SessionOptions(mode: .automatic)
        options.quality = .full
        let session = try await AppleScreenSharingBackend().connect(ConnectionRequest(
            options: options, transport: ScriptedMacTransport(isTunnelled: true), prompts: StaticPromptHandler(username: "tester", password: "s3cret")
        ))
        #expect(session.info.mode == .standard)
        #expect(session.info.isTunnelled)
        #expect(session.capabilities.audio.unavailableReason == .tunnelled)
        await session.disconnect()
    }

    @Test func theMacHangingUpEndsTheSessionAndSaysSo() async throws {
        let transport = ScriptedMacTransport()
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let events = session.events()
        await transport.latest.hangUp()
        for await event in events {
            if case .stateChanged(.disconnected(let reason)) = event {
                #expect(reason != .userInitiated)
                break
            }
        }
        #expect(session.state.isDisconnected)
        #expect(!session.capabilities.clipboard.isAvailable)
        // The frame stream ends rather than waiting for ever.
        let display = try #require(session.layout.displays.first)
        _ = await session.frames(for: display.id).next()
    }

    @Test func garbageInsideTheEncryptedStreamEndsTheSessionAsAViolation() async throws {
        let transport = ScriptedMacTransport()
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let events = session.events()
        // A well-sealed record carrying a message type no Mac sends.
        transport.latest.send(Data([0xee, 1, 2, 3, 4, 5, 6, 7]))
        var reason: DisconnectReason?
        for await event in events {
            if case .stateChanged(.disconnected(let why)) = event {
                reason = why
                break
            }
        }
        guard case .protocolViolation = reason else {
            Issue.record("ended as \(String(describing: reason))")
            return
        }
    }

    /// A rectangle's header can claim any size. One far larger than the screen ends the session
    /// as the protocol violation it is, and allocates nothing on the claim's say-so.
    @Test func aRectangleClaimingAnEnormousSizeEndsTheSessionCleanly() async throws {
        let transport = ScriptedMacTransport()
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let events = session.events()
        var update = WireWriter()
        update.u8(0); update.u8(0); update.u16(1)
        update.u16(0); update.u16(0); update.u16(65535); update.u16(65535)
        update.i32(Encoding.zlib.rawValue)
        let chunk = Deflate.compressSyncFlushed(Data(repeating: 1, count: 64))
        update.u32(UInt32(chunk.count))
        update.bytes(chunk)
        transport.latest.send(update.data)
        var reason: DisconnectReason?
        for await event in events {
            if case .stateChanged(.disconnected(let why)) = event {
                reason = why
                break
            }
        }
        guard case .protocolViolation = reason else {
            Issue.record("ended as \(String(describing: reason))")
            return
        }
    }

    @Test func aBellIsPassedOn() async throws {
        let transport = ScriptedMacTransport()
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let events = session.events()
        transport.latest.sendBell()
        for await event in events {
            if case .notice(.bell) = event { break }
        }
        await session.disconnect()
    }

    /// A Mac discards what a viewer types in the first seconds after its login, so the session
    /// holds input until then and delivers it in order.
    @Test func inputIsHeldUntilTheMacWillTakeItThenArrivesInOrder() async throws {
        let transport = ScriptedMacTransport()
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let mac = transport.latest
        let display = try #require(session.layout.displays.first)
        let generation = session.layout.generation
        let connected = ContinuousClock.now

        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 10, y: 20), layoutGeneration: generation)))
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 10, y: 20), buttons: .primary, layoutGeneration: generation)))
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 11, y: 21), layoutGeneration: generation)))
        session.input.send(.key(KeyEvent(key: .a, characters: "a", charactersIgnoringModifiers: "a", phase: .down)))
        session.input.send(.key(KeyEvent(key: .a, characters: "a", charactersIgnoringModifiers: "a", phase: .up)))
        session.input.send(.key(KeyEvent(key: .leftCommand, phase: .down)))
        session.input.send(.key(KeyEvent(key: .leftCommand, phase: .up)))

        func input() -> [ScriptedMac.Received] {
            mac.record.withLock { $0.messages.filter { if case .key = $0 { true } else if case .pointer = $0 { true } else { false } } }
        }
        try await Task.sleep(for: .milliseconds(600))
        #expect(input().isEmpty, "input reached the Mac while it would have been discarded")
        await until("the held input", timeout: .seconds(5)) { input().count >= 7 }
        #expect(ContinuousClock.now - connected >= .seconds(1))
        #expect(input() == [
            .pointer(mask: 0, x: 10, y: 20), .pointer(mask: 1, x: 10, y: 20), .pointer(mask: 0, x: 11, y: 21),
            .key(keysym: 0x61, isDown: true), .key(keysym: 0x61, isDown: false),
            // To a Mac, Command is the Super key.
            .key(keysym: 0xffeb, isDown: true), .key(keysym: 0xffeb, isDown: false),
        ])
        await session.disconnect()
    }

    /// Trackpad gestures become Screen Sharing's own gesture messages, at the pointer.
    @Test func gesturesReachTheMacAsScreenSharingSendsThem() async throws {
        let transport = ScriptedMacTransport()
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let mac = transport.latest
        let display = try #require(session.layout.displays.first)
        let generation = session.layout.generation
        let at = PixelPoint(x: 10, y: 20)
        func gesture(_ kind: GestureEvent.Kind, _ phase: ScrollEvent.Phase = .none) {
            session.input.send(.gesture(GestureEvent(kind: kind, phase: phase, display: display.id, position: at, layoutGeneration: generation)))
        }
        gesture(.magnify(0), .began)
        gesture(.magnify(0.25), .changed)
        gesture(.magnify(0), .ended)
        gesture(.rotate(-90), .changed)
        gesture(.smartMagnify)
        gesture(.quickLook)
        gesture(.swipe(dx: 1, dy: 0))
        gesture(.swipe(dx: 0, dy: 1)) // vertical page swipes are not sent
        // From an old layout: dropped.
        session.input.send(.gesture(GestureEvent(kind: .smartMagnify, display: display.id, position: at, layoutGeneration: generation + 1)))

        func events() -> [(kind: UInt16, message: Data)] {
            mac.record.withLock { $0.messages.compactMap { if case .event(let kind, let message) = $0 { (kind, message) } else { nil } } }
        }
        await until("the gestures", timeout: .seconds(6)) { events().count >= 10 }
        try await Task.sleep(for: .milliseconds(200))
        let received = events()
        #expect(received.map(\.kind) == [3, 3, 3, 5, 4, 7, 6, 6, 6, 6])
        #expect(received[1].message == ClientMessage.gestureMagnify(0.25, phase: GesturePhase.changed.rawValue, x: 10, y: 20))
        #expect(received[0].message == ClientMessage.gestureMagnify(0, phase: GesturePhase.began.rawValue, x: 10, y: 20))
        #expect(received[2].message == ClientMessage.gestureMagnify(0, phase: GesturePhase.ended.rawValue, x: 10, y: 20))
        #expect(received[3].message == ClientMessage.gestureRotate(degrees: -90, phase: GesturePhase.changed.rawValue, x: 10, y: 20))
        #expect(received[4].message == ClientMessage.gestureSmartMagnify(x: 10, y: 20))
        #expect(received[5].message == ClientMessage.gestureLookUp(x: 10, y: 20))
        // A navigation swipe: under way (motion 2) from progress 0 to 1, then finished (motion 1).
        #expect(received[6...].map(\.message) == [
            (2 as UInt32, 0 as Float), (2, 0.5), (2, 1), (1, 1),
        ].map { ClientMessage.gesturePageSwipe(PageSwipe(motion: $0.0, swipeMask: 4, progress: $0.1), x: 10, y: 20) })
        await session.disconnect()
    }

    /// Scroll phases and momentum go to the Mac, which its apps need for swipe navigation and
    /// rubber-banding; a scroll that began without moving is sent with its first movement.
    @Test func scrollPhasesAndMomentumReachTheMac() async throws {
        let transport = ScriptedMacTransport()
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let mac = transport.latest
        let display = try #require(session.layout.displays.first)
        let generation = session.layout.generation
        func scroll(_ dy: Double, _ phase: ScrollEvent.Phase, momentum: ScrollEvent.Phase = .none, precise: Bool = true) {
            session.input.send(.scroll(ScrollEvent(
                display: display.id, position: PixelPoint(x: 10, y: 20), deltaX: 0, deltaY: dy, isPrecise: precise,
                phase: phase, momentumPhase: momentum, layoutGeneration: generation
            )))
        }
        // Fingers that touch and lift without moving scroll nothing.
        scroll(0, .began)
        scroll(0, .ended)
        scroll(0, .began)
        scroll(0, .changed)
        scroll(-30, .changed)
        scroll(-30, .changed)
        scroll(0, .ended)
        scroll(-20, .none, momentum: .began)
        scroll(-10, .none, momentum: .changed)
        scroll(0, .none, momentum: .ended)
        scroll(1, .none, precise: false)

        func fields() -> [(dy: Int32, phase: UInt32, momentum: UInt32, flags: UInt32)] {
            mac.record.withLock {
                $0.messages.compactMap { received -> (Int32, UInt32, UInt32, UInt32)? in
                    guard case .event(11, let message) = received else { return nil }
                    var reader = WireReader(message)
                    guard (try? reader.skip(8 + 6 + 12 + 4)) != nil, let dy = try? reader.i32(),
                          (try? reader.skip(4)) != nil, let phase = try? reader.u32(), let momentum = try? reader.u32(),
                          (try? reader.skip(4)) != nil, let flags = try? reader.u32()
                    else { return nil }
                    return (dy, phase, momentum, flags)
                }
            }
        }
        await until("the scrolls", timeout: .seconds(6)) { fields().count >= 7 }
        try await Task.sleep(for: .milliseconds(200))
        // Precise deltas are pixels of this 2x display, sent as points; a wheel notch is ten points.
        let received = fields()
        #expect(received.map(\.dy) == [-15, -15, 0, -10, -5, 0, 10])
        #expect(received.map(\.phase) == [1, 2, 4, 0, 0, 0, 0])
        #expect(received.map(\.momentum) == [0, 0, 0, 1, 2, 3, 0])
        #expect(received.map(\.flags) == [2, 2, 2, 2, 2, 2, 0])
        await session.disconnect()
    }

    @Test func choosingOneDisplayAsksTheMacForIt() async throws {
        let transport = ScriptedMacTransport()
        var options = SessionOptions(mode: .require(.standard))
        options.quality = .full
        options.displays = .physical(.single(DisplayID(77)))
        let session = try await AppleScreenSharingBackend().connect(ConnectionRequest(
            options: options, transport: transport, prompts: StaticPromptHandler(username: "tester", password: "s3cret")
        ))
        #expect(transport.latest.record.withLock { $0.messages.contains(.setDisplay(77)) })
        await session.disconnect()
    }

    /// Showing every display is said too, as Screen Sharing.app says it.
    @Test func showingEveryDisplayIsSaidAtTheStart() async throws {
        let transport = ScriptedMacTransport()
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        #expect(transport.latest.record.withLock { $0.messages.contains(.setDisplay(nil)) })
        await session.disconnect()
    }

    @Test func manySessionsOneAfterAnotherAllWork() async throws {
        for round in 0..<25 {
            let transport = ScriptedMacTransport(chunkLimit: round % 3 == 0 ? 5 : .max)
            let session = try await AppleScreenSharingBackend().connect(request(transport))
            let display = try #require(session.layout.displays.first)
            #expect(await session.frames(for: display.id).next() != nil, "round \(round)")
            await session.disconnect()
            #expect(session.state == .disconnected(.userInitiated))
        }
    }

    @Test func aServerWithoutLayoutsIsOneScreenOfItsFramebuffer() async throws {
        var options = ScriptedMac.Options()
        options.sendsLayout = false
        let transport = ScriptedMacTransport(options: options)
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let display = try #require(session.layout.displays.first)
        #expect(display.pixelSize == PixelSize(width: 64, height: 48))
        #expect(colours(of: try #require(await session.frames(for: display.id).next())) == expected(width: 64, height: 48))
        await session.disconnect()
    }

    /// Updates are armed as Apple's viewer arms them: the whole screen at interval 0, with a
    /// request just before; and switched off (0xffffffff) while the app is in the background.
    @Test func updatesAreArmedForTheWholeScreenAndOffWhileSuspended() async throws {
        let transport = ScriptedMacTransport()
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let mac = transport.latest
        func updates() -> [ScriptedMac.Received] {
            mac.record.withLock { $0.messages.filter { if case .autoUpdate = $0 { true } else if case .updateRequest = $0 { true } else { false } } }
        }
        #expect(updates().prefix(2) == [.updateRequest(incremental: false, x: 0, y: 0, width: 64, height: 48), .autoUpdate(interval: 0, width: 64, height: 48)])
        await session.suspend()
        await until("updates to be switched off") { updates().last == .autoUpdate(interval: .max, width: 64, height: 48) }
        await session.resume()
        await until("updates to be armed again") { updates().last == .autoUpdate(interval: 0, width: 64, height: 48) }
        #expect(updates().dropLast().last == .updateRequest(incremental: false, x: 0, y: 0, width: 64, height: 48))
        await session.disconnect()
    }

    /// A Mac sends a heartbeat every two seconds. One that goes quiet while the connection stays
    /// open (it lost power, the path went away) ends the session as lost, so it can reconnect.
    @Test func aMacThatGoesQuietEndsTheSessionAsLost() async throws {
        var options = ScriptedMac.Options()
        options.heartbeatInterval = .milliseconds(300)
        var backend = AppleScreenSharingBackend()
        backend.sessionTiming.controlSilenceLimit = .seconds(3)
        let alive = try await backend.connect(request(ScriptedMacTransport(options: options)))
        try await Task.sleep(for: .seconds(5))
        #expect(!alive.state.isDisconnected, "a Mac that keeps sending its heartbeat was given up")
        await alive.disconnect()

        options.heartbeatInterval = nil
        let quiet = try await backend.connect(request(ScriptedMacTransport(options: options)))
        let events = quiet.events()
        var reason: DisconnectReason?
        for await event in events {
            if case .stateChanged(.disconnected(let why)) = event {
                reason = why
                break
            }
        }
        guard case .connectionLost = reason else {
            Issue.record("ended as \(String(describing: reason))")
            return
        }
    }

    /// Switching to observing lets go of what the viewer holds: an observer's input, releases
    /// included, is dropped from then on.
    @Test func switchingToObserveReleasesHeldKeysFirst() async throws {
        let transport = ScriptedMacTransport()
        var backend = AppleScreenSharingBackend()
        backend.sessionTiming.inputSettlingTime = .zero
        let session = try await backend.connect(request(transport))
        let mac = transport.latest
        session.input.send(.key(KeyEvent(key: .leftCommand, phase: .down)))
        await until("the press") { mac.record.withLock { $0.messages.contains(.key(keysym: 0xffeb, isDown: true)) } }
        try await #require(session.capabilities.control.value).setControlMode(.observe)
        await until("the mode") { mac.record.withLock { $0.messages.contains(.mode(0)) } }
        let tail = mac.record.withLock { Array($0.messages.suffix(2)) }
        #expect(tail == [.key(keysym: 0xffeb, isDown: false), .mode(0)])
        await session.disconnect()
    }

    /// The Mac says when it takes no input from this viewer (status 10) and when it does again
    /// (status 9); the control capability follows.
    @Test func theMacSayingItTakesNoInputWithdrawsControl() async throws {
        let transport = ScriptedMacTransport()
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let events = session.events()
        #expect(session.capabilities.control.isAvailable)
        transport.latest.sendStatus(10)
        for await event in events {
            if case .capabilitiesChanged(let capabilities) = event {
                #expect(capabilities.control.unavailableReason == .notPermitted)
                break
            }
        }
        transport.latest.sendStatus(9)
        await until("control to come back") { session.capabilities.control.isAvailable }
        await session.disconnect()
    }

    /// Curtain mode follows the layout's flags, not the request: offered with Remote Management,
    /// up once the Mac's layout says so, and after lowering it the Mac's console is locked.
    @Test func curtainModeFollowsWhatTheMacReports() async throws {
        var options = ScriptedMac.Options()
        options.standardLayoutFlags = [.onConsole, .curtain]
        let transport = ScriptedMacTransport(options: options)
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        let mac = transport.latest
        let curtain = try #require(session.capabilities.curtain.value)
        #expect(!curtain.isCurtained)

        try await curtain.setCurtained(true, note: "Back soon — Café ☕")
        await until("the curtain") { session.capabilities.curtain.value?.isCurtained == true }
        #expect(mac.record.withLock { $0.messages.contains(.curtain(curtained: true, note: "Back soon — Café ☕")) })

        try await #require(session.capabilities.curtain.value).setCurtained(false, note: "")
        await until("the lock screen") { session.capabilities.curtain.unavailableReason == .remoteScreenLocked }
        #expect(mac.record.withLock { $0.messages.contains(.curtain(curtained: false, note: "")) })
        await session.disconnect()
    }

    /// Without Remote Management a Mac's layout never offers curtain mode, and says why.
    @Test func curtainModeNeedsRemoteManagement() async throws {
        let transport = ScriptedMacTransport()
        let session = try await AppleScreenSharingBackend().connect(request(transport))
        guard case .notConfigured = session.capabilities.curtain.unavailableReason else {
            Issue.record("curtain mode: \(String(describing: session.capabilities.curtain.unavailableReason))")
            return
        }
        await session.disconnect()
    }

    /// The Mac says where its pointer went when something other than this viewer moved it; the
    /// cursor follows, counted as a remote move. Its report of this viewer's own move is no news.
    @Test func thePointerFollowsMovesMadeAtTheMac() async throws {
        let transport = ScriptedMacTransport()
        var backend = AppleScreenSharingBackend()
        backend.sessionTiming.inputSettlingTime = .zero
        let session = try await backend.connect(request(transport))
        let mac = transport.latest
        let display = try #require(session.layout.displays.first)
        let cursor = session.cursor()
        mac.sendCursorPosition(x: 40, y: 30)
        var moved: CursorState?
        for await state in cursor where state.remoteMoves > 0 {
            moved = state
            break
        }
        #expect(moved?.position == PixelPoint(x: 40, y: 30))
        #expect(moved?.remoteMoves == 1)
        // This viewer's own move, reported back: not a remote move.
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 12, y: 13), layoutGeneration: session.layout.generation)))
        await until("the move") { mac.record.withLock { $0.messages.contains(.pointer(mask: 0, x: 12, y: 13)) } }
        mac.sendCursorPosition(x: 12, y: 13)
        mac.sendCursorPosition(x: 50, y: 5)
        var last: CursorState?
        for await state in cursor where state.remoteMoves > 1 {
            last = state
            break
        }
        #expect(last?.remoteMoves == 2)
        #expect(last?.position == PixelPoint(x: 50, y: 5))
        await session.disconnect()
    }

    /// A pasteboard fetch the Mac never answers fails after a while, and one whose caller gives up
    /// ends at once: either way the next one can go ahead.
    @Test func aPasteboardFetchNobodyAnswersEndsOrCanBeCancelled() async throws {
        let transport = ScriptedMacTransport()
        var backend = AppleScreenSharingBackend()
        backend.sessionTiming.pasteboardFetchLimit = .milliseconds(300)
        let session = try await backend.connect(request(transport))
        let clipboard = try #require(session.capabilities.clipboard.value)
        let offers = clipboard.remoteOffers()
        transport.latest.sendStatus(2)
        var iterator = offers.makeAsyncIterator()
        let offer = try #require(await iterator.next())
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) { _ = try await offer.load() }
        // Not a tight bound: the other tests' logins keep every core busy in an unoptimised build.
        #expect(ContinuousClock.now - started < .seconds(5))

        backend.sessionTiming.pasteboardFetchLimit = .seconds(60)
        let patient = try await backend.connect(request(transport))
        let patientOffers = try #require(patient.capabilities.clipboard.value).remoteOffers()
        transport.latest.sendStatus(2)
        var patientIterator = patientOffers.makeAsyncIterator()
        let patientOffer = try #require(await patientIterator.next())
        let load = Task { try await patientOffer.load() }
        try await Task.sleep(for: .milliseconds(200))
        load.cancel()
        let cancelled = ContinuousClock.now
        await #expect(throws: (any Error).self) { _ = try await load.value }
        #expect(ContinuousClock.now - cancelled < .seconds(3))
        await session.disconnect()
        await patient.disconnect()
    }

    // MARK: Session select

    @Test func someoneElseAtTheConsoleIsAskedAndTheSessionFollows() async throws {
        var macOptions = ScriptedMac.Options()
        macOptions.consoleUser = "Ada"
        let transport = ScriptedMacTransport(options: macOptions)
        let prompts = SessionChoices([.askToShareConsole])
        let phases = Mutex<[ConnectionPhase]>([])
        let session = try await AppleScreenSharingBackend().connect(request(transport, prompts: prompts) { phase in phases.withLock { $0.append(phase) } })
        let asked = prompts.asked.withLock { $0 }
        #expect(asked == [SessionSelectRequest(consoleUser: "Ada", choices: [.askToShareConsole, .logInAsSelf])])
        #expect(phases.withLock { $0 }.contains(.waitingForRemoteUser))
        let answers = transport.latest.record.withLock { $0.sessionSelectAnswers }
        #expect(answers == [SessionSelectAnswer(command: .askConsoleUser, viewerName: "Marionette")])
        #expect(transport.latest.record.withLock { $0.isEncrypted })
        await session.disconnect()
    }

    @Test func aDeclinedRequestOffersTheChoiceAgainAndLoggingInSendsTheCredentials() async throws {
        var macOptions = ScriptedMac.Options()
        macOptions.consoleUser = "Ada"
        macOptions.consoleAnswers = [false]
        let transport = ScriptedMacTransport(options: macOptions)
        let prompts = SessionChoices([.askToShareConsole, .logInAsSelf])
        var backend = AppleScreenSharingBackend()
        backend.viewerName = "Grace’s iPhone"
        let session = try await backend.connect(request(transport, prompts: prompts))
        #expect(prompts.asked.withLock { $0.map(\.previousRequestDeclined) } == [false, true])
        // One connection throughout.
        #expect(transport.macs.withLock { $0.count } == 1)
        let record = transport.latest.record.withLock { ($0.sessionSelectAnswers, $0.sessionLogins) }
        #expect(record.0.map(\.command) == [.askConsoleUser, .logInAsSelf])
        #expect(record.0.allSatisfy { $0.viewerName == "Grace’s iPhone" })
        #expect(record.1.map { [$0.username, $0.password] } == [["tester", "s3cret"]])
        await session.disconnect()
    }

    @Test func turningDownTheChoiceCancels() async {
        var macOptions = ScriptedMac.Options()
        macOptions.consoleUser = "Ada"
        await #expect(throws: ConnectionFailure.cancelled) {
            _ = try await AppleScreenSharingBackend().connect(request(ScriptedMacTransport(options: macOptions), prompts: SessionChoices([nil])))
        }
    }

    @Test func waitingForAnAnswerThatNeverComesCanBeCancelledOrRunsOut() async throws {
        var macOptions = ScriptedMac.Options()
        macOptions.consoleUser = "Ada"
        macOptions.consoleAnswers = []
        let transport = ScriptedMacTransport(options: macOptions)
        let waiting = Mutex(false)
        let attempt = Task {
            try await AppleScreenSharingBackend().connect(request(transport, prompts: SessionChoices([.askToShareConsole])) { phase in
                if phase == .waitingForRemoteUser { waiting.withLock { $0 = true } }
            })
        }
        await until("the request to be sent") { waiting.withLock { $0 } }
        // Well past the handshake's own time limit, nothing has given up.
        try await Task.sleep(for: .milliseconds(300))
        attempt.cancel()
        let started = ContinuousClock.now
        await #expect(throws: ConnectionFailure.cancelled) { _ = try await attempt.value }
        #expect(ContinuousClock.now - started < .seconds(2))

        var backend = AppleScreenSharingBackend()
        backend.consoleAnswerTimeout = .milliseconds(200)
        await #expect(throws: ConnectionFailure.timedOut(phase: .waitingForRemoteUser)) {
            _ = try await backend.connect(request(ScriptedMacTransport(options: macOptions), prompts: SessionChoices([.askToShareConsole])))
        }
    }

    @Test func aDirectConnectionToTheConsoleIsTakenWithoutAsking() async throws {
        var macOptions = ScriptedMac.Options()
        macOptions.consoleUser = "Ada"
        macOptions.sessionSelectCommands = [.connectToConsole]
        let transport = ScriptedMacTransport(options: macOptions)
        let prompts = SessionChoices([])
        let session = try await AppleScreenSharingBackend().connect(request(transport, prompts: prompts))
        #expect(prompts.asked.withLock { $0.isEmpty })
        #expect(transport.latest.record.withLock { $0.sessionSelectAnswers.map(\.command) } == [.connectToConsole])
        await session.disconnect()
    }

    @Test func aMacWithNobodyElseAtTheConsoleAsksNothing() async throws {
        let transport = ScriptedMacTransport()
        let prompts = SessionChoices([])
        let session = try await AppleScreenSharingBackend().connect(request(transport, prompts: prompts))
        #expect(prompts.asked.withLock { $0.isEmpty })
        #expect(transport.latest.record.withLock { $0.sessionSelectAnswers.isEmpty })
        await session.disconnect()
    }
}

/// High Performance negotiation against the scripted Mac: virtual displays, ports, offers and
/// answers, and the stream's pictures, in the order and with the faults a Mac can produce.
@Suite struct ScriptedHighPerformanceTests {
    static let small = VirtualDisplayRequest(pointSize: PixelSize(width: 320, height: 200), scale: 1)

    static func request(
        _ transport: ScriptedMacTransport, displays: [VirtualDisplayRequest] = [small], controlMode: ControlMode = .control
    ) -> ConnectionRequest {
        var options = SessionOptions(mode: .require(.highPerformance))
        options.displays = .virtual(displays)
        options.controlMode = controlMode
        return ConnectionRequest(options: options, transport: transport, prompts: StaticPromptHandler(username: "tester", password: "s3cret"))
    }

    /// H.264, which the scripted Mac encodes with the system's encoder.
    static var backend: AppleScreenSharingBackend {
        var backend = AppleScreenSharingBackend()
        backend.videoCodec = .h264
        backend.firstPictureTimeout = .seconds(8)
        return backend
    }

    static func transport(_ configure: (inout ScriptedMac.HighPerformanceScript) -> Void = { _ in }) -> ScriptedMacTransport {
        var options = ScriptedMac.Options()
        configure(&options.highPerformance)
        return ScriptedMacTransport(options: options, supportsDatagrams: true)
    }

    static let smallMode = VirtualDisplayMode(pixelWidth: 320, pixelHeight: 200, pointWidth: 320, pointHeight: 200)

    @Test func theOpeningDisplaysThenTheSessionSizeAreNegotiatedAndShown() async throws {
        let transport = Self.transport()
        let session = try await Self.backend.connect(Self.request(transport))
        let mac = transport.latest
        #expect(session.info.mode == .highPerformance)
        #expect(mac.configurations == [[.opening], [Self.smallMode]])
        #expect(mac.offerCount == 2)
        let display = try #require(session.layout.displays.first)
        #expect(display.pixelSize == PixelSize(width: 320, height: 200))
        #expect(display.state == .live)
        let frame = try #require(await session.frames(for: display.id).next())
        #expect(frame.pixelSize == PixelSize(width: 320, height: 200))
        // A Mac never offers curtain mode for virtual displays.
        #expect(session.capabilities.curtain.unavailableReason == .requiresMode(.standard))
        await session.disconnect()
    }

    /// What a display configuration and the offers that follow it look like in the Mac's record:
    /// "c" for each configuration, "o" for each offer.
    static func negotiation(_ mac: ScriptedMac) -> String {
        mac.record.withLock { record in
            record.messages.compactMap { message -> String? in
                switch message {
                case .displayConfiguration: "c"
                case .mediaOffer: "o"
                default: nil
                }
            }.joined()
        }
    }

    static func display(_ session: any RemoteSession) throws -> RemoteDisplay {
        try #require(session.layout.displays.first)
    }

    @Test func theComputersOwnDisplaysAreMadeAsVirtualOnesOfTheirSize() async throws {
        var options = ScriptedMac.Options()
        // A screen of 800 × 600 points at 2x.
        options.width = 1600
        options.height = 1200
        let transport = ScriptedMacTransport(options: options, supportsDatagrams: true)
        var sessionOptions = SessionOptions(mode: .require(.highPerformance))
        sessionOptions.displays = .physical(.all)
        let session = try await Self.backend.connect(ConnectionRequest(
            options: sessionOptions, transport: transport, prompts: StaticPromptHandler(username: "tester", password: "s3cret")
        ))
        let mac = transport.latest
        // The layout is asked for before any display is made.
        let encodings = mac.record.withLock { $0.messages.compactMap { if case .encodings(let list) = $0 { list } else { nil } } }
        #expect(encodings.first == Encoding.standardFull.map(\.rawValue))
        #expect(mac.configurations == [[.opening], [VirtualDisplayMode(pixelWidth: 1600, pixelHeight: 1200, pointWidth: 800, pointHeight: 600)]])
        #expect(session.layout.displays.map(\.pixelSize) == [PixelSize(width: 1600, height: 1200)])
        await session.disconnect()
    }

    /// A studio Mac's two displays (see the protocol notes): a 6K main display and a 5K one left
    /// of it, both at 2x, and a laptop's own screen.
    @Test func virtualDisplaysAreAskedForLikeTheMacsOwnScreens() {
        func screen(_ id: UInt32, points: (Int, Int, Int, Int), density: Double, main: Bool = false) -> DisplayLayout.Screen {
            DisplayLayout.Screen(
                id: id, density: density, serverScale: 1,
                pointLeft: points.0, pointTop: points.1, pointWidth: points.2, pointHeight: points.3,
                pixelLeft: 0, pixelTop: 0, pixelWidth: Int(Double(points.2) * density), pixelHeight: Int(Double(points.3) * density),
                flags: main ? .main : []
            )
        }
        func layout(_ screens: [DisplayLayout.Screen]) -> DisplayLayout {
            DisplayLayout(version: 1, desktopPointWidth: 0, desktopPointHeight: 0, framebufferWidth: 1, framebufferHeight: 1, currentScreen: nil, flags: [.onConsole], screens: screens)
        }
        let studio = layout([
            screen(2, points: (-2560, 0, 2560, 1440), density: 2),
            screen(1, points: (0, 0, 3008, 1692), density: 2, main: true),
        ])
        // The main one first; both too many pixels at 2x for a virtual display, so 1x at their size.
        #expect(ARDEngine.requests(matching: studio, limit: 2) == [
            VirtualDisplayRequest(pointSize: PixelSize(width: 3008, height: 1692), scale: 1),
            VirtualDisplayRequest(pointSize: PixelSize(width: 2560, height: 1440), scale: 1),
        ])
        #expect(ARDEngine.requests(matching: studio, limit: 1).count == 1)
        let laptop = layout([screen(1, points: (0, 0, 1512, 982), density: 2, main: true)])
        #expect(ARDEngine.requests(matching: laptop, limit: 2) == [VirtualDisplayRequest(pointSize: PixelSize(width: 1512, height: 982), scale: 2)])
        // Only another viewer's virtual display listed: nothing to go by.
        var virtual = screen(9, points: (0, 0, 1440, 900), density: 2, main: true)
        virtual.flags.insert(.dynamicVirtual)
        #expect(ARDEngine.requests(matching: layout([virtual]), limit: 2).isEmpty)
        let oldMonitor = layout([screen(1, points: (0, 0, 1920, 1080), density: 1, main: true)])
        #expect(ARDEngine.requests(matching: oldMonitor, limit: 2) == [VirtualDisplayRequest(pointSize: PixelSize(width: 1920, height: 1080), scale: 1)])
    }

    static func mode(_ request: VirtualDisplayRequest) -> VirtualDisplayMode {
        VirtualDisplayMode.fitting(pointWidth: request.pointSize.width, pointHeight: request.pointSize.height, scale: request.scale)
    }

    static func size(_ width: Int, _ height: Int) -> VirtualDisplayRequest {
        VirtualDisplayRequest(pointSize: PixelSize(width: width, height: height), scale: 1)
    }

    static func ended(_ events: AsyncStream<SessionEvent>) async -> DisconnectReason? {
        for await event in events {
            if case .stateChanged(.disconnected(let reason)) = event { return reason }
        }
        return nil
    }

    /// High Performance arms the whole screen at interval 0 too: the Mac paces cursor shapes by it.
    @Test func updatesAreArmedForTheWholeScreen() async throws {
        let transport = Self.transport()
        let session = try await Self.backend.connect(Self.request(transport))
        let arming = transport.latest.record.withLock { $0.messages.filter { if case .autoUpdate = $0 { true } else { false } } }
        #expect(arming.last == .autoUpdate(interval: 0, width: 320, height: 200))
        await session.disconnect()
    }

    @Test func everyOfferCarriesNewKeys() async throws {
        let transport = Self.transport()
        let session = try await Self.backend.connect(Self.request(transport))
        try await #require(session.capabilities.displayConfiguration.value).setVirtualDisplays([Self.size(400, 300)])
        let offered = transport.latest.record.withLock { $0.messages.compactMap { if case .mediaOffer(let keys) = $0 { keys } else { nil } } }
        #expect(offered.count == 3)
        #expect(Set(offered.flatMap { $0.map(\.serverToViewer) }).count == 3)
        await until("the new stream's picture") { (try? Self.display(session).state) == .live }
        await session.disconnect()
    }

    /// After a while in the background the stream is started afresh; after a moment, a keyframe will do.
    @Test func returningFromTheBackgroundStartsAFreshStream() async throws {
        let transport = Self.transport()
        var backend = Self.backend
        backend.sessionTiming.resumeRestartThreshold = .milliseconds(300)
        let session = try await backend.connect(Self.request(transport))
        let mac = transport.latest
        await session.suspend()
        await session.resume()
        try await Task.sleep(for: .milliseconds(200))
        #expect(Self.negotiation(mac) == "coco")
        await session.suspend()
        try await Task.sleep(for: .milliseconds(400))
        await session.resume()
        await until("a fresh stream") { Self.negotiation(mac) == "cococo" }
        await until("its picture") { (try? Self.display(session).state) == .live }
        await session.disconnect()
    }

    /// A stream that goes quiet is started again once on the same connection; only a second
    /// stall soon after ends the session.
    @Test func aStalledStreamIsStartedAgainOnceBeforeTheSessionEnds() async throws {
        let transport = Self.transport()
        var backend = Self.backend
        backend.sessionTiming.mediaSilenceLimit = .milliseconds(700)
        let session = try await backend.connect(Self.request(transport))
        let mac = transport.latest
        let events = session.events()
        mac.stopMedia()
        await until("a fresh stream", timeout: .seconds(5)) { Self.negotiation(mac) == "cococo" }
        await until("its picture") { (try? Self.display(session).state) == .live }
        #expect(!session.state.isDisconnected)
        mac.stopMedia()
        #expect(await Self.ended(events) == .mediaStalled(.silent))
    }

    /// A running stream that loses a fifth of its packets window after window goes on in the
    /// constrained profile (displays in whole multiples of 16 points), and one already constrained
    /// ends as stalled by loss, so the caller can go on in Standard mode.
    @Test func sustainedLossStepsDownThenEnds() async throws {
        let transport = Self.transport {
            $0.pictureInterval = .milliseconds(40)
            $0.packetPayload = 100
        }
        var backend = Self.backend
        backend.sessionTiming.lossWindow = .milliseconds(400)
        backend.sessionTiming.lossWindowPackets = 40
        let size = Self.size(320, 200)
        let session = try await backend.connect(Self.request(transport, displays: [size]))
        let mac = transport.latest
        try await Task.sleep(for: .seconds(1))
        #expect(mac.configurations.count == 2, "stepped down with no loss")
        mac.losePackets(every: 3)
        await until("the step down", timeout: .seconds(5)) { mac.configurations.count == 3 }
        #expect(mac.configurations.last == [VirtualDisplayMode(pixelWidth: 320, pixelHeight: 192, pointWidth: 320, pointHeight: 192)])
        #expect(!session.state.isDisconnected)
        await session.disconnect()

        var constrained = backend
        constrained.sessionTiming.bandwidthProfile = .constrained
        let transport2 = Self.transport {
            $0.pictureInterval = .milliseconds(40)
            $0.packetPayload = 100
        }
        let second = try await constrained.connect(Self.request(transport2, displays: [size]))
        let events = second.events()
        transport2.latest.losePackets(every: 3)
        #expect(await Self.ended(events) == .mediaStalled(.lossy))
    }

    @Test func portsNamedBeforeTheLayoutWorkToo() async throws {
        let transport = Self.transport { $0.portsBeforeLayout = true }
        let session = try await Self.backend.connect(Self.request(transport))
        #expect(Self.negotiation(transport.latest) == "coco")
        #expect(try Self.display(session).pixelSize == PixelSize(width: 320, height: 200))
        await session.disconnect()
    }

    /// A Mac repeats its port message while it waits. One offer per configuration all the same:
    /// a second offer while one is starting breaks the Mac's capture.
    @Test func aRepeatedPortMessageBringsNoUnaskedOffer() async throws {
        let transport = Self.transport { $0.repeatedPortMessages = 2 }
        let session = try await Self.backend.connect(Self.request(transport))
        try await Task.sleep(for: .milliseconds(300))
        #expect(Self.negotiation(transport.latest) == "coco")
        await session.disconnect()
    }

    /// Media comes from the Mac's ports to the same port numbers here: ones this side cannot bind
    /// end the attempt with a reason that offers Standard mode, rather than as a busy device.
    @Test(arguments: [[5900, 5900, 5902], [0, 5901, 5902], [5900, 80, 5902]] as [[UInt16]])
    func unusablePortsFailTheAttempt(ports: [UInt16]) async {
        let transport = Self.transport { $0.ports = ports }
        await #expect(throws: ConnectionFailure.modeUnavailable(mode: .highPerformance, reason: .notSupportedByServer)) {
            _ = try await Self.backend.connect(Self.request(transport))
        }
    }

    /// Two displays need two picture ports. A Mac that names one has no stream to offer for the
    /// second, and the attempt says so at once instead of waiting out the first-picture timer.
    @Test func aSecondDisplayWithoutAPortFailsAtOnce() async {
        let transport = Self.transport { $0.namesOneVideoPort = true }
        var backend = Self.backend
        backend.firstPictureTimeout = .seconds(30)
        let started = ContinuousClock.now
        await #expect(throws: ConnectionFailure.modeUnavailable(mode: .highPerformance, reason: .notSupportedByServer)) {
            _ = try await backend.connect(Self.request(transport, displays: [Self.small, Self.small]))
        }
        // Well short of the first-picture timer (loose: logins are slow in a busy unoptimised build).
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    @Test func twoDisplaysEachGetAStream() async throws {
        let transport = Self.transport()
        let session = try await Self.backend.connect(Self.request(transport, displays: [Self.small, Self.size(400, 300)]))
        #expect(session.layout.displays.map(\.pixelSize) == [PixelSize(width: 320, height: 200), PixelSize(width: 400, height: 300)])
        #expect(session.layout.displays.allSatisfy { $0.state == .live })
        await session.disconnect()
    }

    @Test func aResizeWhileAChangeIsOutstandingEndsAtTheNewestSize() async throws {
        let transport = Self.transport { $0.layoutDelay = .milliseconds(200) }
        let session = try await Self.backend.connect(Self.request(transport))
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        let first = Task { try await configuration.setVirtualDisplays([Self.size(400, 300)]) }
        try await Task.sleep(for: .milliseconds(50))
        try await configuration.setVirtualDisplays([Self.size(480, 320)])
        try await first.value
        #expect(transport.latest.configurations.last == [Self.mode(Self.size(480, 320))])
        #expect(try Self.display(session).pixelSize == PixelSize(width: 480, height: 320))
        await until("the display to come up") { (try? Self.display(session).state) == .live }
        await session.disconnect()
    }

    /// Resizes in a row: the one in flight finishes, the ones behind it collapse into the newest.
    @Test func resizesInARowSupersedeEachOther() async throws {
        let transport = Self.transport { $0.layoutDelay = .milliseconds(150) }
        let session = try await Self.backend.connect(Self.request(transport))
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        let sizes = [Self.size(400, 300), Self.size(420, 300), Self.size(440, 300), Self.size(460, 300)]
        var resizes: [Task<Void, any Error>] = []
        for size in sizes {
            resizes.append(Task { try await configuration.setVirtualDisplays([size]) })
            try await Task.sleep(for: .milliseconds(20))
        }
        for resize in resizes { try await resize.value }
        let asked = transport.latest.configurations.dropFirst(2)
        #expect(asked.first == [Self.mode(sizes[0])])
        #expect(asked.last == [Self.mode(sizes[3])])
        #expect(asked.count <= 2)
        #expect(try Self.display(session).pixelSize == PixelSize(width: 460, height: 300))
        await session.disconnect()
    }

    @Test func aChangeTheMacNeverAnswersTimesOutAndLaterResizesStillWork() async throws {
        let transport = Self.transport { $0.unansweredConfigurations = [2] }
        var backend = Self.backend
        backend.sessionTiming.displayChangeTimeout = .milliseconds(600)
        let session = try await backend.connect(Self.request(transport))
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        await #expect(throws: ARDEngine.DisplayChangeError.timedOut) {
            try await configuration.setVirtualDisplays([Self.size(400, 300)])
        }
        try await configuration.setVirtualDisplays([Self.size(480, 320)])
        #expect(transport.latest.configurations.last == [Self.mode(Self.size(480, 320))])
        #expect(try Self.display(session).pixelSize == PixelSize(width: 480, height: 320))
        await session.disconnect()
    }

    /// The scripted Mac, like a real one with a still desktop, sends no picture that would say so.
    @Test func aDisplayIsLiveAgainOnceAChangeTheMacNeverAnswersTimesOut() async throws {
        let transport = Self.transport { $0.unansweredConfigurations = [2] }
        var backend = Self.backend
        backend.sessionTiming.displayChangeTimeout = .milliseconds(600)
        let session = try await backend.connect(Self.request(transport))
        let events = session.events()
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        let before = try Self.display(session)
        #expect(before.state == .live)
        await #expect(throws: ARDEngine.DisplayChangeError.timedOut) {
            try await configuration.setVirtualDisplays([Self.size(400, 300)])
        }
        let after = try Self.display(session)
        #expect(after.state == .live)
        #expect(after.pixelSize == before.pixelSize)
        await session.disconnect()
        var announced: [RemoteDisplay.State] = []
        for await event in events {
            if case .layoutChanged(let layout) = event, let state = layout.displays.first?.state { announced.append(state) }
        }
        #expect(announced == [.reconfiguring, .live])
    }

    /// Displays asked for again are asked because their pictures stopped; an unanswered request
    /// leaves nothing known to be good to go back to.
    @Test func aDisplayStaysReconfiguringWhenTheMacNeverBringsItBack() async throws {
        let transport = Self.transport { $0.unansweredConfigurations = [2] }
        let notes = Notes()
        var backend = Self.backend
        backend.sessionTiming.displayChangeTimeout = .milliseconds(600)
        backend.diagnostics = { line in notes.lines.withLock { $0.append(line) } }
        let session = try await backend.connect(Self.request(transport))
        #expect(try Self.display(session).state == .live)
        transport.latest.sendStatus(17)
        await until("the request to time out") {
            notes.lines.withLock { $0.contains { $0.hasPrefix("the Mac did not take up the display configuration") } }
        }
        #expect(try Self.display(session).state == .reconfiguring)
        await session.disconnect()
    }

    @Test(arguments: [
        (kind: UInt32(1), subCode: UInt32(1), failure: ConnectionFailure.busy(detail: "Another viewer is using this Mac's High Performance stream.")),
        (kind: 2, subCode: 0, failure: .modeUnavailable(mode: .highPerformance, reason: .notSupportedByServer)),
    ])
    func aRefusedFirstOfferFailsTheAttempt(kind: UInt32, subCode: UInt32, failure: ConnectionFailure) async {
        let transport = Self.transport { $0.refusedOffers = [0: (kind, subCode)] }
        await #expect(throws: failure) {
            _ = try await Self.backend.connect(Self.request(transport))
        }
    }

    @Test func aRefusalMidSessionEndsTheSession() async throws {
        let transport = Self.transport { $0.refusedOffers = [2: (1, 1)] }
        let session = try await Self.backend.connect(Self.request(transport))
        let events = session.events()
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        await #expect(throws: (any Error).self) {
            try await configuration.setVirtualDisplays([Self.size(400, 300)])
        }
        let reason = await Self.ended(events)
        guard case .remoteClosed(let detail) = reason else {
            Issue.record("ended as \(String(describing: reason))")
            return
        }
        #expect(detail?.contains("heldByAnotherViewer") == true)
    }

    /// A login or logout moves the session to another user's displays; the session's own are
    /// asked for again, also when that news arrives while a change is under way.
    @Test func aUserSessionChangeBringsTheSessionDisplaysBack() async throws {
        let transport = Self.transport { $0.layoutDelay = .milliseconds(150) }
        let session = try await Self.backend.connect(Self.request(transport))
        let mac = transport.latest
        mac.sendStatus(17)
        await until("the displays to be asked for again") { Self.negotiation(mac) == "cococo" }
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        let resize = Task { try await configuration.setVirtualDisplays([Self.size(400, 300)]) }
        await until("the resize to be sent") { mac.configurations.count == 4 }
        mac.sendStatus(17)
        try await resize.value
        await until("the displays to be asked for again after the resize") { Self.negotiation(mac) == "cococococo" }
        #expect(mac.configurations.last == [Self.mode(Self.size(400, 300))])
        await session.disconnect()
    }

    /// After a logout the Mac shows the Login Window on its own display, which is not the
    /// session's. The session asks for its displays once, and does not keep asking.
    @Test func aLayoutThatIsNotTheSessionsIsReassertedOnlyOnce() async throws {
        let transport = Self.transport { $0.physicalFromConfiguration = 2 }
        let session = try await Self.backend.connect(Self.request(transport))
        let mac = transport.latest
        mac.sendStatus(17)
        try await Task.sleep(for: .milliseconds(800))
        #expect(mac.configurations.count <= 4)
        #expect(!session.state.isDisconnected)
        await session.disconnect()
    }

    /// Pointer moves made while the connection is backed up collapse into the latest; the press
    /// after them, and its place after the last move, are kept.
    @Test func movesOnABackedUpConnectionCollapseButClicksAreKept() async throws {
        let transport = ScriptedMacTransport()
        var backend = AppleScreenSharingBackend()
        backend.sessionTiming.inputSettlingTime = .zero
        let session = try await backend.connect(ScriptedMacTests.standardRequest(transport))
        let mac = transport.latest
        let display = try #require(session.layout.displays.first)
        let generation = session.layout.generation
        await mac.stallViewer(true)
        for step in 0..<3000 {
            session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: Double(step % 60), y: 10), layoutGeneration: generation)))
        }
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 33, y: 10), buttons: .primary, layoutGeneration: generation)))
        await mac.stallViewer(false)
        func pointer() -> [ScriptedMac.Received] {
            mac.record.withLock { $0.messages.filter { if case .pointer = $0 { true } else { false } } }
        }
        await until("the press") { pointer().contains(.pointer(mask: 1, x: 33, y: 10)) }
        let received = pointer()
        #expect(received.count < 2000, "\(received.count) moves replayed")
        #expect(received.last == .pointer(mask: 1, x: 33, y: 10))
        #expect(received.dropLast().last == .pointer(mask: 0, x: 2999 % 60, y: 10))
        await session.disconnect()
    }

    /// A Mac discards input from a display change until a while after its layout; input sent
    /// meanwhile is held and arrives, in order, once the Mac takes it again.
    @Test func inputIsHeldAroundADisplayChange() async throws {
        let transport = Self.transport { $0.layoutDelay = .milliseconds(300) }
        var backend = Self.backend
        backend.sessionTiming.inputSettlingTime = .zero
        backend.sessionTiming.displayChangeInputHold = .milliseconds(400)
        let session = try await backend.connect(Self.request(transport))
        let mac = transport.latest
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        let resize = Task { try await configuration.setVirtualDisplays([Self.size(400, 300)]) }
        await until("the change to be sent") { mac.configurations.count == 3 }
        let sent = ContinuousClock.now
        session.input.send(.key(KeyEvent(key: .a, characters: "a", charactersIgnoringModifiers: "a", phase: .down)))
        session.input.send(.key(KeyEvent(key: .a, characters: "a", charactersIgnoringModifiers: "a", phase: .up)))
        func keys() -> [ScriptedMac.Received] {
            mac.record.withLock { $0.messages.filter { if case .key = $0 { true } else { false } } }
        }
        try await resize.value
        #expect(keys().isEmpty, "input reached the Mac while it was making the displays")
        await until("the held input") { keys().count == 2 }
        // The layout came about 300 ms after the change, and the hold lasts 400 ms after it.
        #expect(ContinuousClock.now - sent >= .milliseconds(600))
        #expect(keys() == [.key(keysym: 0x61, isDown: true), .key(keysym: 0x61, isDown: false)])
        await session.disconnect()
    }

    /// A button pressed on one layout and released after the displays changed is released all
    /// the same: a lost release leaves the Mac's button down.
    @Test func aButtonReleaseFromAnOldLayoutStillReachesTheMac() async throws {
        let transport = Self.transport()
        var backend = Self.backend
        backend.sessionTiming.inputSettlingTime = .zero
        backend.sessionTiming.displayChangeInputHold = .zero
        let session = try await backend.connect(Self.request(transport))
        let mac = transport.latest
        let display = try Self.display(session)
        let old = session.layout.generation
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 10, y: 20), buttons: .primary, layoutGeneration: old)))
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        try await configuration.setVirtualDisplays([Self.size(400, 300)])
        #expect(session.layout.generation != old)
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 11, y: 21), layoutGeneration: old)))
        func pointer() -> [ScriptedMac.Received] {
            mac.record.withLock { $0.messages.filter { if case .pointer = $0 { true } else { false } } }
        }
        await until("the release") { pointer().count == 2 }
        #expect(pointer().first == .pointer(mask: 1, x: 10, y: 20))
        guard case .pointer(0, _, _)? = pointer().last else {
            Issue.record("no release: \(pointer())")
            return
        }
        await session.disconnect()
    }

    /// Whatever ends the session, keys and buttons held on the Mac are let go while the
    /// connection still carries them, and disconnecting returns once the connection is closed.
    @Test func teardownLetsGoOfHeldInputAndClosesBeforeReturning() async throws {
        let transport = Self.transport()
        var backend = Self.backend
        backend.sessionTiming.inputSettlingTime = .zero
        let session = try await backend.connect(Self.request(transport))
        let mac = transport.latest
        let display = try Self.display(session)
        session.input.send(.key(KeyEvent(key: .leftCommand, phase: .down)))
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 5, y: 6), buttons: .primary, layoutGeneration: session.layout.generation)))
        await until("the presses") { mac.record.withLock { $0.messages.contains(.pointer(mask: 1, x: 5, y: 6)) } }
        await session.disconnect()
        #expect(mac.record.withLock { $0.viewerClosed }, "disconnect returned before the connection closed")
        let input = mac.record.withLock { $0.messages.filter { if case .key = $0 { true } else if case .pointer = $0 { true } else { false } } }
        #expect(input.suffix(2).contains(.key(keysym: 0xffeb, isDown: false)))
        #expect(input.suffix(2).contains(.pointer(mask: 0, x: 5, y: 6)))
    }

    @Test func aSessionEndedByAProtocolViolationStillLetsGoOfHeldKeys() async throws {
        let transport = Self.transport()
        var backend = Self.backend
        backend.sessionTiming.inputSettlingTime = .zero
        let session = try await backend.connect(Self.request(transport))
        let mac = transport.latest
        let events = session.events()
        session.input.send(.key(KeyEvent(key: .leftShift, phase: .down)))
        await until("the press") { mac.record.withLock { $0.messages.contains(.key(keysym: 0xffe1, isDown: true)) } }
        mac.send(Data([0xee, 1, 2, 3]))
        guard case .protocolViolation = await Self.ended(events) else {
            Issue.record("did not end as a violation")
            return
        }
        await until("the release") { mac.record.withLock { $0.messages.contains(.key(keysym: 0xffe1, isDown: false)) } }
    }

    /// A Mac sends reports on every leg once a second. When nothing at all arrives after the
    /// answer, something between the two machines blocks the datagrams: the attempt says so
    /// within seconds, and Standard mode is the way on.
    @Test func mediaThatNeverArrivesIsReportedAsBlockedSoon() async {
        let transport = Self.transport { $0.sendsMedia = false }
        var backend = Self.backend
        backend.firstPictureTimeout = .seconds(30)
        let started = ContinuousClock.now
        await #expect(throws: ConnectionFailure.modeUnavailable(mode: .highPerformance, reason: .mediaBlocked)) {
            _ = try await backend.connect(Self.request(transport))
        }
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    /// Every leg is watched at start, not only the first.
    @Test func aSecondLegThatNeverArrivesIsNoticed() async {
        let transport = Self.transport { $0.silentLegs = [1] }
        var backend = Self.backend
        backend.firstPictureTimeout = .seconds(30)
        let started = ContinuousClock.now
        await #expect(throws: ConnectionFailure.modeUnavailable(mode: .highPerformance, reason: .mediaBlocked)) {
            _ = try await backend.connect(Self.request(transport, displays: [Self.small, Self.small]))
        }
        #expect(ContinuousClock.now - started < .seconds(15))
    }

    // MARK: HDR

    /// Notes the back end makes, for what they say about offers.
    final class Notes: Sendable {
        let lines = Mutex<[String]>([])
        var offers: [String] { lines.withLock { $0.filter { $0.hasPrefix("offered media for") } } }
    }

    /// The scripted Mac sends H.264 pictures whatever is offered; offering HEVC still lets a test
    /// see what an HDR offer would carry.
    static func hdrBackend(_ dynamicRange: AppleScreenSharingBackend.DynamicRangePreference, notes: Notes) -> AppleScreenSharingBackend {
        var backend = Self.backend
        backend.videoCodec = .hevc
        backend.dynamicRange = dynamicRange
        backend.diagnostics = { line in notes.lines.withLock { $0.append(line) } }
        return backend
    }

    static func hdrSize(_ wantsHDR: Bool) -> VirtualDisplayRequest {
        VirtualDisplayRequest(pointSize: PixelSize(width: 320, height: 200), scale: 1, wantsHDR: wantsHDR)
    }

    /// A display is asked for in HDR, and offered HDR pictures, only when it wants HDR, the device
    /// takes it and the Mac makes it. The opening displays are always SDR.
    @Test(arguments: [
        // wants HDR, device, Mac makes HDR, display asked in HDR, offered HDR
        (true, AppleScreenSharingBackend.DynamicRangePreference.high, true, true, true),
        (true, .high, false, true, false),
        (true, .standard, true, false, false),
        (false, .high, true, false, false),
    ])
    func hdrNeedsTheDisplayTheDeviceAndTheMac(wants: Bool, device: AppleScreenSharingBackend.DynamicRangePreference, macMakesHDR: Bool, askedInHDR: Bool, offeredHDR: Bool) async throws {
        let transport = Self.transport { $0.makesHDRDisplays = macMakesHDR }
        let notes = Notes()
        let session = try await Self.hdrBackend(device, notes: notes).connect(Self.request(transport, displays: [Self.hdrSize(wants)]))
        let mac = transport.latest
        #expect(mac.configurations.first == [.opening])
        let last = try #require(mac.configurations.last?.first)
        #expect(last.isHDR == askedInHDR)
        #expect(notes.offers.count == 2)
        #expect(notes.offers.first?.hasSuffix("HDR") == false, "the opening display's offer")
        #expect(notes.offers.last?.hasSuffix("HDR") == offeredHDR)
        await session.disconnect()
    }

    /// The virtual displays made like the Mac's own screens are HDR as the session's options say.
    @Test(arguments: [true, false])
    func displaysLikeTheMacsOwnFollowTheOptions(wantsHDR: Bool) async throws {
        let transport = Self.transport()
        let notes = Notes()
        var request = Self.request(transport)
        request.options.displays = .physical(.all)
        request.options.wantsHDR = wantsHDR
        let session = try await Self.hdrBackend(.high, notes: notes).connect(request)
        let mac = transport.latest
        #expect(mac.configurations.last?.allSatisfy { $0.isHDR == wantsHDR } == true)
        await session.disconnect()
    }

    /// A display that stops wanting HDR (a monitor without it took over) is asked for again in SDR.
    @Test func aDisplayCanGoFromHDRToSDRAndBack() async throws {
        let transport = Self.transport()
        let notes = Notes()
        let session = try await Self.hdrBackend(.high, notes: notes).connect(Self.request(transport, displays: [Self.hdrSize(true)]))
        let mac = transport.latest
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        try await configuration.setVirtualDisplays([Self.hdrSize(false)])
        #expect(mac.configurations.last?.first?.isHDR == false)
        #expect(notes.offers.last?.hasSuffix("HDR") == false)
        try await configuration.setVirtualDisplays([Self.hdrSize(true)])
        #expect(mac.configurations.last?.first?.isHDR == true)
        #expect(notes.offers.last?.hasSuffix("HDR") == true)
        #expect(mac.configurations.count == 4)
        await session.disconnect()
    }

    /// The constrained profile gives HDR up with the rate.
    @Test func steppingDownGivesHDRUp() async throws {
        let transport = Self.transport {
            $0.pictureInterval = .milliseconds(40)
            $0.packetPayload = 100
        }
        let notes = Notes()
        var backend = Self.hdrBackend(.high, notes: notes)
        backend.sessionTiming.lossWindow = .milliseconds(400)
        backend.sessionTiming.lossWindowPackets = 40
        let session = try await backend.connect(Self.request(transport, displays: [Self.hdrSize(true)]))
        let mac = transport.latest
        #expect(mac.configurations.last?.first?.isHDR == true)
        #expect(session.capabilities.highDynamicRange.isAvailable)
        mac.losePackets(every: 3)
        await until("the step down", timeout: .seconds(5)) { mac.configurations.count == 3 }
        #expect(mac.configurations.last?.first?.isHDR == false)
        #expect(session.capabilities.highDynamicRange.unavailableReason == .lowBandwidth)
        await session.disconnect()
    }

    /// A session that starts in the constrained profile (a metered network) has no HDR to offer.
    @Test func aConstrainedStartHasNoHDR() async throws {
        let transport = Self.transport()
        let notes = Notes()
        var backend = Self.hdrBackend(.high, notes: notes)
        backend.sessionTiming.bandwidthProfile = .constrained
        let session = try await backend.connect(Self.request(transport, displays: [Self.hdrSize(true)]))
        #expect(session.capabilities.highDynamicRange.unavailableReason == .lowBandwidth)
        #expect(transport.latest.configurations.last?.first?.isHDR == false)
        await session.disconnect()
    }
}

@Suite struct FramebufferSnapshotTests {
    /// New buffers for every picture of two 5K–6K displays take an iPhone Duo past its memory
    /// limit within a second, so snapshots come from a pool with a ceiling.
    @Test func snapshotsAreLimitedAndReusedOnceLetGo() throws {
        let framebuffer = Framebuffer(size: PixelSize(width: 64, height: 32))
        let left = PixelRect(x: 0, y: 0, width: 32, height: 32)
        var held: [CVReadOnlyPixelBuffer] = []
        for _ in 0..<Framebuffer.snapshotsInFlight {
            held.append(try #require(framebuffer.snapshot(of: left)))
        }
        #expect(framebuffer.snapshot(of: left) == nil, "no more than the ceiling of one size at once")
        // Another size has a pool of its own.
        #expect(framebuffer.snapshot(of: PixelRect(x: 0, y: 0, width: 64, height: 32)) != nil)
        held.removeFirst()
        #expect(framebuffer.snapshot(of: left) != nil, "a buffer let go is used again")
    }
}
