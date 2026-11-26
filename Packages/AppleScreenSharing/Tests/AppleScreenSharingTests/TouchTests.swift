// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
@testable import AppleScreenSharing
import Foundation
import RemoteDesktopCore
import Testing

private extension ScriptedMac {
    var pointerEvents: Int {
        record.withLock { $0.messages.count { if case .pointer = $0 { true } else { false } } }
    }

    var touches: [(display: UInt32, report: DigitizerReport)] {
        record.withLock { record in
            record.messages.compactMap { if case .touch(let display, let report) = $0 { (display, report) } else { nil } }
        }
    }
}

private extension RemoteSession {
    func touch(_ contacts: [TouchEvent.Contact]) throws {
        let display = try #require(layout.displays.first)
        input.send(.touch(TouchEvent(display: display.id, contacts: contacts, layoutGeneration: layout.generation)))
    }
}

private func finger(_ id: Int, _ x: Double, _ y: Double, _ phase: TouchEvent.Contact.Phase = .touching) -> TouchEvent.Contact {
    TouchEvent.Contact(id: id, position: PixelPoint(x: x, y: y), phase: phase)
}

/// Touches to a Mac that takes them as a touch screen of its own (macOS 27.3): one report per
/// event, to the Mac's own id for the display, positions as fractions of it.
@Suite struct ScriptedTouchTests {
    private static func connect(_ configure: (inout ScriptedMac.Options) -> Void = { _ in }) async throws -> (any RemoteSession, ScriptedMac) {
        var options = ScriptedMac.Options()
        options.takesTouches = true
        configure(&options)
        let transport = ScriptedMacTransport(options: options)
        var backend = AppleScreenSharingBackend()
        backend.sessionTiming.inputSettlingTime = .zero
        let session = try await backend.connect(ScriptedMacTests.standardRequest(transport))
        return (session, transport.latest)
    }

    @Test func fingersGoAsReportsToTheMacsOwnDisplay() async throws {
        let (session, mac) = try await Self.connect()
        #expect(session.capabilities.touch.value == TouchInput(maximumContacts: 5))
        // The scripted Mac's display is 64 × 48 pixels, its id 77.
        try session.touch([finger(0, 0, 0)])
        try session.touch([finger(0, 63, 47), finger(1, 31.5, 23.5)])
        try session.touch([finger(0, 63, 47, .lifted), finger(1, 31.5, 23.5)])
        try session.touch([finger(1, 31.5, 23.5, .lifted)])
        await until("the touches") { mac.touches.count == 4 }

        let touches = mac.touches
        #expect(touches.allSatisfy { $0.display == 77 })
        typealias Contact = DigitizerReport.Contact
        #expect(touches.map(\.report.contacts) == [
            [Contact(identifier: 0, isTouching: true, x: 0, y: 0)],
            [Contact(identifier: 0, isTouching: true, x: 65535, y: 65535), Contact(identifier: 1, isTouching: true, x: 32767, y: 32767)],
            [Contact(identifier: 0, isTouching: false, x: 65535, y: 65535), Contact(identifier: 1, isTouching: true, x: 32767, y: 32767)],
            [Contact(identifier: 1, isTouching: false, x: 32767, y: 32767)],
        ])
        await session.disconnect()
    }

    @Test func aCancelledFingerIsCancelledOnTheMac() async throws {
        let (session, mac) = try await Self.connect()
        try session.touch([finger(2, 10, 10)])
        try session.touch([finger(2, 10, 10, .cancelled)])
        await until("the touches") { mac.touches.count == 2 }
        #expect(mac.touches.last?.report.contacts == [DigitizerReport.Contact(identifier: 2, isTouching: false, isCancelled: true, x: 10402, y: 13943)])
        await session.disconnect()
    }

    /// Losing focus, or a display going away, must not leave a finger down on the Mac.
    @Test func fingersStillDownAreCancelledWhenEverythingIsReleased() async throws {
        let (session, mac) = try await Self.connect()
        try session.touch([finger(0, 10, 10), finger(3, 20, 20)])
        session.input.send(.releaseAll)
        // Nothing is left to release a second time. Input arrives in order, so once the pointer
        // event after it has, so has anything the second release sent.
        session.input.send(.releaseAll)
        try session.point(1, 1)
        await until("the pointer") { mac.pointerEvents == 1 }
        #expect(mac.touches.count == 2)
        #expect(mac.touches.last?.report.contacts.map { [$0.identifier, $0.isTouching ? 1 : 0, $0.isInRange ? 1 : 0, $0.isCancelled ? 1 : 0] } == [[0, 0, 0, 1], [3, 0, 0, 1]])

        // Fingers on a layout that has gone are not sent; those down are let go.
        try session.touch([finger(1, 5, 5)])
        let display = try #require(session.layout.displays.first)
        session.input.send(.touch(TouchEvent(display: display.id, contacts: [finger(1, 6, 6)], layoutGeneration: session.layout.generation + 1)))
        await until("the release") { mac.touches.count == 4 }
        #expect(mac.touches.last?.report.contacts.map(\.isCancelled) == [true])
        await session.disconnect()
    }

    @Test func noFingerIsSentBeyondWhatTheMacFollows() async throws {
        let (session, mac) = try await Self.connect()
        try session.touch((0..<7).map { finger($0, 1, 1) })
        await until("the touches") { mac.touches.count == 1 }
        #expect(mac.touches.first?.report.contacts.map(\.identifier) == [0, 1, 2, 3, 4])
        await session.disconnect()
    }

    @Test func aMacBefore27Point3TakesNoTouches() async throws {
        let (session, mac) = try await Self.connect { $0.takesTouches = false }
        #expect(session.capabilities.touch.unavailableReason == .notSupportedByServer)
        try session.touch([finger(0, 1, 1)])
        try session.point(1, 1)
        await until("the pointer") { mac.pointerEvents == 1 }
        #expect(mac.touches.isEmpty)
        await session.disconnect()
    }

    /// A Mac passes touches on only for the session on its own screen.
    @Test func aSessionOfOnesOwnTakesNoTouches() async throws {
        let (session, mac) = try await Self.connect { $0.standardLayoutFlags = [.onVirtualDisplay] }
        #expect(session.capabilities.touch.unavailableReason == .notSupportedByServer)
        try session.touch([finger(0, 1, 1)])
        try session.point(1, 1)
        await until("the pointer") { mac.pointerEvents == 1 }
        #expect(mac.touches.isEmpty)
        await session.disconnect()
    }

    @Test func aViewerThatMayOnlyWatchTakesNoTouches() async throws {
        let (session, _) = try await Self.connect { $0.isObserveOnly = true }
        #expect(session.capabilities.touch.unavailableReason == .notPermitted)
        await session.disconnect()
    }

    /// A finger dragged while the connection is backed up arrives as its last place, not its whole
    /// path; a finger landing or lifting is never dropped, and pointer moves are not mixed in.
    @Test func touchMovesOnABackedUpConnectionCollapseButLandingAndLiftingAreKept() async throws {
        let (session, mac) = try await Self.connect()
        try session.touch([finger(0, 1, 1)])
        await until("the first touch") { mac.touches.count == 1 }
        await mac.stallViewer(true)
        for step in 0..<3000 {
            try session.touch([finger(0, Double(step % 60), 10)])
        }
        try session.point(5, 5)
        try session.touch([finger(0, 33, 10), finger(1, 40, 40)])
        try session.touch([finger(0, 34, 10), finger(1, 41, 40)])
        try session.touch([finger(0, 34, 10, .lifted), finger(1, 41, 40)])
        await mac.stallViewer(false)
        await until("the lift") { mac.touches.last?.report.contacts.first?.isTouching == false }
        let reports = mac.touches.map(\.report.contacts)
        #expect(reports.count < 2000, "\(reports.count) moves replayed")
        #expect(mac.pointerEvents == 1)
        #expect(reports.suffix(4).map { $0.map(\.identifier) } == [[0], [0, 1], [0, 1], [0, 1]])
        #expect(reports.suffix(4).first?.first?.x == DigitizerReport.Contact.scaled(59.0 / 63))
        await session.disconnect()
    }

    /// The Mac stops taking this viewer's input with a finger down: the finger is let go there, and
    /// nothing is left down for when control comes back.
    @Test func withdrawingControlLetsTheFingersGo() async throws {
        let (session, mac) = try await Self.connect()
        try session.touch([finger(2, 10, 10)])
        await until("the touch") { mac.touches.count == 1 }
        mac.sendStatus(10)
        await until("the release") { mac.touches.count == 2 }
        #expect(mac.touches.last?.report.contacts.map(\.isCancelled) == [true])
        #expect(session.capabilities.touch.unavailableReason == .notPermitted)
        mac.sendStatus(9)
        await until("touches to come back") { session.capabilities.touch.isAvailable }
        session.input.send(.releaseAll)
        try session.point(1, 1)
        await until("the pointer") { mac.pointerEvents == 1 }
        #expect(mac.touches.count == 2)
        await session.disconnect()
    }

    /// High Performance's displays are recreated under new ids; touches go to the one in the layout.
    @Test func inHighPerformanceTouchesGoToTheVirtualDisplaysId() async throws {
        var options = ScriptedMac.Options()
        options.takesTouches = true
        let transport = ScriptedMacTransport(options: options, supportsDatagrams: true)
        var backend = ScriptedHighPerformanceTests.backend
        backend.sessionTiming.displayChangeInputHold = .zero
        let session = try await backend.connect(ScriptedHighPerformanceTests.request(transport))
        let mac = transport.latest
        #expect(session.capabilities.touch.isAvailable)
        try session.touch([finger(0, 319, 0)])
        await until("the touch", timeout: .seconds(10)) { mac.touches.count == 1 }
        let touch = try #require(mac.touches.first)
        // Each configuration's displays get new ids: the opening display 0x4001, the session's 0x4002.
        #expect(touch.display == 0x4002)
        #expect(touch.report.contacts.map { [$0.x, $0.y] } == [[65535, 0]])
        await session.disconnect()
    }
}

private extension RemoteSession {
    func point(_ x: Double, _ y: Double) throws {
        let display = try #require(layout.displays.first)
        input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: x, y: y), layoutGeneration: layout.generation)))
    }
}
