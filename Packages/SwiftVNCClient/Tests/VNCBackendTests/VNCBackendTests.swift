// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import CoreVideo
import Foundation
import RemoteDesktopConformance
import RemoteDesktopCore
import RemoteDesktopTransport
import SwiftVNCClientTestSupport
import Synchronization
import Testing
@testable import VNCBackend

/// A pipe end as the stream a transport provider hands out.
private struct PipeStream: ByteStream {
    let end: PipeEnd

    func read(upTo maxLength: Int) async throws -> Data? { try await end.read(upTo: maxLength) }
    func write(_ data: Data) async throws { try await end.write(data) }
    func close() async { await end.close() }
}

/// Reaches a new scripted server on every connection, the way a real host accepts a new socket.
private final class ScriptedTransport: TransportProvider {
    let peer = Endpoint(host: "scripted.test", port: 5900)
    let isTunnelled: Bool
    let supportsDatagrams = false
    let password: String?
    let servers = Mutex<[ScriptedServer]>([])
    private let makeServer: @Sendable (PipeEnd, String?) -> ScriptedServer

    init(
        password: String? = nil, isTunnelled: Bool = false,
        server: @escaping @Sendable (PipeEnd, String?) -> ScriptedServer = { ScriptedServer(end: $0, password: $1) }
    ) {
        self.password = password
        self.isTunnelled = isTunnelled
        makeServer = server
    }

    var latest: ScriptedServer { servers.withLock { $0.last! } }

    func openStream(port: UInt16) async throws -> any ByteStream {
        let (clientEnd, serverEnd) = PipeEnd.pair()
        let server = makeServer(serverEnd, password)
        servers.withLock { $0.append(server) }
        Task { try? await server.run() }
        return PipeStream(end: clientEnd)
    }

    func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel {
        throw TransportError.unsupported(detail: "no datagrams in a pipe")
    }
}

/// Answers password prompts from a list, one per attempt, and remembers what it was asked.
private final class ScriptedPrompts: PromptHandler {
    let answers: Mutex<[String?]>
    let asked = Mutex<[CredentialRequest]>([])

    init(_ answers: [String?]) {
        self.answers = Mutex(answers)
    }

    func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
        guard case .credentials(let request) = prompt else { return .cancel }
        asked.withLock { $0.append(request) }
        let answer: String?? = answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        guard let answer, let password = answer else { return .cancel }
        return .credentials(username: "", password: password)
    }
}

private func until(_ what: String, timeout: Duration = .seconds(5), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(what)")
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@Suite struct VNCBackendTests {
    private func connect(
        _ transport: ScriptedTransport = ScriptedTransport(), options: SessionOptions = SessionOptions(),
        prompts: any PromptHandler = StaticPromptHandler(username: "", password: "")
    ) async throws(ConnectionFailure) -> any RemoteSession {
        try await VNCBackend().connect(ConnectionRequest(options: options, transport: transport, prompts: prompts))
    }

    @Test(arguments: BackendConformance.allChecks)
    func conformsToTheSessionContract(check: BackendConformance.Check) async throws {
        let transport = ScriptedTransport()
        let suite = BackendConformance(backend: VNCBackend(), timeout: .seconds(10)) {
            ConnectionRequest(transport: transport, prompts: StaticPromptHandler(username: "", password: ""))
        }
        try await suite.run(check)
    }

    @Test func describesTheSessionAndItsLimits() async throws {
        let session = try await connect()
        #expect(session.info.backendID == "vnc")
        #expect(session.info.mode == .standard)
        #expect(session.info.remoteName == "Scripted Desktop")
        #expect(!session.info.isTunnelled)
        #expect(!session.info.isEncrypted && !session.info.isServerAuthenticated)
        #expect(session.layout.displays.map(\.pixelSize) == [PixelSize(width: 64, height: 48)])
        #expect(session.capabilities.clipboard.isAvailable)
        #expect(session.capabilities.audio.unavailableReason == .notSupportedByBackend)
        #expect(session.capabilities.displayConfiguration.unavailableReason == .notSupportedByBackend)
        #expect(session.capabilities.quality.value?.supportedPresets == [.adaptive, .full])
        await session.disconnect()
        #expect(session.state == .disconnected(.userInitiated))
    }

    /// Full is lossless: no JPEG quality among the encodings (-32 to -23 are qualities 0 to 9).
    @Test(arguments: [(QualityPreset.adaptive, [Int32(-24)]), (.full, [])])
    func theChosenQualityIsWhatTheServerIsAskedFor(preset: QualityPreset, qualities: [Int32]) async throws {
        let transport = ScriptedTransport()
        let session = try await connect(transport, options: SessionOptions(quality: preset))
        #expect(transport.latest.recorded.withLock { $0.encodings }.filter { (-32)...(-23) ~= $0 } == qualities)
        await session.disconnect()
    }

    @Test func qualityCanBeChangedDuringASession() async throws {
        let transport = ScriptedTransport()
        let session = try await connect(transport)
        let quality = try #require(session.capabilities.quality.value)
        try await quality.setPreset(.full)
        await until("JPEG is no longer asked for") {
            !transport.latest.recorded.withLock { $0.encodings }.contains(-24)
        }
        await session.disconnect()
        await #expect(throws: TransportError.self) { try await quality.setPreset(.adaptive) }
    }

    @Test func firstFrameCarriesTheServersPixels() async throws {
        let session = try await connect()
        let display = try #require(session.layout.displays.first)
        let frame = try #require(await session.frames(for: display.id).next())
        #expect(frame.pixelSize == PixelSize(width: 64, height: 48))
        let pixels: [[UInt8]] = frame.surface.withUnsafeBuffer { buffer in
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(buffer)!
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            return [(0, 0), (63, 0), (10, 20), (63, 47)].map { x, y in
                let pixel = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
                return [pixel[0], pixel[1], pixel[2]]
            }
        }
        #expect(pixels == [(0, 0), (63, 0), (10, 20), (63, 47)].map { Array(ScriptedServer.pixel(x: $0.0, y: $0.1).prefix(3)) })
        await session.disconnect()
    }

    @Test func highPerformanceIsRefusedBeforeConnecting() async {
        let transport = ScriptedTransport()
        await #expect(throws: ConnectionFailure.modeUnavailable(mode: .highPerformance, reason: .notSupportedByBackend)) {
            _ = try await connect(transport, options: SessionOptions(mode: .require(.highPerformance)))
        }
        #expect(transport.servers.withLock { $0.isEmpty })
    }

    /// A computer that has proved its identity before gets nothing from a login that cannot.
    @Test func aComputerThatMustProveItselfIsNotContacted() async {
        let transport = ScriptedTransport(password: "s3cret")
        let prompts = ScriptedPrompts(["s3cret"])
        do {
            _ = try await connect(transport, options: SessionOptions(requiresServerAuthentication: true), prompts: prompts)
            Issue.record("connected without the server proving itself")
        } catch {
            guard case .identityUnverifiable = error else {
                Issue.record("failed as \(error)")
                return
            }
        }
        #expect(transport.servers.withLock { $0.isEmpty })
        #expect(prompts.asked.withLock { $0.isEmpty })
    }

    @Test func asksForThePasswordOnce() async throws {
        let prompts = ScriptedPrompts(["s3cret"])
        let session = try await connect(ScriptedTransport(password: "s3cret"), prompts: prompts)
        let asked = prompts.asked.withLock { $0 }
        #expect(asked.count == 1)
        #expect(asked.first?.kind == .passwordOnly)
        #expect(asked.first?.attempt == 1)
        #expect(asked.first?.context == .remoteDesktop(host: "scripted.test"))
        await session.disconnect()
    }

    @Test func aRejectedPasswordIsAskedForAgain() async throws {
        let prompts = ScriptedPrompts(["wrong", "s3cret"])
        let transport = ScriptedTransport(password: "s3cret")
        let session = try await connect(transport, prompts: prompts)
        let asked = prompts.asked.withLock { $0 }
        #expect(asked.map(\.attempt) == [1, 2])
        // In the server's own words.
        #expect(asked.last?.previousFailure == "Authentication failed")
        // The server hangs up on a wrong password, so the second try is a second connection.
        #expect(transport.servers.withLock { $0.count } == 2)
        await session.disconnect()
    }

    @Test func phasesAreReportedInOrderAndNeverGoBack() async throws {
        let phases = Mutex<[ConnectionPhase]>([])
        let session = try await VNCBackend().connect(ConnectionRequest(
            transport: ScriptedTransport(password: "s3cret"), prompts: ScriptedPrompts(["wrong", "s3cret"]),
            progress: { phase in phases.withLock { $0.append(phase) } }
        ))
        // The second try at the password is a second connection, but still part of signing in.
        #expect(phases.withLock { $0 } == [.reachingHost, .negotiating, .authenticating, .authenticating, .preparingDisplays])
        await session.disconnect()
    }

    @Test func threeRejectedPasswordsEndAsAnAuthenticationFailure() async {
        let prompts = ScriptedPrompts(["one", "two", "three", "four"])
        do {
            _ = try await connect(ScriptedTransport(password: "s3cret"), prompts: prompts)
            Issue.record("connected with a wrong password")
        } catch {
            guard case .authenticationFailed = error else {
                Issue.record("failed as \(error)")
                return
            }
        }
        #expect(prompts.asked.withLock { $0.count } == 3)
    }

    /// TigerVNC turns clients away for a while after wrong passwords; asking again would only
    /// extend that.
    @Test func aServerThatTakesNoMoreAttemptsIsNotAskedAgain() async {
        let prompts = ScriptedPrompts(["s3cret"])
        let transport = ScriptedTransport(password: "s3cret") { end, _ in
            ScriptedServer(end: end, refusal: .beforeAuthentication("Too many security failures"))
        }
        await #expect(throws: ConnectionFailure.authenticationFailed(detail: "Too many security failures")) {
            _ = try await connect(transport, prompts: prompts)
        }
        #expect(prompts.asked.withLock { $0.isEmpty })
        #expect(transport.servers.withLock { $0.count } == 1)
    }

    @Test(arguments: [
        ("Too many authentication failures", ConnectionFailure.authenticationFailed(detail: "Too many authentication failures")),
        ("No matching security types", .unsupportedServer(detail: "No matching security types")),
        ("Server is busy", .busy(detail: "Server is busy")),
        ("Connection rejected by user", .permissionDenied(detail: "Connection rejected by user")),
    ])
    func refusalsAreSortedByWhatTheServerSaid(reason: String, failure: ConnectionFailure) {
        #expect(VNCBackend.failure(forRefusal: reason) == failure)
    }

    @Test func decliningThePasswordCancels() async {
        await #expect(throws: ConnectionFailure.cancelled) {
            _ = try await connect(ScriptedTransport(password: "s3cret"), prompts: ScriptedPrompts([nil]))
        }
    }

    @Test func aServerThatIsNotVNCIsReportedAsUnsupported() async {
        struct Garbage: TransportProvider {
            let peer = Endpoint(host: "garbage.test", port: 5900)
            let isTunnelled = false
            let supportsDatagrams = false
            func openStream(port: UInt16) async throws -> any ByteStream {
                let (clientEnd, serverEnd) = PipeEnd.pair()
                Task {
                    try? await serverEnd.write(Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
                    await serverEnd.close()
                }
                return PipeStream(end: clientEnd)
            }
            func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel {
                throw TransportError.unsupported(detail: "")
            }
        }
        do {
            _ = try await VNCBackend().connect(ConnectionRequest(transport: Garbage(), prompts: StaticPromptHandler(username: "", password: "")))
            Issue.record("connected to something that is not a VNC server")
        } catch {
            guard case .unsupportedServer = error else {
                Issue.record("failed as \(error)")
                return
            }
        }
    }

    @Test func anUnreachableHostIsReportedAsSuch() async {
        struct Dead: TransportProvider {
            let peer = Endpoint(host: "dead.test", port: 5900)
            let isTunnelled = false
            let supportsDatagrams = false
            func openStream(port: UInt16) async throws -> any ByteStream { throw TransportError.unreachable(detail: "no route") }
            func openDatagramChannel(_ options: DatagramOptions) async throws -> any DatagramChannel {
                throw TransportError.unsupported(detail: "")
            }
        }
        await #expect(throws: ConnectionFailure.unreachable(host: "dead.test", detail: "no route")) {
            _ = try await VNCBackend().connect(ConnectionRequest(transport: Dead(), prompts: StaticPromptHandler(username: "", password: "")))
        }
    }

    @Test func keysBecomeKeysymsAndAreReleasedOnce() async throws {
        let transport = ScriptedTransport()
        let session = try await connect(transport)
        let server = transport.latest
        session.input.send(.key(KeyEvent(key: .a, characters: "a", charactersIgnoringModifiers: "a", phase: .down)))
        // A repeat of a key that is already down adds nothing.
        session.input.send(.key(KeyEvent(key: .a, characters: "a", charactersIgnoringModifiers: "a", phase: .down)))
        session.input.send(.key(KeyEvent(key: .a, characters: "a", charactersIgnoringModifiers: "a", phase: .up)))
        session.input.send(.key(KeyEvent(key: .leftCommand, phase: .down)))
        session.input.send(.key(KeyEvent(key: .leftOption, phase: .down)))
        session.input.send(.key(KeyEvent(key: .returnOrEnter, phase: .down)))
        session.input.send(.releaseAll)
        await until("the releases") { server.recorded.withLock { $0.keys.count >= 8 } }
        let keys = server.recorded.withLock { $0.keys }
        #expect(keys.prefix(2).map { "\($0.keysym):\($0.isDown)" } == ["97:true", "97:false"])
        // On a generic server Command is Super and Option is Alt.
        #expect(keys.dropFirst(2).prefix(3).map { "\(String($0.keysym, radix: 16)):\($0.isDown)" } == ["ffeb:true", "ffe9:true", "ff0d:true"])
        #expect(Set(keys.suffix(3).map(\.keysym)) == [0xffeb, 0xffe9, 0xff0d])
        #expect(keys.suffix(3).allSatisfy { !$0.isDown })
        await session.disconnect()
    }

    @Test func typedTextIsSentAsKeyTaps() async throws {
        let transport = ScriptedTransport()
        let session = try await connect(transport)
        let server = transport.latest
        // A decomposed é is composed first; the heart's variation selector goes as a key of its own.
        session.input.send(.text("He\u{301}❤️"))
        await until("the text") { server.recorded.withLock { $0.keys.count >= 8 } }
        #expect(server.recorded.withLock { $0.keys }.map { "\(String($0.keysym, radix: 16)):\($0.isDown)" } == [
            "48:true", "48:false", "e9:true", "e9:false", "1002764:true", "1002764:false", "100fe0f:true", "100fe0f:false",
        ])
        await session.disconnect()
    }

    /// A Mac's own server reads Alt as Command. Its buttons stay RFB's on this protocol (right is
    /// bit 2), unlike on its own.
    @Test func aMacsServerGetsOptionAsMeta() async throws {
        let transport = ScriptedTransport { end, _ in ScriptedServer(end: end, version: "RFB 003.889\n") }
        var backend = VNCBackend()
        backend.inputSettlingTimeForMacs = .zero
        let session = try await backend.connect(ConnectionRequest(transport: transport, prompts: StaticPromptHandler(username: "", password: "")))
        let server = transport.latest
        let display = try #require(session.layout.displays.first)
        session.input.send(.key(KeyEvent(key: .leftOption, phase: .down)))
        session.input.send(.key(KeyEvent(key: .leftOption, phase: .up)))
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 3, y: 4), buttons: .secondary, layoutGeneration: session.layout.generation)))
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 3, y: 4), buttons: .middle, layoutGeneration: session.layout.generation)))
        await until("the input") { server.recorded.withLock { $0.keys.count >= 2 && $0.pointers.count >= 2 } }
        #expect(server.recorded.withLock { $0.keys }.map(\.keysym) == [X11Keysym.metaLeft, X11Keysym.metaLeft])
        // Beyond U+FFFF a Mac takes a character's UTF-16 surrogates.
        session.input.send(.text("👍"))
        await until("the emoji") { server.recorded.withLock { $0.keys.count >= 6 } }
        #expect(server.recorded.withLock { $0.keys }.dropFirst(2).map(\.keysym) == [0x0100_d83d, 0x0100_d83d, 0x0100_dc4d, 0x0100_dc4d])
        #expect(server.recorded.withLock { $0.pointers }.map(\.mask) == [4, 2])
        await session.disconnect()
    }

    @Test func pointerAndScrollUseTheServersButtonNumbers() async throws {
        let transport = ScriptedTransport()
        let session = try await connect(transport)
        let server = transport.latest
        let display = try #require(session.layout.displays.first)
        let generation = session.layout.generation
        func pointer(_ x: Double, _ y: Double, _ buttons: PointerButtons) -> InputEvent {
            .pointer(PointerEvent(display: display.id, position: PixelPoint(x: x, y: y), buttons: buttons, layoutGeneration: generation))
        }
        session.input.send(pointer(10, 20, []))
        session.input.send(pointer(10, 20, .secondary))
        session.input.send(pointer(10, 20, []))
        // Outside the display: clamped to its last pixel.
        session.input.send(pointer(500, -3, .primary))
        // An event for a layout that no longer exists is dropped.
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 1, y: 1), layoutGeneration: generation + 1)))
        // Two notches of precise scrolling, content moving down.
        session.input.send(.scroll(ScrollEvent(display: display.id, position: PixelPoint(x: 63, y: 0), deltaX: 0, deltaY: 80, isPrecise: true, layoutGeneration: generation)))
        session.input.send(.releaseAll)
        await until("the pointer events") { server.recorded.withLock { $0.pointers.count >= 9 } }
        #expect(server.recorded.withLock { $0.pointers }.map { [$0.x, $0.y, $0.mask] } == [
            [10, 20, 0], [10, 20, 4], [10, 20, 0], [63, 0, 1],
            [63, 0, 1 | 8], [63, 0, 1], [63, 0, 1 | 8], [63, 0, 1],
            [63, 0, 0],
        ])
        await session.disconnect()
    }

    /// A Mac drops input for a while after a login; input from then is held and sent in order.
    @Test func inputToAMacWaitsUntilItListens() async throws {
        let transport = ScriptedTransport { end, _ in ScriptedServer(end: end, version: "RFB 003.889\n") }
        var backend = VNCBackend()
        backend.inputSettlingTimeForMacs = .milliseconds(400)
        let session = try await backend.connect(ConnectionRequest(transport: transport, prompts: StaticPromptHandler(username: "", password: "")))
        let connected = ContinuousClock.now
        let server = transport.latest
        session.input.send(.text("ab"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.recorded.withLock { $0.keys.isEmpty })
        await until("the held keys") { server.recorded.withLock { $0.keys.count >= 4 } }
        #expect(ContinuousClock.now - connected >= .milliseconds(350))
        #expect(server.recorded.withLock { $0.keys }.map(\.keysym) == [0x61, 0x61, 0x62, 0x62])
        let plain = ScriptedTransport()
        let other = try await connect(plain)
        other.input.send(.text("c"))
        await until("the key", timeout: .milliseconds(300)) { plain.latest.recorded.withLock { $0.keys.count >= 2 } }
        await other.disconnect()
        await session.disconnect()
    }

    /// A held key repeats only through downs marked as repeats; others are dropped.
    @Test func aRepeatGoesDownAgainAsWhatWasPressed() async throws {
        let transport = ScriptedTransport()
        let session = try await connect(transport)
        let server = transport.latest
        session.input.send(.key(KeyEvent(key: .a, characters: "a", charactersIgnoringModifiers: "a", phase: .down)))
        session.input.send(.key(KeyEvent(key: .a, characters: "a", charactersIgnoringModifiers: "a", phase: .down)))
        // Shift came down meanwhile; the repeat is still the key that was pressed.
        session.input.send(.key(KeyEvent(key: .a, characters: "A", charactersIgnoringModifiers: "a", modifiers: .leftShift, phase: .down, isRepeat: true)))
        session.input.send(.key(KeyEvent(key: .a, phase: .up)))
        session.input.send(.key(KeyEvent(key: .b, phase: .down, isRepeat: false)))
        session.input.send(.key(KeyEvent(key: .b, phase: .up)))
        await until("the keys") { server.recorded.withLock { $0.keys.count >= 5 } }
        #expect(server.recorded.withLock { $0.keys }.map { "\(String($0.keysym, radix: 16)):\($0.isDown)" } == ["61:true", "61:true", "61:false", "62:true", "62:false"])
        await session.disconnect()
    }

    /// What is left over from one gesture does not add a notch to the next.
    @Test func aNewScrollStartsFromNothing() async throws {
        let transport = ScriptedTransport()
        let session = try await connect(transport)
        let server = transport.latest
        let display = try #require(session.layout.displays.first)
        func scroll(_ deltaY: Double, _ phase: ScrollEvent.Phase) -> InputEvent {
            .scroll(ScrollEvent(display: display.id, position: PixelPoint(x: 1, y: 1), deltaX: 0, deltaY: deltaY, isPrecise: true, phase: phase, layoutGeneration: session.layout.generation))
        }
        // Three quarters of a notch, then a new gesture of half a notch: no notch at all.
        session.input.send(scroll(30, .began))
        session.input.send(scroll(0, .ended))
        session.input.send(scroll(20, .began))
        session.input.send(scroll(0, .ended))
        session.input.send(.text("x"))
        await until("the marker key") { server.recorded.withLock { !$0.keys.isEmpty } }
        #expect(server.recorded.withLock { $0.pointers }.isEmpty)
        await session.disconnect()
    }

    @Test func observingSendsNoInput() async throws {
        let transport = ScriptedTransport()
        var options = SessionOptions()
        options.controlMode = .observe
        let session = try await connect(transport, options: options)
        let server = transport.latest
        session.input.send(.text("ignored"))
        try await session.capabilities.control.value?.setControlMode(.control)
        session.input.send(.text("x"))
        await until("the allowed key") { server.recorded.withLock { $0.keys.count >= 2 } }
        #expect(server.recorded.withLock { $0.keys }.map(\.keysym) == [0x78, 0x78])
        await session.disconnect()
    }

    @Test func clipboardTextTravelsBothWays() async throws {
        let transport = ScriptedTransport()
        let session = try await connect(transport)
        let server = transport.latest
        let clipboard = try #require(session.capabilities.clipboard.value)

        try await clipboard.sendToRemote([ClipboardItem(text: "copied here")])
        await until("the server's copy") { server.recorded.withLock { !$0.clipboard.isEmpty } }
        #expect(server.recorded.withLock { $0.clipboard } == ["copied here"])

        let offers = clipboard.remoteOffers()
        server.sendCutText("from the server")
        server.sendBell()
        let display = try #require(session.layout.displays.first)
        session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: 1, y: 1), layoutGeneration: session.layout.generation)))
        await session.suspend()
        await session.resume()
        try await server.sendQueued()
        var iterator = offers.makeAsyncIterator()
        let offer = try #require(await iterator.next())
        #expect(try await offer.load() == [ClipboardItem(text: "from the server")])
        await session.disconnect()
    }

    @Test func aClipboardWithoutTextIsNotSent() async throws {
        let transport = ScriptedTransport()
        let session = try await connect(transport)
        let server = transport.latest
        let clipboard = try #require(session.capabilities.clipboard.value)
        try await clipboard.sendToRemote([ClipboardItem(representations: ["public.png": Data([0x89, 0x50])])])
        try await clipboard.sendToRemote([ClipboardItem(text: "after")])
        await until("the server's copy") { server.recorded.withLock { !$0.clipboard.isEmpty } }
        #expect(server.recorded.withLock { $0.clipboard } == ["after"])
        await session.disconnect()
    }

    /// A network failure, or an end noticed on returning from the background, is worth a reconnect.
    @Test func aBrokenConnectionCanBeRecovered() async throws {
        let transport = ScriptedTransport()
        let session = try await connect(transport)
        let events = session.events()
        await transport.latest.fail()
        for await event in events {
            if case .stateChanged(.disconnected(let reason)) = event {
                guard case .connectionLost = reason else {
                    Issue.record("ended as \(reason)")
                    break
                }
                #expect(reason.isRecoverable)
                break
            }
        }
    }

    @Test func anEndWhileInTheBackgroundCanBeRecovered() async throws {
        let transport = ScriptedTransport()
        let session = try await connect(transport)
        let events = session.events()
        await session.suspend()
        await transport.latest.hangUp()
        for await event in events {
            if case .stateChanged(.disconnected(let reason)) = event {
                #expect(reason.isRecoverable, "ended as \(reason)")
                break
            }
        }
    }

    /// A request beside the one outstanding would freeze the colour depth, so a return from the
    /// background shows what the client already has.
    @Test(.timeLimit(.minutes(1))) func returningFromTheBackgroundShowsThePictureWithoutAskingTheServer() async throws {
        let transport = ScriptedTransport()
        let session = try await connect(transport)
        let display = try #require(session.layout.displays.first)
        let frames = session.frames(for: display.id)
        _ = await frames.next()
        let requests = transport.latest.recorded.withLock { $0.updateRequests }
        await session.suspend()
        await session.resume()
        #expect(await frames.next() != nil)
        #expect(transport.latest.recorded.withLock { $0.updateRequests } == requests)
        await session.disconnect()
    }

    @Test(.timeLimit(.minutes(1))) func anEndJustAfterReturningFromTheBackgroundCanBeRecovered() async throws {
        let transport = ScriptedTransport()
        var backend = VNCBackend()
        backend.resumeGraceTime = .seconds(30)
        let session = try await backend.connect(ConnectionRequest(options: SessionOptions(), transport: transport, prompts: StaticPromptHandler(username: "", password: "")))
        let events = session.events()
        await session.suspend()
        await session.resume()
        await transport.latest.hangUp()
        for await event in events {
            if case .stateChanged(.disconnected(let reason)) = event {
                #expect(reason.isRecoverable, "ended as \(reason)")
                break
            }
        }
    }

    @Test func theServerHangingUpEndsTheSession() async throws {
        let transport = ScriptedTransport()
        let session = try await connect(transport)
        let events = session.events()
        await transport.latest.hangUp()
        for await event in events {
            if case .stateChanged(.disconnected(let reason)) = event {
                #expect(reason == .remoteClosed(detail: nil))
                break
            }
        }
        #expect(session.state.isDisconnected)
        #expect(!session.capabilities.clipboard.isAvailable)
    }

    @Test func aTunnelledSessionSaysSo() async throws {
        let session = try await connect(ScriptedTransport(isTunnelled: true))
        #expect(session.info.isTunnelled)
        await session.disconnect()
    }
}

/// Against a real Mac, used as a plain VNC server (`MARIONETTE_TEST_HOST`, `Scripts/test.sh --live`).
private enum LiveHost {
    static let environment = ProcessInfo.processInfo.environment
    static let host = environment["MARIONETTE_TEST_HOST"]
    static let user = environment["MARIONETTE_TEST_USER"] ?? ""
    static let password = environment["MARIONETTE_TEST_PASSWORD"] ?? "password"

    static func request(password: String = password) -> ConnectionRequest {
        ConnectionRequest(
            transport: DirectTransportProvider(peer: Endpoint(host: host ?? "", port: 5900)),
            prompts: StaticPromptHandler(username: user, password: password)
        )
    }
}

/// Gives the same answer every time it is asked, and remembers the questions.
private final class RecordingPrompts: PromptHandler {
    let username: String
    let password: String
    let asked = Mutex<[CredentialRequest]>([])

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
        guard case .credentials(let request) = prompt else { return .cancel }
        asked.withLock { $0.append(request) }
        return .credentials(username: username, password: password)
    }
}

@Suite(.serialized, .enabled(if: LiveHost.host != nil))
struct LiveVNCBackendTests {
    @Test(arguments: BackendConformance.allChecks)
    func aMacAsAPlainVNCServerConforms(check: BackendConformance.Check) async throws {
        let suite = BackendConformance(backend: VNCBackend(), timeout: .seconds(30)) { LiveHost.request() }
        try await suite.run(check)
    }

    @Test func showsTheMacsDesktop() async throws {
        let session = try await VNCBackend().connect(LiveHost.request())
        let display = try #require(session.layout.displays.first)
        #expect(display.pixelSize.width >= 800)
        let frame = try #require(await session.frames(for: display.id).next())
        // A real desktop is not one flat colour.
        let distinct: Int = frame.surface.withUnsafeBuffer { buffer in
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(buffer)!
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            var seen = Set<UInt32>()
            for y in Swift.stride(from: 0, to: CVPixelBufferGetHeight(buffer), by: 16) {
                for x in Swift.stride(from: 0, to: CVPixelBufferGetWidth(buffer), by: 16) {
                    seen.insert(base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt32.self).pointee & 0x00ff_ffff)
                }
            }
            return seen.count
        }
        #expect(distinct > 8)
        await session.disconnect()
    }

    @Test func aWrongPasswordIsRefusedAndAskedForAgain() async {
        let prompts = RecordingPrompts(username: LiveHost.user, password: "definitely-wrong")
        do {
            _ = try await VNCBackend().connect(ConnectionRequest(
                transport: DirectTransportProvider(peer: Endpoint(host: LiveHost.host ?? "", port: 5900)), prompts: prompts
            ))
            Issue.record("connected with a wrong password")
        } catch {
            guard case .authenticationFailed = error else {
                Issue.record("failed as \(error)")
                return
            }
        }
        let asked = prompts.asked.withLock { $0 }
        #expect(asked.map(\.attempt) == [1, 2, 3])
        // A Mac asks for an account, not just a password.
        #expect(asked.first?.kind == .usernameAndPassword)
    }
}
