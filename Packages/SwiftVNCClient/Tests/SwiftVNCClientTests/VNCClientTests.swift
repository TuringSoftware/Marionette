// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import CLibVNCClient
import CoreGraphics
import Foundation
import ImageIO
import SwiftVNCClient
import SwiftVNCClientTestSupport
import Synchronization
import Testing

/// What a client's handlers saw, gathered for assertions.
private final class Observed: Sendable {
    struct State {
        var sizes: [(Int, Int)] = []
        var updates: [[VNCRect]] = []
        var pixels: [UInt8] = []
        var bells = 0
        var cursors: [VNCCursor] = []
        var clipboard: [String] = []
        var disconnects: [VNCDisconnectReason] = []
        var credentialRequests: [VNCCredentialKind] = []
    }

    let state = Mutex(State())
    private let signal = AsyncStream.makeStream(of: Void.self)

    func handlers(credential: VNCCredential? = nil) -> VNCHandlers {
        var handlers = VNCHandlers()
        handlers.credential = { [self] kind in
            state.withLock { $0.credentialRequests.append(kind) }
            return credential
        }
        handlers.resized = { [self] width, height in
            state.withLock { $0.sizes.append((width, height)) }
            signal.continuation.yield()
        }
        handlers.updated = { [self] framebuffer, changed in
            state.withLock { state in
                state.updates.append(changed)
                state.pixels = Array(framebuffer.pixels)
            }
            signal.continuation.yield()
        }
        handlers.bell = { [self] in
            state.withLock { $0.bells += 1 }
            signal.continuation.yield()
        }
        handlers.cursor = { [self] cursor in
            state.withLock { $0.cursors.append(cursor) }
            signal.continuation.yield()
        }
        handlers.clipboard = { [self] text in
            state.withLock { $0.clipboard.append(text) }
            signal.continuation.yield()
        }
        handlers.disconnected = { [self] reason in
            state.withLock { $0.disconnects.append(reason) }
            signal.continuation.yield()
        }
        return handlers
    }

    /// Waits until `condition` holds, failing the test after a few seconds.
    func wait(_ what: String, until condition: @Sendable (State) -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !state.withLock({ condition($0) }) {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@Suite struct VNCClientTests {
    private func start(
        password: String? = nil, credential: VNCCredential? = nil, configuration: VNCConfiguration = VNCConfiguration(),
        server makeServer: (PipeEnd) -> ScriptedServer = { ScriptedServer(end: $0) }
    ) -> (VNCClient, ScriptedServer, Observed, Task<Void, any Error>) {
        let (clientEnd, serverEnd) = PipeEnd.pair()
        let server = password.map { ScriptedServer(end: serverEnd, password: $0) } ?? makeServer(serverEnd)
        let observed = Observed()
        let client = VNCClient(transport: clientEnd, configuration: configuration, handlers: observed.handlers(credential: credential))
        let serving = Task { try await server.run() }
        return (client, server, observed, serving)
    }

    @Test func connectsAndReceivesTheWholeDesktop() async throws {
        let (client, server, observed, _) = start()
        let info = try await client.connect()
        #expect(info == VNCServerInfo(name: "Scripted Desktop", width: 64, height: 48))

        await observed.wait("the first update") { !$0.updates.isEmpty }
        let state = observed.state.withLock { $0 }
        #expect(state.sizes.map { [$0.0, $0.1] } == [[64, 48]])
        #expect(state.updates.first == [VNCRect(x: 0, y: 0, width: 64, height: 48)])
        #expect(state.pixels.count == 64 * 48 * 4)
        // Pixels arrive in the order the framebuffer promises: B, G, R, X.
        for (x, y) in [(0, 0), (63, 0), (10, 20), (63, 47)] {
            let offset = (y * 64 + x) * 4
            #expect(Array(state.pixels[offset..<(offset + 3)]) == Array(ScriptedServer.pixel(x: x, y: y).prefix(3)), "pixel \(x),\(y)")
        }
        #expect(server.recorded.withLock { $0.shared } == true)
        // Tight is asked for first, with its JPEG quality (-32 + 8) and LastRect (-224).
        let encodings = server.recorded.withLock { $0.encodings }
        #expect(encodings.first == 7)
        #expect(encodings.contains(-24))
        #expect(encodings.contains(-224))
        client.disconnect()
        await observed.wait("the disconnect") { !$0.disconnects.isEmpty }
        #expect(observed.state.withLock { $0.disconnects } == [.requested])
    }

    @Test func partialUpdatesChangeOnlyTheirRectangle() async throws {
        let (client, server, observed, _) = start()
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        server.sendUpdate(x: 8, y: 4, width: 16, height: 8, generation: 100)
        client.requestFullUpdate()
        await observed.wait("the partial update") { $0.updates.count >= 2 }
        let state = observed.state.withLock { $0 }
        #expect(state.updates.last == [VNCRect(x: 8, y: 4, width: 16, height: 8)])
        let inside = (5 * 64 + 9) * 4
        let outside = (5 * 64 + 40) * 4
        #expect(state.pixels[inside] == ScriptedServer.pixel(x: 9, y: 5, generation: 100)[0])
        #expect(state.pixels[outside] == ScriptedServer.pixel(x: 40, y: 5)[0])
        client.disconnect()
    }

    @Test func inputReachesTheServerInOrder() async throws {
        let (client, server, observed, _) = start()
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        client.sendPointer(x: 10, y: 20, buttonMask: 0)
        client.sendPointer(x: 10, y: 20, buttonMask: 1)
        client.sendPointer(x: 11, y: 21, buttonMask: 0)
        client.sendKey(keysym: 0x61, isDown: true)
        client.sendKey(keysym: 0x61, isDown: false)
        client.sendKey(keysym: 0xff0d, isDown: true)
        client.sendClipboard("copied here")
        let deadline = ContinuousClock.now + .seconds(5)
        while server.recorded.withLock({ $0.clipboard.isEmpty }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let recorded = server.recorded.withLock { $0 }
        #expect(recorded.pointers.map { [$0.x, $0.y, $0.mask] } == [[10, 20, 0], [10, 20, 1], [11, 21, 0]])
        #expect(recorded.keys.map { "\($0.keysym):\($0.isDown)" } == ["97:true", "97:false", "65293:true"])
        #expect(recorded.clipboard == ["copied here"])
        client.disconnect()
    }

    @Test func bellAndServerClipboardAreReported() async throws {
        let (client, server, observed, _) = start()
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        server.sendBell()
        server.sendCutText("from the server")
        client.requestFullUpdate()
        await observed.wait("bell and clipboard") { $0.bells == 1 && !$0.clipboard.isEmpty }
        #expect(observed.state.withLock { $0.clipboard } == ["from the server"])
        client.disconnect()
    }

    /// LibVNCClient's DES code loads and unloads OpenSSL providers by hand, which would leave the
    /// process without its default algorithms; every later login and SSH tunnel depends on those.
    @Test func aPasswordLoginLeavesTheRestOfOpenSSLWorking() async throws {
        let (client, _, _, _) = start(password: "s3cret", credential: VNCCredential(password: "s3cret"))
        _ = try await client.connect()
        client.disconnect()
        #expect(marionette_vnc_crypto_self_test() == 1)
        #expect(marionette_vnc_crypto_self_test() == 1)
    }

    @Test func passwordAuthentication() async throws {
        let (client, _, observed, _) = start(password: "s3cret", credential: VNCCredential(password: "s3cret"))
        let info = try await client.connect()
        #expect(info.width == 64)
        #expect(observed.state.withLock { $0.credentialRequests } == [.password])
        client.disconnect()
    }

    @Test func wrongPasswordFailsTheConnectWithoutADisconnectEvent() async throws {
        let (client, _, observed, _) = start(password: "s3cret", credential: VNCCredential(password: "wrong"))
        await #expect(throws: VNCError.authenticationRejected(reason: "Authentication failed")) { _ = try await client.connect() }
        try await Task.sleep(for: .milliseconds(100))
        // `disconnected` is for sessions that were connected.
        #expect(observed.state.withLock { $0.disconnects }.isEmpty)
    }

    @Test func decliningToGiveAPasswordFailsTheConnect() async throws {
        let (client, _, _, _) = start(password: "s3cret", credential: nil)
        await #expect(throws: VNCError.self) { _ = try await client.connect() }
    }

    @Test func serverHangingUpIsReported() async throws {
        let (client, server, observed, _) = start()
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        await server.hangUp()
        await observed.wait("the disconnect") { !$0.disconnects.isEmpty }
        #expect(observed.state.withLock { $0.disconnects } == [.connectionClosed])
        // Commands after the end are ignored, not a crash.
        client.sendKey(keysym: 0x61, isDown: true)
        client.disconnect()
    }

    @Test func aBrokenConnectionIsReportedAsLost() async throws {
        let (client, server, observed, _) = start()
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        await server.fail()
        await observed.wait("the disconnect") { !$0.disconnects.isEmpty }
        guard case .connectionLost = observed.state.withLock({ $0.disconnects.first }) else {
            Issue.record("ended as \(observed.state.withLock { $0.disconnects })")
            return
        }
    }

    @Test func dataTheClientCannotReadIsAProtocolError() async throws {
        let (client, server, observed, _) = start()
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        // A rectangle reaching past the 64 × 48 desktop.
        server.send(Data([0, 0, 0, 1, 0, 60, 0, 0, 0, 10, 0, 10, 0, 0, 0, 0]))
        client.requestFullUpdate()
        await observed.wait("the disconnect") { !$0.disconnects.isEmpty }
        guard case .protocolError(let detail) = observed.state.withLock({ $0.disconnects.first }) else {
            Issue.record("ended as \(observed.state.withLock { $0.disconnects })")
            return
        }
        #expect(detail.contains("Rect too large"))
    }

    /// TigerVNC and RealVNC turn clients away for a while after wrong passwords, before asking for one.
    @Test func aServersRefusalKeepsItsReason() async throws {
        let (client, _, _, _) = start { ScriptedServer(end: $0, refusal: .beforeAuthentication("Too many security failures")) }
        await #expect(throws: VNCError.refused(reason: "Too many security failures")) { _ = try await client.connect() }
    }

    @Test func aMacsServerIsRecognised() async throws {
        let (client, _, _, _) = start { ScriptedServer(end: $0, version: "RFB 003.889\n") }
        let info = try await client.connect()
        #expect(info.isAppleScreenSharing)
        #expect(info.majorVersion == 3 && info.minorVersion == 889)
        client.disconnect()
        let (other, _, _, _) = start()
        #expect(try await !other.connect().isAppleScreenSharing)
        other.disconnect()
    }

    /// KDE's KRFB reports 0 × 0 until its screen capture starts.
    @Test func aDesktopThatStartsEmptyIsShownOnceItHasASize() async throws {
        let (client, server, observed, _) = start { ScriptedServer(end: $0, width: 0, height: 0) }
        let info = try await client.connect()
        #expect(info.width == 0 && info.height == 0)
        server.resize(width: 64, height: 48, generation: 0)
        client.requestFullUpdate()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        let state = observed.state.withLock { $0 }
        #expect(state.sizes.map { [$0.0, $0.1] } == [[64, 48]])
        #expect(state.pixels.count == 64 * 48 * 4)
        client.disconnect()
    }

    /// QEMU numbers its one screen 0, which LibVNCClient takes as no screen at all.
    @Test func aServerWhoseScreenIsNumberedZeroCanResize() async throws {
        let (client, server, observed, _) = start { ScriptedServer(end: $0, extendedDesktopSizeScreenID: 0) }
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        // The encodings go again, without ExtendedDesktopSize (-308). The client sends them before
        // it reports the update, but the server may not have read them yet; a resize before it has
        // would still come as ExtendedDesktopSize.
        await waitUntil("the encodings again") { server.recorded.withLock { $0.encodingLists.count >= 2 } }
        let lists = server.recorded.withLock { $0.encodingLists }
        #expect(lists.count == 2)
        #expect(lists.first?.contains(-308) == true)
        #expect(lists.last?.contains(-308) == false)
        #expect(lists.last?.contains(-223) == true)
        server.resize(width: 80, height: 60, generation: 9)
        client.requestFullUpdate()
        await observed.wait("the resized update") { $0.updates.last == [VNCRect(x: 0, y: 0, width: 80, height: 60)] }
        let state = observed.state.withLock { $0 }
        #expect(state.sizes.map { [$0.0, $0.1] } == [[64, 48], [80, 60]])
        #expect(state.disconnects.isEmpty)
        client.disconnect()
    }

    @Test func aServerWithNumberedScreensKeepsExtendedDesktopSize() async throws {
        let (client, server, observed, _) = start { ScriptedServer(end: $0, extendedDesktopSizeScreenID: 1) }
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        server.resize(width: 80, height: 60, generation: 9)
        client.requestFullUpdate()
        await observed.wait("the resized update") { $0.updates.last == [VNCRect(x: 0, y: 0, width: 80, height: 60)] }
        #expect(server.recorded.withLock { $0.encodingLists.count } == 1)
        client.disconnect()
    }

    @Test(arguments: [
        // Many servers send UTF-8 as classic cut text.
        ([0x68, 0xc3, 0xa9], "hé"),
        // Latin-1, as the protocol says.
        ([0x68, 0xe9], "hé"),
        // Windows line ends, and a NUL some servers end with.
        ([0x61, 0x0d, 0x0a, 0x62, 0x00], "a\nb"),
    ] as [([UInt8], String)])
    func classicCutTextIsDecoded(bytes: [UInt8], text: String) async throws {
        let (client, server, observed, _) = start()
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        server.sendCutText(bytes: bytes)
        client.requestFullUpdate()
        await observed.wait("the clipboard") { !$0.clipboard.isEmpty }
        #expect(observed.state.withLock { $0.clipboard } == [text])
        client.disconnect()
    }

    @Test func theExtendedClipboardTravelsBothWays() async throws {
        let (client, server, observed, _) = start { ScriptedServer(end: $0, extendedClipboard: true) }
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        let caps = try #require(server.recorded.withLock { $0.clientClipboardCaps })
        #expect(caps & ExtendedClipboard.text != 0)
        for action in [ExtendedClipboard.request, ExtendedClipboard.peek, ExtendedClipboard.notify, ExtendedClipboard.provide] {
            #expect(caps & action != 0)
        }

        // The server only says it has text; the client asks for it.
        server.announceClipboard("line one\nline two")
        client.requestFullUpdate()
        await observed.wait("the server's clipboard") { !$0.clipboard.isEmpty }
        #expect(observed.state.withLock { $0.clipboard } == ["line one\nline two"])

        // The client says it has text and hands it over when asked: CR LF and a NUL, as the
        // extended clipboard carries text.
        client.sendClipboard("é\nü")
        let deadline = ContinuousClock.now + .seconds(5)
        while server.recorded.withLock({ $0.clipboard.isEmpty }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(server.recorded.withLock { $0.clientClipboardNotifies } == 1)
        #expect(server.recorded.withLock { $0.clipboard } == ["é\r\nü\0"])
        client.disconnect()
    }

    /// Input queued while a large update is arriving goes out between its rectangles, and moves
    /// queued meanwhile collapse into the last one.
    @Test func inputDoesNotWaitForTheRestOfAnUpdate() async throws {
        let (client, server, observed, _) = start()
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        let pointersBefore = server.recorded.withLock { $0.pointers.count }
        server.sendTwoRectanglesWaitingForInput(generation: 5)
        client.requestFullUpdate()
        // The first rectangle is half sent now; the client is reading the rest.
        try await Task.sleep(for: .milliseconds(80))
        for x in 0..<30 { client.sendPointer(x: x, y: 7, buttonMask: 0) }
        client.sendKey(keysym: 0x61, isDown: true)
        await observed.wait("the update") { $0.updates.count >= 2 }
        let recorded = server.recorded.withLock { $0 }
        #expect(recorded.inputArrivedBetweenRectangles == true)
        #expect(recorded.pointers.dropFirst(pointersBefore).map { [$0.x, $0.y] } == [[29, 7]])
        client.disconnect()
    }

    @Test func tightJPEGRectanglesAreDecoded() async throws {
        let (client, server, observed, _) = start()
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        let jpeg = try #require(Self.jpeg(width: 16, height: 8, red: 200, green: 100, blue: 40))
        // Tight, compression control 0x90 (JPEG), then the length in Tight's compact form.
        var message = Data([0, 0, 0, 1, 0, 4, 0, 2, 0, 16, 0, 8, 0, 0, 0, 7, 0x90])
        message.append(contentsOf: jpeg.count < 128 ? [UInt8(jpeg.count)] : [UInt8(jpeg.count & 0x7f | 0x80), UInt8(jpeg.count >> 7)])
        message.append(jpeg)
        server.send(message)
        client.requestFullUpdate()
        await observed.wait("the JPEG") { $0.updates.last == [VNCRect(x: 4, y: 2, width: 16, height: 8)] }
        let pixels = observed.state.withLock { $0.pixels }
        let inside = Array(pixels[((5 * 64 + 10) * 4)..<((5 * 64 + 10) * 4 + 3)])
        // B, G, R; JPEG is lossy, a little.
        for (got, want) in zip(inside, [40, 100, 200]) { #expect(abs(Int(got) - want) <= 6, "\(inside)") }
        #expect(pixels[(1 * 64 + 1) * 4] == ScriptedServer.pixel(x: 1, y: 1)[0])
        client.disconnect()
    }

    @Test func aJPEGOfTheWrongSizeIsRefused() throws {
        let jpeg = try #require(Self.jpeg(width: 16, height: 8, red: 1, green: 2, blue: 3))
        var pixels = [UInt8](repeating: 0, count: 32 * 8 * 4)
        let decoded = jpeg.withUnsafeBytes { marionette_vnc_decode_jpeg($0.baseAddress, UInt(jpeg.count), &pixels, 32, 8, 32 * 4, 1) }
        #expect(decoded == 0)
        let garbage = [UInt8](repeating: 0x42, count: 64)
        #expect(marionette_vnc_decode_jpeg(garbage, UInt(garbage.count), &pixels, 16, 8, 32 * 4, 1) == 0)
    }

    static func jpeg(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8) -> Data? {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for index in 0..<(width * height) {
            pixels[index * 4] = red
            pixels[index * 4 + 1] = green
            pixels[index * 4 + 2] = blue
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let image = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    @Test func aServerThatIsNotVNCFailsTheConnect() async throws {
        let (clientEnd, serverEnd) = PipeEnd.pair()
        let client = VNCClient(transport: clientEnd, handlers: VNCHandlers())
        try await serverEnd.write(Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8))
        await serverEnd.close()
        await #expect(throws: VNCError.self) { _ = try await client.connect() }
        await #expect(throws: VNCError.alreadyStarted) { _ = try await client.connect() }
    }

    @Test func manySessionsOneAfterAnotherLeaveNothingBehind() async throws {
        let before = openDescriptorCount()
        for _ in 0..<25 {
            let (client, _, observed, _) = start()
            _ = try await client.connect()
            await observed.wait("the first update") { !$0.updates.isEmpty }
            client.disconnect()
            await observed.wait("the disconnect") { !$0.disconnects.isEmpty }
        }
        // Each session uses a socket pair, a pipe and a copy of one end; none may outlive it. The
        // count is the whole process's, and other tests open sessions alongside this one, so it
        // waits for theirs to settle and allows fewer than one descriptor per session here: a
        // leak in this path leaves at least 25.
        var settled = false
        for _ in 0..<50 where !settled {
            settled = openDescriptorCount() < before + 25
            if !settled { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(settled, "\(openDescriptorCount() - before) more descriptors open than before")
    }

    // MARK: Quality

    /// The JPEG quality pseudo-encodings, -32 (quality 0) to -23 (quality 9).
    private static func qualities(in encodings: [Int32]) -> [Int32] {
        encodings.filter { (-32)...(-23) ~= $0 }.map { $0 + 32 }
    }

    @Test func aFullQualitySessionAsksForNoJPEG() async throws {
        var configuration = VNCConfiguration()
        configuration.quality = .lossless
        let (client, server, observed, _) = start(configuration: configuration)
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        let recorded = server.recorded.withLock { $0 }
        #expect(Self.qualities(in: recorded.encodings).isEmpty)
        #expect(recorded.encodings.first == 7, "Tight is still asked for first, losslessly")
        #expect(recorded.pixelFormats == [32])
        client.disconnect()
    }

    @Test func choosingFullQualityDropsJPEGAtOnce() async throws {
        let (client, server, observed, _) = start()
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        #expect(Self.qualities(in: server.recorded.withLock { $0.encodings }) == [8])
        // No update is needed for it to go out.
        client.setQuality(.lossless)
        await waitUntil("JPEG is no longer asked for") { Self.qualities(in: server.recorded.withLock { $0.encodings }).isEmpty }
        client.setQuality(.automatic)
        await waitUntil("JPEG is asked for again") { Self.qualities(in: server.recorded.withLock { $0.encodings }) == [8] }
        #expect(server.recorded.withLock { $0.pixelFormats } == [32])
        client.disconnect()
    }

    /// A slow link: quality 6 from the start, then 256 colours from the first update on, switched
    /// while no request is outstanding, decoded into the same B, G, R, X framebuffer; then full
    /// colour again, with the whole desktop asked for anew.
    @Test func aSlowLinkGetsLowerQualityAnd256ColoursUntilFullIsChosen() async throws {
        var configuration = VNCConfiguration()
        // A quick update raises the estimate by about eight bit/s per byte it carries (its weight
        // grows with its time as its rate falls), so the test's updates, about 13 kB in all, leave
        // it far below 256 kbit/s.
        configuration.initialBitsPerSecond = 1_000
        let (client, server, observed, _) = start(configuration: configuration)
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        #expect(Self.qualities(in: server.recorded.withLock { $0.encodingLists.first ?? [] }) == [6])
        await waitUntil("256 colours are asked for") {
            server.recorded.withLock { $0.pixelFormats.last == 8 && $0.updateRequests >= 2 }
        }
        // JPEG is not asked for in 256 colours: Tight has none there.
        #expect(Self.qualities(in: server.recorded.withLock { $0.encodings }).isEmpty)

        try await server.paint(x: 8, y: 4, width: 16, height: 8, generation: 100)
        await observed.wait("the update in 256 colours") { $0.updates.count >= 2 }
        var pixels = observed.state.withLock { $0.pixels }
        let inside = (5 * 64 + 9) * 4
        let outside = (5 * 64 + 40) * 4
        #expect(Array(pixels[inside..<(inside + 3)]) == ScriptedServer.lowColourPixel(x: 9, y: 5, generation: 100))
        #expect(Array(pixels[outside..<(outside + 3)]) == Array(ScriptedServer.pixel(x: 40, y: 5).prefix(3)), "what has not changed keeps its colours")

        await waitUntil("the next request") { server.recorded.withLock { $0.updateRequests >= 3 } }
        try await server.changeCursor(width: 4, height: 3)
        await observed.wait("the cursor in 256 colours") { !$0.cursors.isEmpty }
        let cursor = try #require(observed.state.withLock { $0.cursors.last })
        #expect(cursor.width == 4 && cursor.height == 3 && cursor.hotspotX == 1 && cursor.hotspotY == 2)
        #expect(Array(cursor.pixels.prefix(4)) == ScriptedServer.lowColourPixel(x: 1, y: 1) + [255])

        client.setQuality(.lossless)
        await waitUntil("the request after the cursor") { server.recorded.withLock { $0.updateRequests >= 4 } }
        // The switch back waits for an update to start: this one still comes in 256 colours.
        try await server.paint(x: 0, y: 0, width: 4, height: 4, generation: 200)
        await waitUntil("full colour is asked for, then the whole desktop") {
            server.recorded.withLock { $0.pixelFormats.last == 32 && $0.incrementalRequests.last == false }
        }
        pixels = observed.state.withLock { $0.pixels }
        #expect(Array(pixels[0..<3]) == ScriptedServer.lowColourPixel(x: 0, y: 0, generation: 200))

        let updatesBefore = observed.state.withLock { $0.updates.count }
        try await server.paint(x: 0, y: 0, width: 4, height: 4, generation: 300)
        await observed.wait("the update in full colour") { $0.updates.count > updatesBefore }
        pixels = observed.state.withLock { $0.pixels }
        #expect(Array(pixels[4..<8]) == ScriptedServer.pixel(x: 1, y: 0, generation: 300))
        #expect(server.recorded.withLock { $0.pixelFormatsWithRequestOutstanding } == 0)
        #expect(server.recorded.withLock { $0.requestsWhileOneWasOutstanding } == 0)
        #expect(observed.state.withLock { $0.disconnects }.isEmpty)
        client.disconnect()
    }

    /// A request beside the one outstanding may be answered with one update or two, so an update in
    /// the old format could follow a change of depth: the depth stays as it is.
    @Test func afterAnExtraRequestTheColourDepthStays() async throws {
        var configuration = VNCConfiguration()
        configuration.quality = .lossless
        configuration.initialBitsPerSecond = 1_000
        let (client, server, observed, _) = start(configuration: configuration)
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        client.requestFullUpdate()
        await waitUntil("the extra request") { server.recorded.withLock { $0.requestsWhileOneWasOutstanding == 1 } }
        client.setQuality(.automatic)
        await waitUntil("quality 6 is asked for") { Self.qualities(in: server.recorded.withLock { $0.encodings }) == [6] }
        for generation in 1...3 {
            try await server.paint(x: 0, y: 0, width: 4, height: 4, generation: generation)
            await observed.wait("update \(generation)") { $0.updates.count > generation }
        }
        #expect(server.recorded.withLock { $0.pixelFormats } == [32])
        #expect(Array(observed.state.withLock { $0.pixels }[0..<4]) == ScriptedServer.pixel(x: 0, y: 0, generation: 3))
        client.disconnect()
    }

    /// A Mac's server ends the session when asked for 8 bits a pixel.
    @Test func aMacsServerStaysInFullColourOnASlowLink() async throws {
        var configuration = VNCConfiguration()
        configuration.initialBitsPerSecond = 1_000
        let (client, server, observed, _) = start(configuration: configuration, server: { ScriptedServer(end: $0, version: "RFB 003.889\n") })
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        try await server.paint(x: 0, y: 0, width: 4, height: 4, generation: 1)
        await observed.wait("the second update") { $0.updates.count >= 2 }
        #expect(server.recorded.withLock { $0.pixelFormats } == [32])
        #expect(Self.qualities(in: server.recorded.withLock { $0.encodings }) == [6])
        client.disconnect()
    }

    /// LibVNCClient sets its own copy of the JPEG quality to 9 whenever a ZRLE rectangle arrives.
    @Test func aZRLEPictureDoesNotChangeTheQualityAskedFor() async throws {
        let (client, server, observed, _) = start(server: { ScriptedServer(end: $0, firstFrameInZRLE: true) })
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        let offset = (20 * 64 + 10) * 4
        let pixels = observed.state.withLock { $0.pixels }
        try #require(pixels.count == 64 * 48 * 4)
        #expect(Array(pixels[offset..<(offset + 3)]) == Array(ScriptedServer.pixel(x: 10, y: 20).prefix(3)))
        // Without ExtendedDesktopSize the encodings go again after the first update.
        await waitUntil("the encodings again") { server.recorded.withLock { $0.encodingLists.count >= 2 } }
        #expect(Self.qualities(in: server.recorded.withLock { $0.encodings }) == [8])
        client.disconnect()
    }

    @Test func republishingHandsOverTheDesktopWithoutAskingTheServer() async throws {
        let (client, server, observed, _) = start()
        _ = try await client.connect()
        await observed.wait("the first update") { !$0.updates.isEmpty }
        await waitUntil("the request after the first update") { server.isRequestOutstanding }
        let requests = server.recorded.withLock { $0.updateRequests }
        client.republish()
        await observed.wait("the desktop again") { $0.updates.count == 2 }
        #expect(observed.state.withLock { $0.updates.last } == [VNCRect(x: 0, y: 0, width: 64, height: 48)])
        #expect(server.recorded.withLock { $0.updateRequests } == requests)
        client.disconnect()
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out waiting until \(what)")
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func openDescriptorCount() -> Int {
        (0..<1024).filter { fcntl(Int32($0), F_GETFD) != -1 }.count
    }
}
