// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopInteraction
import RemoteDesktopSimulated
import Testing
@testable import MarionetteKit

@MainActor
@Suite struct SessionInputTests {
    @Test func aHardwareKeyIsOneDownAndOneUpHoweverLongItIsHeld() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.keyDown(.a, characters: "a", charactersIgnoringModifiers: "a", source: .hardware)
        // The system repeats a held key; the remote machine must not see that.
        model.keyDown(.a, characters: "a", charactersIgnoringModifiers: "a", source: .hardware)
        model.keyDown(.a, characters: "a", charactersIgnoringModifiers: "a", source: .hardware)
        #expect(model.hasHeldKeys)
        model.keyUp(.a, source: .hardware)
        let keys = session.receivedInput.compactMap(\.key)
        #expect(keys.map(\.phase) == [.down, .up])
        #expect(keys.allSatisfy { $0.key == .a })
        #expect(!model.hasHeldKeys)
        model.keyUp(.a, source: .hardware)
        #expect(session.receivedInput.count == 2, "a stray key-up sends nothing")
        model.disconnect()
    }

    /// When the remote machine's pointer is moved there (its own mouse), this client's pointer,
    /// which trackpad-style touches move from where it is, goes on from that place.
    @Test func aPointerMovedAtTheRemoteMachineIsWhereThePointerGoesOnFrom() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        let display = try #require(session.layout.displays.first)
        let frame = display.frameInDesktop
        session.simulateRemotePointerMove(to: PixelPoint(x: Double(frame.x + 30), y: Double(frame.y + 20)))
        try await waitUntil { model.uiState.pointer == PixelPoint(x: 30, y: 20) }
        model.disconnect()
    }

    @Test func hardwareModifiersTravelAsKeysAndAsFlags() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.keyDown(.rightCommand, source: .hardware)
        model.keyDown(.c, characters: "c", charactersIgnoringModifiers: "c", source: .hardware)
        model.keyUp(.c, source: .hardware)
        model.keyUp(.rightCommand, source: .hardware)
        let keys = session.receivedInput.compactMap(\.key)
        #expect(keys.map(\.key) == [.rightCommand, .c, .c, .rightCommand])
        #expect(keys[1].modifiers == .rightCommand)
        #expect(keys[3].modifiers.isEmpty)
        model.disconnect()
    }

    @Test func aLatchedModifierAppliesToAHardwareKeyAndIsUsedUpByIt() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.tapModifier(.command)
        model.keyDown(.q, characters: "q", charactersIgnoringModifiers: "q", source: .hardware)
        #expect(model.uiState.modifiers.state(of: .command) == .oneShot, "still held while the key is down")
        model.keyUp(.q, source: .hardware)
        #expect(model.uiState.modifiers.isEmpty)
        let keys = session.receivedInput.compactMap(\.key)
        #expect(keys.map(\.key) == [.leftCommand, .q, .q, .leftCommand])
        #expect(keys[1].modifiers.hasCommand)
        model.disconnect()
    }

    @Test func theFunctionLayerWorksOnTheOnScreenKeyboard() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.tapModifier(.function)
        model.keyDown(.rightArrow)
        model.keyUp(.rightArrow)
        let keys = session.receivedInput.compactMap(\.key)
        #expect(keys.map(\.key) == [.end, .end])
        #expect(keys.allSatisfy { !$0.modifiers.contains(.function) })
        #expect(model.uiState.modifiers.isEmpty)
        model.disconnect()
    }

    @Test func resigningActiveReleasesHeldKeysAndMouseButtons() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.keyDown(.leftShift, source: .hardware)
        model.keyDown(.downArrow)
        model.pointerButtons(.primary, at: ViewPoint(x: 200, y: 150))
        model.sceneDidResignActive()
        #expect(!model.hasHeldKeys)
        let received = session.receivedInput
        #expect(received.last == .releaseAll)
        let downs = received.compactMap(\.key).filter { $0.phase == .down }.map(\.key)
        let ups = received.compactMap(\.key).filter { $0.phase == .up }.map(\.key)
        #expect(Set(downs.compactMap(\.self)) == Set(ups.compactMap(\.self)))
        #expect(received.compactMap(\.pointer).last?.buttons == [])
        model.disconnect()
    }

    @Test func theMouseIsAnAbsolutePointerWithButtonsAndScroll() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        // 640×400 fitted into 400×300: scale 0.625, 25 pt of letterbox above.
        model.pointerMoved(to: ViewPoint(x: 100, y: 75))
        var pointer = try #require(session.receivedInput.compactMap(\.pointer).last)
        #expect(abs(pointer.position.x - 160) < 1 && abs(pointer.position.y - 80) < 1)
        #expect(pointer.buttons.isEmpty)
        #expect(abs(model.uiState.pointer.x - 160) < 1, "the locally drawn cursor follows")

        model.pointerButtons(.secondary, at: ViewPoint(x: 100, y: 75))
        model.pointerButtons([], at: ViewPoint(x: 100, y: 75))
        #expect(model.inputTally.secondaryClicks == 1)
        pointer = try #require(session.receivedInput.compactMap(\.pointer).last)
        #expect(pointer.buttons.isEmpty)

        model.pointerScrolled(by: ViewVector(dx: 0, dy: -20), at: ViewPoint(x: 100, y: 75), phase: .began)
        model.pointerScrolled(by: ViewVector(dx: 0, dy: -20), at: ViewPoint(x: 100, y: 75), phase: .changed)
        model.pointerScrolled(by: .zero, at: ViewPoint(x: 100, y: 75), phase: .ended)
        let scrolls = session.receivedInput.compactMap { event -> ScrollEvent? in
            if case .scroll(let scroll) = event { scroll } else { nil }
        }
        #expect(scrolls.first?.phase == .began)
        #expect(scrolls.last?.phase == .ended)
        #expect(scrolls.contains { $0.deltaY != 0 })

        let before = model.uiState.viewport.scale
        let count = session.receivedInput.count
        model.pointerMagnified(by: 1.5, at: ViewPoint(x: 200, y: 150))
        #expect(model.uiState.viewport.scale > before)
        #expect(session.receivedInput.count == count, "zooming the view sends nothing")
        model.disconnect()
    }

    @Test func thePencilClicksWhereItTouches() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        let point = ViewPoint(x: 200, y: 150)
        model.pencil(TouchSample(id: 0, phase: .began, location: point, timestamp: 1))
        model.pencil(TouchSample(id: 0, phase: .moved, location: ViewPoint(x: 220, y: 150), timestamp: 1.1))
        model.pencil(TouchSample(id: 0, phase: .ended, location: ViewPoint(x: 220, y: 150), timestamp: 1.2))
        let pointers = session.receivedInput.compactMap(\.pointer)
        #expect(pointers.first { $0.buttons == .primary } != nil)
        #expect(pointers.last?.buttons == [])
        #expect(model.inputTally.clicks == 1)
        model.disconnect()
    }

    @Test func pastePutsTheTextOnTheRemoteClipboardThenPressesCommandV() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.paste("from the phone")
        try await waitUntil { session.receivedInput.compactMap(\.key).contains { $0.key == .v && $0.phase == .up } }
        #expect(session.remoteClipboard.first?.text == "from the phone")
        let keys = session.receivedInput.compactMap(\.key)
        #expect(keys.first?.key == .leftCommand)
        #expect(keys.first { $0.key == .v }?.modifiers.hasCommand == true)
        model.disconnect()
    }

    @Test func anUnreliableNetworkFallsBackToStandardAndSaysWhy() async throws {
        var scenario = fastScenario()
        scenario.failure = (.startingMedia, .modeUnavailable(mode: .highPerformance, reason: .unreliableNetwork))
        let fixture = try Fixture([scenario], claimedModes: [.highPerformance, .standard])
        let model = try await fixture.connectedModel()
        #expect(model.info?.mode == .standard)
        #expect(model.banner?.kind == .fallback)
        #expect(model.banner?.title == "Connected in Standard Mode")
        #expect(model.banner?.message.contains("losing too much data") == true)
        model.disconnect()
    }

    @Test func scrollDirectionAndPointerSpeedComeFromTheSavedSettings() async throws {
        let fixture = try Fixture()
        var preferences = SessionPreferences()
        #expect(preferences.naturalScrolling && preferences.pointerSpeed == 1)
        preferences.naturalScrolling = false
        preferences.pointerSpeed = 9
        preferences.save(to: fixture.defaults)
        let stored = SessionPreferences(defaults: fixture.defaults)
        #expect(!stored.naturalScrolling)
        #expect(stored.pointerSpeed == 2, "out-of-range speeds are pulled back into range")

        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.pointerScrolled(by: ViewVector(dx: 0, dy: 10), at: ViewPoint(x: 100, y: 100), phase: .none)
        let scroll = session.receivedInput.compactMap { event -> ScrollEvent? in
            if case .scroll(let scroll) = event { scroll } else { nil }
        }.first
        #expect((scroll?.deltaY ?? 0) < 0, "with natural scrolling off the direction is reversed")
        // Closing the session keeps the input settings it did not change.
        model.setInputMode(.trackpad)
        model.disconnect()
        let after = SessionPreferences(defaults: fixture.defaults)
        #expect(after.inputMode == .trackpad && !after.naturalScrolling && after.pointerSpeed == 2)
    }

    @Test func aPaneLearnedAfterConnectingStillGetsItsFittedDisplay() async throws {
        var fixture = try Fixture()
        fixture.computer.display = .fitToDevice
        let model = fixture.makeModel()
        // The session starts before its screen exists, as it does when a computer is tapped.
        model.start()
        try await waitUntil { model.phase == .connected }
        model.stageLayoutChanged(size: CGSize(width: 402, height: 874), safeArea: .zero, deviceScale: 3)
        try await waitUntil { model.selectedDisplay?.pixelSize == PixelSize(width: 804, height: 1748) }
        #expect(model.selectedDisplay?.kind == .virtual)
        model.disconnect()
    }

    @Test func aStalledHighPerformanceSessionReconnectsInStandardAndSaysWhy() async throws {
        var stalling = fastScenario()
        stalling.disconnect = (.milliseconds(120), .mediaStalled(.lossy))
        let fixture = try Fixture([stalling, fastScenario()], claimedModes: [.highPerformance, .standard])
        // Only the end state is waited for: the first session stalls 120 ms after it connects,
        // which a loaded machine can miss.
        let model = try await fixture.startedModel { $0.phase == .connected && $0.info?.mode == .standard }
        #expect(fixture.backend.sessions.first?.info.mode == .highPerformance)
        #expect(model.banner?.title == "Reconnected in Standard Mode")
        #expect(model.banner?.message.contains("losing too much data") == true)
        #expect(fixture.backend.attempts == 2, "no second attempt at High Performance")
        model.disconnect()
    }

    @Test func aPhoneHeldUprightGetsAPortraitDisplayThatFillsItsPane() async throws {
        var fixture = try Fixture()
        fixture.computer.display = .fitToDevice
        let model = fixture.makeModel()
        model.stageLayoutChanged(size: CGSize(width: 402, height: 874), safeArea: .zero, deviceScale: 3)
        model.start()
        try await waitUntil { model.phase == .connected }
        let display = try #require(model.selectedDisplay)
        #expect(display.kind == .virtual)
        #expect(display.pixelSize == PixelSize(width: 804, height: 1748))
        #expect(abs(model.uiState.viewport.contentFrame.width - 402) < 1, "fitted, it fills the pane")
        #expect(abs(model.uiState.viewport.contentFrame.height - 874) < 1)

        // A bar's worth of change is not worth a resize…
        model.stageLayoutChanged(size: CGSize(width: 402, height: 874), safeArea: ViewInsets(bottom: 50), deviceScale: 3)
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.selectedDisplay?.pixelSize == PixelSize(width: 804, height: 1748))
        // …turning the device is. On its side the phone has a shape the Mac makes at Retina: its
        // own pixels at 2x.
        model.stageLayoutChanged(size: CGSize(width: 874, height: 402), safeArea: .zero, deviceScale: 3)
        try await waitUntil { model.selectedDisplay?.pixelSize == PixelSize(width: 2624, height: 1208) }
        #expect(model.selectedDisplay?.scale == 2)
        model.disconnect()
    }
}
