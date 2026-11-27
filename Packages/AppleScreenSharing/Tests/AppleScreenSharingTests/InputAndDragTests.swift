// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
@testable import AppleScreenSharing
import Foundation
import RemoteDesktopCore
import Synchronization
import Testing

private func connect(
    _ options: ScriptedMac.Options = ScriptedMac.Options(), configure: (inout AppleScreenSharingBackend) -> Void = { _ in }
) async throws -> (session: any RemoteSession, mac: ScriptedMac) {
    let transport = ScriptedMacTransport(options: options)
    var backend = AppleScreenSharingBackend()
    backend.sessionTiming.inputSettlingTime = .zero
    configure(&backend)
    let session = try await backend.connect(ScriptedMacTests.standardRequest(transport))
    return (session, transport.latest)
}

private extension ScriptedMac {
    var inputTraffic: [Received] {
        record.withLock { record in
            record.messages.filter {
                switch $0 {
                case .key, .pointer, .drag, .dragRequest: true
                default: false
                }
            }
        }
    }

    var sealedInput: [SealedInput] { record.withLock { $0.sealedInput } }
}

private extension RemoteSession {
    func point(_ x: Double, _ y: Double, _ buttons: PointerButtons = []) throws {
        let display = try #require(layout.displays.first)
        input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: x, y: y), buttons: buttons, layoutGeneration: layout.generation)))
    }

    func key(_ key: KeyCode, _ characters: String? = nil, _ phase: KeyEvent.Phase) {
        input.send(.key(KeyEvent(key: key, characters: characters, charactersIgnoringModifiers: characters, phase: phase)))
    }
}

/// Keys and pointer events as `EncryptedInputEvent` messages, which is how Screen Sharing.app
/// sends every one of them, and as plain ones wherever the sealed kind cannot be used.
@Suite struct ScriptedEncryptedInputTests {
    /// No flag is set on any of it: the Mac then counts clicks itself, from the elapsed times, and
    /// maps a key by its keysym, as it does for the plain messages.
    @Test func inputGoesSealedToAMacThatTakesIt() async throws {
        let (session, mac) = try await connect()
        try session.point(10, 20)
        try session.point(10, 20, .primary)
        try session.point(12, 22, .primary)
        try session.point(12, 22)
        session.key(.a, "a", .down)
        session.key(.a, "a", .up)
        session.key(.leftCommand, nil, .down)
        session.key(.leftCommand, nil, .up)
        await until("the input") { mac.sealedInput.count >= 8 }

        let sealed = mac.sealedInput
        #expect(sealed.map(\.event) == [
            .pointer(mask: 0, x: 10, y: 20), .pointer(mask: 1, x: 10, y: 20), .pointer(mask: 1, x: 12, y: 22), .pointer(mask: 0, x: 12, y: 22),
            .key(keysym: 0x61, isDown: true), .key(keysym: 0x61, isDown: false),
            .key(keysym: 0xffeb, isDown: true), .key(keysym: 0xffeb, isDown: false),
        ])
        #expect(sealed.allSatisfy { $0.flags == EncryptedInputEvent.plainFlags })
        // Nothing went plain as well.
        #expect(mac.inputTraffic == sealed.map(\.event))
        // Where Screen Sharing.app names its keyboard and the key's code, this client names none.
        for key in sealed.suffix(4) { #expect(key.block.suffix(6) == Data(count: 6)) }
        await session.disconnect()
    }

    /// Each event says how long ago the one before it was sent, in microseconds. A Mac sent no
    /// click count tells a double click from two clicks by these times.
    @Test func eachEventCarriesTheTimeSinceTheOneBefore() async throws {
        let (session, mac) = try await connect()
        session.key(.a, "a", .down)
        try await Task.sleep(for: .milliseconds(60))
        session.key(.a, "a", .up)
        try await Task.sleep(for: .milliseconds(120))
        try session.point(5, 6)
        await until("the input") { mac.sealedInput.count >= 3 }
        let elapsed = mac.sealedInput.map(\.elapsedMicroseconds)
        // A sleep never ends early, and on a busy host it may end late.
        #expect((60_000..<2_000_000).contains(elapsed[1]), "\(elapsed)")
        #expect((120_000..<2_000_000).contains(elapsed[2]), "\(elapsed)")
        await session.disconnect()
    }

    /// The modes share the record layer and its key, so High Performance seals input the same way.
    @Test func highPerformanceSealsInputToo() async throws {
        let transport = ScriptedHighPerformanceTests.transport()
        var backend = ScriptedHighPerformanceTests.backend
        backend.sessionTiming.inputSettlingTime = .zero
        backend.sessionTiming.displayChangeInputHold = .zero
        let session = try await backend.connect(ScriptedHighPerformanceTests.request(transport))
        let mac = transport.latest
        #expect(session.info.mode == .highPerformance)
        #expect(session.capabilities.fileDrag.isAvailable)
        try session.point(40, 30, .primary)
        try session.point(40, 30)
        session.key(.a, "a", .down)
        session.key(.a, "a", .up)
        await until("the input") { mac.sealedInput.count >= 4 }
        #expect(mac.sealedInput.map(\.event) == [
            .pointer(mask: 1, x: 40, y: 30), .pointer(mask: 0, x: 40, y: 30), .key(keysym: 0x61, isDown: true), .key(keysym: 0x61, isDown: false),
        ])
        #expect(mac.sealedInput.allSatisfy { $0.flags == EncryptedInputEvent.plainFlags })
        #expect(mac.inputTraffic == mac.sealedInput.map(\.event))
        await session.disconnect()
    }

    private static func sendsPlainInput(_ session: any RemoteSession, to mac: ScriptedMac) async throws {
        try session.point(10, 20, .primary)
        try session.point(10, 20)
        session.key(.a, "a", .down)
        session.key(.a, "a", .up)
        let expected: [ScriptedMac.Received] = [
            .pointer(mask: 1, x: 10, y: 20), .pointer(mask: 0, x: 10, y: 20), .key(keysym: 0x61, isDown: true), .key(keysym: 0x61, isDown: false),
        ]
        await until("the input") { mac.inputTraffic.count >= expected.count }
        #expect(mac.inputTraffic == expected)
        #expect(mac.sealedInput.isEmpty)
        // A Mac starts a viewer's drag only when that viewer's pointer events are sealed.
        #expect(session.capabilities.fileDrag.unavailableReason == .notSupportedByServer)
        #expect(session.state == .connected)
    }

    /// The bitmap in the Mac's initialisation says which messages it takes. One without `0x10`
    /// (an older macOS, wayshare) would drop the connection at the first sealed event.
    @Test func aServerThatDoesNotTakeSealedInputGetsPlainEvents() async throws {
        var options = ScriptedMac.Options()
        options.takesEncryptedInput = false
        let (session, mac) = try await connect(options)
        #expect(session.info.isEncrypted)
        try await Self.sendsPlainInput(session, to: mac)
        await session.disconnect()
    }

    /// After a VNC-password login there is no record layer, so no key to seal with, whatever the
    /// Mac's bitmap says.
    @Test func aSessionInClearSendsPlainEvents() async throws {
        var options = ScriptedMac.Options()
        options.securityTypes = [2]
        let (session, mac) = try await connect(options)
        #expect(!session.info.isEncrypted)
        try await Self.sendsPlainInput(session, to: mac)
        await session.disconnect()
    }

    @Test func sealingCanBeSwitchedOffForExperiments() async throws {
        let (session, mac) = try await connect { $0.sessionTiming.encryptsInput = false }
        #expect(session.info.isEncrypted)
        try await Self.sendsPlainInput(session, to: mac)
        await session.disconnect()
    }

    /// Releases at teardown are input like any other: sealed where the presses were.
    @Test func keysLetGoAtTheEndAreSealedLikeThePresses() async throws {
        let (session, mac) = try await connect()
        session.key(.leftShift, nil, .down)
        try session.point(7, 8, .primary)
        await until("the presses") { mac.sealedInput.count >= 2 }
        await session.disconnect()
        // The session has sent the releases; the Mac reads them in its own time.
        await until("the releases") { mac.inputTraffic.count >= 4 }
        let sealed = mac.sealedInput
        #expect(sealed.suffix(2).contains { $0.event == .key(keysym: 0xffe1, isDown: false) })
        #expect(sealed.suffix(2).contains { $0.event == .pointer(mask: 0, x: 7, y: 8) })
        #expect(mac.inputTraffic == sealed.map(\.event))
    }
}

/// Drags of files into the Mac's picture and out of it, against a Mac scripted to do what macOS
/// 27.0.1 was seen to do (Docs/protocol/apple-screen-sharing.md, "Dragging files").
@Suite struct ScriptedFileDragTests {
    static let silentMac: ScriptedMac.Options = {
        var options = ScriptedMac.Options()
        options.dropFolder = nil
        return options
    }()

    private static func drags(_ session: any RemoteSession) throws -> (any FileDragAndDrop, DisplayID) {
        (try #require(session.capabilities.fileDrag.value), try #require(session.layout.displays.first).id)
    }

    // MARK: From this device to the Mac

    /// The order a Mac needs: the pointer where the drag enters with no button down, the drag's
    /// names, the press that makes the Mac start a drag of its own there, the moves, the release.
    @Test func aDragInIsAnnouncedBetweenAMoveAndAPressAndDroppedByTheRelease() async throws {
        let (session, mac) = try await connect()
        let (drags, display) = try Self.drags(session)
        let drag = try drags.beginDrag(names: ["notes.txt", "Report 2026 ünï.pdf"], at: PixelPoint(x: 10, y: 20), on: display)
        drag.move(to: PixelPoint(x: 14, y: 22), on: display)
        drag.move(to: PixelPoint(x: 30, y: 31), on: display)
        #expect(try await drag.drop() == "/Users/tester/Desktop")

        let traffic = mac.inputTraffic
        guard traffic.count == 6, case .drag(let token, let names) = traffic[1] else {
            Issue.record("the Mac saw \(traffic)")
            return
        }
        #expect(names == ["notes.txt", "Report 2026 ünï.pdf"])
        // Not the token of the Mac's own drags, nor nothing.
        #expect(token > ScriptedMac.ownDragToken)
        #expect(traffic == [
            .pointer(mask: 0, x: 10, y: 20), .drag(token: token, names: names), .pointer(mask: 1, x: 10, y: 20),
            .pointer(mask: 1, x: 14, y: 22), .pointer(mask: 1, x: 30, y: 31), .pointer(mask: 0, x: 30, y: 31),
        ])
        #expect(mac.record.withLock { $0.namedDrops } == [token])
        // Every pointer event of it sealed: a Mac ignores the drag of a viewer whose are plain.
        #expect(mac.sealedInput.count == 5)
        await #expect(throws: FileDragError.notAccepted) { _ = try await drag.drop() }
        #expect(mac.inputTraffic == traffic)
        await session.disconnect()
    }

    /// Over an app's window or the Dock a Mac says nothing at all, so silence is the refusal.
    @Test func aDropTheMacDoesNotAnswerIsNotAccepted() async throws {
        let limit = Duration.milliseconds(300)
        let (session, mac) = try await connect(Self.silentMac) { $0.sessionTiming.dropAnswerLimit = limit }
        let (drags, display) = try Self.drags(session)
        let drag = try drags.beginDrag(names: ["notes.txt"], at: PixelPoint(x: 10, y: 20), on: display)
        let started = ContinuousClock.now
        await #expect(throws: FileDragError.notAccepted) { _ = try await drag.drop() }
        let waited = ContinuousClock.now - started
        #expect(waited >= limit - .milliseconds(20), "gave up after \(waited)")
        #expect(waited < limit + .seconds(3), "gave up after \(waited)")
        #expect(mac.inputTraffic.last == .pointer(mask: 0, x: 10, y: 20))
        try drags.beginDrag(names: ["again.txt"], at: PixelPoint(x: 1, y: 2), on: display).cancel()
        await session.disconnect()
    }

    /// A Mac discards input just after the login, so the session holds it, the release included.
    /// The Mac's time to answer starts when the release reaches it, not when the drop was asked for.
    @Test func aDropMadeWhileInputIsHeldWaitsForItsAnswerFromTheRelease() async throws {
        let limit = Duration.milliseconds(200)
        let (session, mac) = try await connect {
            $0.sessionTiming.inputSettlingTime = .seconds(2)
            $0.sessionTiming.dropAnswerLimit = limit
        }
        let (drags, display) = try Self.drags(session)
        let drag = try drags.beginDrag(names: ["notes.txt"], at: PixelPoint(x: 10, y: 20), on: display)
        #expect(mac.inputTraffic.isEmpty, "the drag reached the Mac while it would have been discarded")
        let started = ContinuousClock.now
        #expect(try await drag.drop() == "/Users/tester/Desktop")
        // Longer than the Mac is given once it has the release: the hold was not counted against it.
        #expect(ContinuousClock.now - started > limit)
        #expect(mac.inputTraffic.count == 4)
        await session.disconnect()
    }

    /// A viewer that only watches sends no pointer events, so a drag of its could never move or
    /// be let go: none is begun, and nothing of it is sent.
    @Test func noDragBeginsWhileOnlyObserving() async throws {
        let (session, mac) = try await connect()
        let (drags, display) = try Self.drags(session)
        let control = try #require(session.capabilities.control.value)
        try await control.setControlMode(.observe)
        #expect(throws: FileDragError.notAccepted) { _ = try drags.beginDrag(names: ["notes.txt"], at: PixelPoint(x: 10, y: 20), on: display) }
        try await control.setControlMode(.control)
        // The refusal left no drag behind to be busy with.
        let drag = try drags.beginDrag(names: ["notes.txt"], at: PixelPoint(x: 10, y: 20), on: display)
        #expect(try await drag.drop() == "/Users/tester/Desktop")
        #expect(mac.inputTraffic.count == 4, "\(mac.inputTraffic)")
        await session.disconnect()
    }

    /// The token ties the Mac's answer to the drag: a folder named for another drag is not this
    /// one's, and this one's is taken whenever within the limit it comes.
    @Test func onlyTheAnswerWithTheDragsTokenIsItsFolder() async throws {
        let (session, mac) = try await connect(Self.silentMac)
        let (drags, display) = try Self.drags(session)
        let drag = try drags.beginDrag(names: ["notes.txt"], at: PixelPoint(x: 10, y: 20), on: display)
        let dropped = Task { try await drag.drop() }
        // The press and the release: the drag's first event, the move it enters with, is the
        // release's twin.
        await until("the release") { mac.inputTraffic.suffix(2) == [.pointer(mask: 1, x: 10, y: 20), .pointer(mask: 0, x: 10, y: 20)] }
        guard case .drag(let token, _)? = mac.inputTraffic.dropFirst().first else {
            Issue.record("the Mac saw \(mac.inputTraffic)")
            return
        }
        mac.send(DropDestination(token: token ^ 1, path: "/Users/tester/Elsewhere").encoded())
        try await Task.sleep(for: .milliseconds(200))
        mac.send(DropDestination(token: token, path: "/Users/tester/Documents/ünï").encoded())
        #expect(try await dropped.value == "/Users/tester/Documents/ünï")
        await session.disconnect()
    }

    /// A drag that leaves the picture is called off with an empty announcement before the button
    /// comes up, so the Mac drops nothing where the pointer was.
    @Test func cancellingAnnouncesTheEndBeforeTheRelease() async throws {
        let (session, mac) = try await connect()
        let (drags, display) = try Self.drags(session)
        let drag = try drags.beginDrag(names: ["notes.txt"], at: PixelPoint(x: 10, y: 20), on: display)
        drag.move(to: PixelPoint(x: 14, y: 22), on: display)
        drag.cancel()
        // A key after it, to know the Mac has dealt with everything before.
        session.key(.a, "a", .down)
        session.key(.a, "a", .up)
        await until("the key") { mac.inputTraffic.last == .key(keysym: 0x61, isDown: false) }
        let traffic = mac.inputTraffic
        #expect(traffic.dropFirst(4).prefix(2) == [.drag(token: 0, names: []), .pointer(mask: 0, x: 14, y: 22)], "\(traffic)")
        #expect(mac.record.withLock { $0.namedDrops }.isEmpty)

        drag.cancel()
        drag.move(to: PixelPoint(x: 40, y: 40), on: display)
        await #expect(throws: FileDragError.notAccepted) { _ = try await drag.drop() }
        #expect(mac.inputTraffic == traffic)
        let next = try drags.beginDrag(names: ["next.txt"], at: PixelPoint(x: 3, y: 4), on: display)
        #expect(try await next.drop() == "/Users/tester/Desktop")
        await session.disconnect()
    }

    /// The Mac holds one drag for a viewer, under the one pointer.
    @Test func aSecondDragWhileOneIsUnderWayIsBusy() async throws {
        let (session, mac) = try await connect()
        let (drags, display) = try Self.drags(session)
        let first = try drags.beginDrag(names: ["one.txt"], at: PixelPoint(x: 10, y: 20), on: display)
        #expect(throws: FileDragError.busy) { _ = try drags.beginDrag(names: ["two.txt"], at: PixelPoint(x: 50, y: 40), on: display) }
        _ = try await first.drop()
        #expect(mac.inputTraffic.count == 4)
        #expect(mac.record.withLock { $0.namedDrops }.count == 1)
        let second = try drags.beginDrag(names: ["two.txt"], at: PixelPoint(x: 50, y: 40), on: display)
        #expect(try await second.drop() == "/Users/tester/Desktop")
        await session.disconnect()
    }

    /// A drop waiting for the Mac's answer when the session ends is told so at once, not after
    /// the wait; and the capability a front end still holds starts nothing more.
    @Test(arguments: [true, false])
    func theSessionEndingFailsAWaitingDrop(macHangsUp: Bool) async throws {
        let (session, mac) = try await connect(Self.silentMac)
        let (drags, display) = try Self.drags(session)
        let drag = try drags.beginDrag(names: ["notes.txt"], at: PixelPoint(x: 10, y: 20), on: display)
        let dropped = Task { try await drag.drop() }
        await until("the release") { mac.inputTraffic.suffix(2) == [.pointer(mask: 1, x: 10, y: 20), .pointer(mask: 0, x: 10, y: 20)] }
        let ended = ContinuousClock.now
        if macHangsUp {
            await mac.hangUp()
        } else {
            await session.disconnect()
        }
        let outcome = await dropped.result
        #expect(throws: FileDragError.sessionEnded) { try outcome.get() }
        #expect(ContinuousClock.now - ended < SessionTiming().dropAnswerLimit - .seconds(1))
        #expect(throws: FileDragError.sessionEnded) { _ = try drags.beginDrag(names: ["late.txt"], at: PixelPoint(x: 1, y: 1), on: display) }
        await session.disconnect()
    }

    // MARK: From the Mac to this device

    /// Stands in for the picture Finder sends: the client passes it on unread.
    static let picture = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data((0..<200).map { UInt8($0) })

    /// Collects what a subscription yields, so a test can wait for a value without hanging on one
    /// that never comes.
    private final class Watcher: Sendable {
        let seen = Mutex<[RemoteFileDrag?]>([])
        let isFinished = Mutex(false)

        init(_ stream: AsyncStream<RemoteFileDrag?>) {
            Task {
                for await drag in stream { seen.withLock { $0.append(drag) } }
                isFinished.withLock { $0 = true }
            }
        }

        var values: [RemoteFileDrag?] { seen.withLock { $0 } }
    }

    /// A Mac announces a drag of files as soon as one starts under the viewer's pointer, unasked,
    /// and says so again, empty, when the button has come up.
    @Test func aDragOnTheMacIsReportedWithItsPictureAndThenItsEnd() async throws {
        let (session, mac) = try await connect()
        let (drags, _) = try Self.drags(session)
        let watcher = Watcher(drags.remoteDrags())
        // The press and the first movement that make Finder start a drag.
        try session.point(50, 20, .primary)
        try session.point(46, 22, .primary)
        await until("the press") { mac.inputTraffic.count == 2 }
        #expect(mac.beginDrag(paths: ["/Users/tester/Desktop/a b.txt", "/Users/tester/Documents/ünï.pdf"], picturePNG: Self.picture))
        await until("the drag") { watcher.values.count == 1 }
        let expected = RemoteFileDrag(paths: ["/Users/tester/Desktop/a b.txt", "/Users/tester/Documents/ünï.pdf"], previewPNG: Self.picture)
        #expect(watcher.values == [expected])

        let late = Watcher(drags.remoteDrags())
        await until("the drag, replayed") { late.values.count == 1 }
        #expect(late.values == [expected])

        try session.point(20, 30, .primary)
        try session.point(20, 30)
        await until("the end") { watcher.values.count == 2 && late.values.count == 2 }
        #expect(watcher.values == [expected, nil])
        // Nothing but the pointer was sent to the Mac: watching a drag is not taking it.
        #expect(mac.inputTraffic.count == 4 && mac.inputTraffic.allSatisfy { if case .pointer = $0 { true } else { false } })

        await session.disconnect()
        await until("the streams to finish") { watcher.isFinished.withLock { $0 } && late.isFinished.withLock { $0 } }
    }

    /// Taking the drag over tells the Mac it is over there (an empty announcement from the
    /// viewer): the Mac cancels its drag, the files stay where they were and are fetched by path.
    @Test func takingTheMacsDragEndsItOnTheMac() async throws {
        let (session, mac) = try await connect()
        let (drags, _) = try Self.drags(session)
        let watcher = Watcher(drags.remoteDrags())
        try session.point(50, 20, .primary)
        try session.point(46, 22, .primary)
        await until("the press") { mac.inputTraffic.count == 2 }
        #expect(mac.beginDrag(paths: ["/Users/tester/Desktop/notes.txt"], picturePNG: Self.picture))
        await until("the drag") { watcher.values.count == 1 }
        drags.takeRemoteDrag()
        await until("the empty announcement") { mac.inputTraffic.count == 3 }
        #expect(mac.inputTraffic.last == .drag(token: 0, names: []))
        await until("the end") { watcher.values.count == 2 }
        #expect(watcher.values.last == .some(nil))
        try session.point(46, 22)
        mac.sendBell()
        try await Task.sleep(for: .milliseconds(200))
        #expect(watcher.values.compactMap { $0 }.count == 1)
        #expect(watcher.values.last == .some(nil))
        #expect(session.state == .connected)
        await session.disconnect()
    }

    /// A Mac tells of a drag only the viewer it has marked as its owner: the one whose pointer
    /// event had exactly the left button down. A right-button drag is not one of files to take.
    @Test func onlyAViewerHoldingTheLeftButtonIsToldOfADrag() async throws {
        let (session, mac) = try await connect()
        let (drags, _) = try Self.drags(session)
        let watcher = Watcher(drags.remoteDrags())
        try session.point(50, 20)
        await until("the move") { mac.inputTraffic.count == 1 }
        #expect(!mac.beginDrag(paths: ["/Users/tester/Desktop/notes.txt"], picturePNG: Self.picture))
        try session.point(50, 20, .secondary)
        await until("the right press") { mac.inputTraffic.count == 2 }
        #expect(mac.inputTraffic.last == .pointer(mask: 2, x: 50, y: 20))
        #expect(!mac.beginDrag(paths: ["/Users/tester/Desktop/notes.txt"], picturePNG: Self.picture))
        try session.point(50, 20)
        try session.point(50, 20, .primary)
        await until("the left press") { mac.inputTraffic.count == 4 }
        #expect(mac.beginDrag(paths: ["/Users/tester/Desktop/notes.txt"], picturePNG: Self.picture))
        await until("the drag") { watcher.values.count == 1 }
        #expect(watcher.values.first??.paths == ["/Users/tester/Desktop/notes.txt"])
        await session.disconnect()
    }

    /// Plain pointer events never mark a viewer as a drag's owner, so a session that cannot seal
    /// its input is never told of one: the other half of why the capability needs sealed input.
    @Test func aViewerWhoseInputIsPlainIsNeverToldOfADrag() async throws {
        let (session, mac) = try await connect { $0.sessionTiming.encryptsInput = false }
        #expect(!session.capabilities.fileDrag.isAvailable)
        let core = try #require((session as? ARDSession)?.core)
        let watcher = Watcher(core.fileDrags.remoteDrags())
        try session.point(50, 20, .primary)
        try session.point(46, 22, .primary)
        await until("the press") { mac.inputTraffic.count == 2 }
        #expect(mac.sealedInput.isEmpty)
        #expect(!mac.beginDrag(paths: ["/Users/tester/Desktop/notes.txt"], picturePNG: Self.picture))
        mac.sendBell()
        try await Task.sleep(for: .milliseconds(200))
        #expect(watcher.values.isEmpty)
        await session.disconnect()
    }

    /// A viewer may ask what the drag on the Mac carries (`0x0e`). With none under way a Mac logs
    /// "drag not active - ignore request" and sends nothing; the session carries on.
    @Test func askingForADragWhenThereIsNoneBringsNothing() async throws {
        let (session, mac) = try await connect()
        let (drags, _) = try Self.drags(session)
        let watcher = Watcher(drags.remoteDrags())
        let core = try #require((session as? ARDSession)?.core)
        core.deliverRawInput([Data([ClientMessageType.dragRequest, 0, 0, 0, 0x4d, 0x41, 0x52, 0x50])])
        session.key(.a, "a", .down)
        session.key(.a, "a", .up)
        await until("the key") { mac.inputTraffic.count == 3 }
        #expect(mac.inputTraffic.first == .dragRequest(token: 0x4d41_5250))
        #expect(watcher.values.isEmpty)
        #expect(session.state == .connected)
        await session.disconnect()
    }

    // MARK: Where drags are offered

    /// A Mac goes along with a drag only for a viewer whose pointer events are sealed and who may
    /// control it; the capability says which of the two is missing.
    @Test func dragsAreOfferedOnlyWithSealedInputAndControl() async throws {
        let (usual, _) = try await connect()
        #expect(usual.capabilities.fileDrag.isAvailable)
        await usual.disconnect()
        #expect(!usual.capabilities.fileDrag.isAvailable)

        var plain = ScriptedMac.Options()
        plain.takesEncryptedInput = false
        let (unsealed, _) = try await connect(plain)
        #expect(unsealed.capabilities.fileDrag.unavailableReason == .notSupportedByServer)
        #expect(unsealed.capabilities.fileTransfer.isAvailable)
        await unsealed.disconnect()

        var watching = ScriptedMac.Options()
        watching.isObserveOnly = true
        let (observer, _) = try await connect(watching)
        #expect(observer.capabilities.fileDrag.unavailableReason == .notPermitted)
        await observer.disconnect()
    }
}
