// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopInteraction
import RemoteDesktopSimulated
import Testing
@testable import MarionetteKit

@MainActor
@Suite struct SessionModelTests {
    @Test func connectsAndPublishesASnapshot() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        #expect(model.info?.mode == .highPerformance)
        #expect(model.statusLine == "High Performance")
        #expect(model.layout.displays.count == 1)
        #expect(model.selectedDisplay?.pixelSize == PixelSize(width: 640, height: 400))
        #expect(model.uiState.viewport.contentSize == PixelSize(width: 640, height: 400))
        #expect(model.features.audio == .unavailable(.notSupportedByServer))
        #expect(model.features.remoteActions == RemoteAction.allCases)
        #expect(model.prompts.pending == nil)
        try await waitUntil { model.hasFirstFrame }
        #expect(model.renderer.lastFramePixelSize == PixelSize(width: 640, height: 400))
        #expect(fixture.repository.record(id: fixture.computer.id)?.lastMode == .highPerformance)
        model.disconnect()
        #expect(model.phase == .closed)
    }

    @Test func tapInTouchModeClicksAtTheMappedPixel() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        // 640×400 fitted into 400×300 is 400×250, centred: 25 pt of letterbox above.
        for samples in tap(at: ViewPoint(x: 200, y: 150)) { model.handleTouches(samples, on: .stage) }
        let pointers = fixture.backend.sessions[0].receivedInput.compactMap(\.pointer)
        let down = try #require(pointers.first { $0.buttons == .primary })
        #expect(abs(down.position.x - 320) < 1)
        #expect(abs(down.position.y - 200) < 1)
        #expect(pointers.last?.buttons == [])
        #expect(down.layoutGeneration == model.layout.generation)
        #expect(abs(model.uiState.pointer.x - 320) < 1)
        model.disconnect()
    }

    @Test func trackpadModeMovesThePointerRelativelyAndClicksThere() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        model.setInputMode(.trackpad)
        let start = model.uiState.pointer
        model.handleTouches([TouchSample(id: 1, phase: .began, location: ViewPoint(x: 50, y: 50), timestamp: 1)], on: .stage)
        model.handleTouches([TouchSample(id: 1, phase: .moved, location: ViewPoint(x: 90, y: 50), timestamp: 1.2)], on: .stage)
        model.handleTouches([TouchSample(id: 1, phase: .ended, location: ViewPoint(x: 90, y: 50), timestamp: 1.25)], on: .stage)
        #expect(model.uiState.pointer.x > start.x)
        #expect(model.uiState.pointer.y == start.y)
        let moved = model.uiState.pointer
        for samples in tap(at: ViewPoint(x: 300, y: 200), time: 3) { model.handleTouches(samples, on: .stage) }
        let down = try #require(fixture.backend.sessions[0].receivedInput.compactMap(\.pointer).first { $0.buttons == .primary })
        #expect(down.position == moved)
        model.handleTouches([TouchSample(id: 7, phase: .began, location: ViewPoint(x: 10, y: 10), timestamp: 5)], on: .deck)
        model.handleTouches([TouchSample(id: 7, phase: .moved, location: ViewPoint(x: 10, y: 60), timestamp: 5.2)], on: .deck)
        model.handleTouches([TouchSample(id: 7, phase: .ended, location: ViewPoint(x: 10, y: 60), timestamp: 5.25)], on: .deck)
        #expect(model.uiState.pointer.y > moved.y)
        #expect(SessionPreferences(defaults: fixture.defaults).inputMode == .trackpad)
        model.disconnect()
    }

    @Test func longPressIsDeliveredByTheModelsTimer() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        var feedback: [InteractionEffect.Feedback] = []
        model.onFeedback = { feedback.append($0) }
        let now = ProcessInfo.processInfo.systemUptime
        let point = ViewPoint(x: 200, y: 150)
        model.handleTouches([TouchSample(id: 1, phase: .began, location: point, timestamp: now)], on: .stage)
        try await waitUntil { feedback.contains(.longPress) }
        model.handleTouches([TouchSample(id: 1, phase: .ended, location: point, timestamp: ProcessInfo.processInfo.systemUptime)], on: .stage)
        let pointers = fixture.backend.sessions[0].receivedInput.compactMap(\.pointer)
        #expect(pointers.contains { $0.buttons == .secondary })
        #expect(pointers.last?.buttons == [])
        model.disconnect()
    }

    @Test func pinchZoomsTheViewportWithoutSendingInput() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let before = model.uiState.viewport.scale
        func pair(_ phase: TouchSample.Phase, spread: Double, _ time: Double) -> [TouchSample] {
            [
                TouchSample(id: 1, phase: phase, location: ViewPoint(x: 200 - spread, y: 150), timestamp: time),
                TouchSample(id: 2, phase: phase, location: ViewPoint(x: 200 + spread, y: 150), timestamp: time),
            ]
        }
        model.handleTouches(pair(.began, spread: 30, 1), on: .stage)
        model.handleTouches(pair(.moved, spread: 60, 1.1), on: .stage)
        model.handleTouches(pair(.moved, spread: 90, 1.2), on: .stage)
        model.handleTouches(pair(.ended, spread: 90, 1.3), on: .stage)
        #expect(model.uiState.viewport.scale > before * 1.5)
        #expect(model.uiState.zoomMode == .free)
        #expect(fixture.backend.sessions[0].receivedInput.isEmpty)
        model.setZoomMode(.fit)
        #expect(model.uiState.viewport.scale == before)
        model.disconnect()
    }

    /// Regression: right after switching displays a pinch did nothing until the pointer moved.
    @Test func aPinchRightAfterSwitchingDisplaysZooms() async throws {
        let fixture = try Fixture([fastScenario(.twoDisplays)])
        let model = try await fixture.connectedModel()
        model.selectDisplay(model.layout.displays[1].id)
        let before = model.uiState.viewport.scale
        func pair(_ phase: TouchSample.Phase, spread: Double, _ time: Double) -> [TouchSample] {
            [
                TouchSample(id: 1, phase: phase, location: ViewPoint(x: 200 - spread, y: 150), timestamp: time),
                TouchSample(id: 2, phase: phase, location: ViewPoint(x: 200 + spread, y: 150), timestamp: time),
            ]
        }
        model.handleTouches(pair(.began, spread: 30, 1), on: .stage)
        model.handleTouches(pair(.moved, spread: 60, 1.1), on: .stage)
        model.handleTouches(pair(.moved, spread: 90, 1.2), on: .stage)
        model.handleTouches(pair(.ended, spread: 90, 1.3), on: .stage)
        #expect(model.uiState.viewport.scale > before * 1.5)
        model.disconnect()
    }

    @Test func typingUsesTextAndLatchedModifiersBecomeKeyStrokes() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.insertText("hi")
        #expect(session.receivedInput == [.text("hi")])

        model.tapModifier(.command)
        #expect(model.uiState.modifiers.state(of: .command) == .oneShot)
        model.insertText("c")
        #expect(model.uiState.modifiers.state(of: .command) == .off)
        let keys = session.receivedInput.compactMap(\.key)
        #expect(keys.map(\.key) == [.leftCommand, .c, .c, .leftCommand])
        #expect(keys.map(\.phase) == [.down, .down, .up, .up])
        #expect(keys[1].modifiers == .leftCommand)

        // A locked modifier survives a key press; a third tap clears it.
        model.tapModifier(.shift)
        model.tapModifier(.shift)
        model.pressKey(.tab)
        #expect(model.uiState.modifiers.state(of: .shift) == .locked)
        model.tapModifier(.shift)
        #expect(model.uiState.modifiers.isEmpty)

        // fn + arrow is translated on the client.
        model.tapModifier(.function)
        model.pressKey(.leftArrow)
        #expect(session.receivedInput.compactMap(\.key).last?.key == .home)
        model.disconnect()
    }

    @Test func aLatchedModifierIsConsumedByAClick() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        model.tapModifier(.command)
        for samples in tap(at: ViewPoint(x: 200, y: 150)) { model.handleTouches(samples, on: .stage) }
        #expect(model.uiState.modifiers.isEmpty)
        let received = fixture.backend.sessions[0].receivedInput
        #expect(received.first?.key?.key == .leftCommand)
        #expect(received.last?.key?.phase == .up)
        model.disconnect()
    }

    @Test func resigningActiveReleasesEverything() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        model.tapModifier(.option)
        model.tapModifier(.option)
        model.handleTouches([TouchSample(id: 1, phase: .began, location: ViewPoint(x: 200, y: 150), timestamp: 1)], on: .stage)
        model.sceneDidResignActive()
        #expect(model.uiState.modifiers.isEmpty)
        let received = fixture.backend.sessions[0].receivedInput
        #expect(received.last == .releaseAll)
        #expect(received.compactMap(\.pointer).allSatisfy { $0.buttons.isEmpty } || received.compactMap(\.pointer).last?.buttons == [])
        model.disconnect()
    }

    @Test func fallsBackToStandardWithABanner() async throws {
        var scenario = fastScenario(.standard)
        scenario.offeredModes = [.standard]
        let fixture = try Fixture([scenario], claimedModes: [.highPerformance, .standard])
        let model = try await fixture.connectedModel()
        #expect(model.info?.mode == .standard)
        #expect(model.banner?.kind == .fallback)
        #expect(model.banner?.title == "Connected in Standard Mode")
        #expect(fixture.backend.attempts == 2)
        model.dismissBanner()
        #expect(model.banner == nil)
        model.disconnect()
    }

    @Test func curtainModeFollowsTheMachine() async throws {
        let highPerformance = try await Fixture().connectedModel()
        #expect(highPerformance.features.curtain == .unavailable(.requiresMode(.standard)))
        highPerformance.disconnect()

        var scenario = fastScenario(.standard)
        scenario.offeredModes = [.standard]
        let fixture = try Fixture([scenario], claimedModes: [.standard])
        let model = try await fixture.connectedModel()
        #expect(model.features.curtain == .available)
        #expect(!model.features.isCurtained)
        model.setCurtained(true)
        try await waitUntil { model.features.isCurtained }
        model.setCurtained(false)
        try await waitUntil { !model.features.isCurtained }
        model.disconnect()
    }

    @Test func aFailureOffersRecoveryAndRetryWorks() async throws {
        var failing = fastScenario()
        failing.failure = (.reachingHost, .unreachable(host: "test.local", detail: ""))
        let fixture = try Fixture([failing, fastScenario()])
        let model = fixture.makeModel()
        model.start()
        try await waitUntil { model.phase == .failed(.unreachable(host: "test.local", detail: "")) }
        #expect(model.perform(.showHelp(topic: .enableScreenSharing)) == false)
        #expect(model.perform(.retry))
        try await waitUntil { model.phase == .connected }
        model.disconnect()
    }

    @Test func requiringHighPerformanceFailsThenConnectsInStandard() async throws {
        var scenario = fastScenario(.standard)
        scenario.offeredModes = [.standard]
        var fixture = try Fixture([scenario], claimedModes: [.highPerformance, .standard])
        fixture.computer.mode = .highPerformance
        let model = fixture.makeModel()
        model.start()
        try await waitUntil { model.phase == .failed(.modeUnavailable(mode: .highPerformance, reason: .notSupportedByServer)) }
        model.perform(.connectWithStandardMode)
        try await waitUntil { model.phase == .connected }
        #expect(model.info?.mode == .standard)
        model.disconnect()
    }

    @Test func cancellingWhileConnectingClosesTheSession() async throws {
        var slow = fastScenario()
        slow.phaseDelay = .seconds(30)
        let fixture = try Fixture([slow])
        let model = fixture.makeModel()
        var closed = 0
        model.onClose = { _ in closed += 1 }
        model.start()
        try await waitUntil { model.phase == .connecting(.reachingHost) }
        model.disconnect()
        #expect(model.phase == .closed)
        #expect(closed == 1)
    }

    @Test func promptsForCredentialsAndRemembersThemOnSuccess() async throws {
        var fixture = try Fixture(savePassword: false)
        fixture.computer.username = ""
        let model = fixture.makeModel()
        model.start()
        try await waitUntil { model.prompts.pending != nil }
        guard case .credentials(let first) = model.prompts.pending?.prompt else {
            Issue.record("expected a credential prompt")
            return
        }
        #expect(first.attempt == 1)
        model.prompts.reply(.credentials(username: "demo", password: "wrong"), remember: true)
        try await waitUntil {
            if case .credentials(let second) = model.prompts.pending?.prompt { second.attempt == 2 } else { false }
        }
        guard case .credentials(let second) = model.prompts.pending?.prompt else { return }
        #expect(second.previousFailure != nil)
        #expect(try fixture.secrets.secret(for: .remoteDesktopPassword(for: fixture.computer)) == nil)
        model.prompts.reply(.credentials(username: "demo", password: "demo"), remember: true)
        try await waitUntil { model.phase == .connected }
        #expect(try fixture.secrets.secret(for: .remoteDesktopPassword(for: fixture.computer)) == "demo")
        #expect(fixture.repository.record(id: fixture.computer.id)?.configuration.username == "demo")
        model.disconnect()
    }

    @Test func decliningAPromptClosesTheSession() async throws {
        let fixture = try Fixture(savePassword: false)
        let model = fixture.makeModel()
        model.start()
        try await waitUntil { model.prompts.pending != nil }
        model.prompts.cancelPending()
        try await waitUntil { model.phase == .closed }
    }

    @Test func aDroppedConnectionReconnectsAndKeepsTheLastFrame() async throws {
        var dropping = fastScenario()
        // Long enough windows to be seen on a loaded machine: connected for 0.6 s, then 0.3 s
        // before the first reconnection attempt.
        dropping.disconnect = (.milliseconds(600), .connectionLost(detail: ""))
        var fixture = try Fixture([dropping, fastScenario()])
        fixture.reconnection.initialDelay = .milliseconds(300)
        fixture.reconnection.maximumDelay = .milliseconds(300)
        let model = try await fixture.connectedModel()
        try await waitUntil { model.hasFirstFrame }
        try await waitUntil { if case .reconnecting = model.phase { true } else { false } }
        #expect(model.renderer.hasFrame)
        try await waitUntil { model.phase == .connected }
        #expect(fixture.backend.attempts == 2)
        // No second prompt: the credentials used the first time are reused.
        #expect(model.prompts.pending == nil)
        model.disconnect()
    }

    @Test func reconnectionGivesUpAfterItsAttempts() async throws {
        var dropping = fastScenario()
        dropping.disconnect = (.milliseconds(50), .connectionLost(detail: ""))
        var unreachable = fastScenario()
        unreachable.failure = (.reachingHost, .unreachable(host: "test.local", detail: ""))
        let fixture = try Fixture([dropping, unreachable])
        let model = try await fixture.startedModel { if case .failed = $0.phase { true } else { false } }
        #expect(fixture.backend.attempts == 3)
        // The last failure, with its own ways forward, not a generic "connection lost".
        #expect(model.phase == .failed(.unreachable(host: "test.local", detail: "")))
        model.disconnect()
        #expect(model.phase == .closed)
    }

    @Test func aRemoteCloseEndsWithoutReconnecting() async throws {
        var closing = fastScenario()
        closing.disconnect = (.milliseconds(50), .remoteClosed(detail: nil))
        let fixture = try Fixture([closing])
        let model = try await fixture.startedModel { $0.phase == .ended(.remoteClosed(detail: nil)) }
        #expect(fixture.backend.attempts == 1)
        // Input after the end goes nowhere and does not crash.
        model.insertText("x")
        for samples in tap(at: ViewPoint(x: 10, y: 10)) { model.handleTouches(samples, on: .stage) }
        model.reconnect()
        try await waitUntil { model.phase == .connected || model.phase == .ended(.remoteClosed(detail: nil)) }
        model.disconnect()
    }

    @Test func switchingDisplaysRetargetsRenderingAndInput() async throws {
        let fixture = try Fixture([fastScenario(.twoDisplays)])
        let model = try await fixture.connectedModel()
        #expect(model.layout.displays.count == 2)
        let second = model.layout.displays[1]
        model.selectDisplay(second.id)
        #expect(model.selectedDisplay?.id == second.id)
        #expect(model.uiState.viewport.contentSize == second.pixelSize)
        for samples in tap(at: ViewPoint(x: 200, y: 150)) { model.handleTouches(samples, on: .stage) }
        let pointer = try #require(fixture.backend.sessions[0].receivedInput.compactMap(\.pointer).last)
        #expect(pointer.display == second.id)
        try await waitUntil { model.renderer.lastFramePixelSize == second.pixelSize }
        model.disconnect()
    }

    /// Regression: a reconnect, or the next session, went back to the first display.
    @Test func theChosenDisplayIsShownAgainAfterAReconnectAndInTheNextSession() async throws {
        let fixture = try Fixture([fastScenario(.twoDisplays), fastScenario(.twoDisplays), fastScenario(.twoDisplays)])
        let model = try await fixture.connectedModel()
        let first = model.layout.displays[0]
        let second = model.layout.displays[1]
        #expect(model.selectedDisplay?.id == first.id, "the first listed, the main display, by default")
        model.selectDisplay(second.id)
        model.reconnect()
        try await waitUntil { model.phase == .connected && model.layout.displays.count == 2 }
        #expect(model.selectedDisplay?.id == second.id)
        model.disconnect()

        let next = try await fixture.connectedModel()
        #expect(next.selectedDisplay?.id == second.id)
        next.disconnect()
    }

    @Test func theKeyboardSlidesAFittedDesktopUpWithoutRescalingIt() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let before = model.uiState.viewport
        model.setKeyboardOverlap(140)
        let after = model.uiState.viewport
        #expect(after.scale == before.scale)
        #expect(after.contentFrame.maxY <= 300 - 140 + 0.5 || after.isPannable)
        model.setKeyboardOverlap(0)
        #expect(model.uiState.viewport.contentFrame == before.contentFrame)
        model.disconnect()
    }

    @Test func remoteCopiesArriveOnTheLocalPasteboard() async throws {
        var scenario = fastScenario()
        scenario.initialRemoteClipboard = "from the Mac"
        let fixture = try Fixture([scenario])
        let model = try await fixture.connectedModel()
        var text: String?
        for _ in 0..<500 where text == nil {
            text = await fixture.pasteboard.items.first?.text
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(text == "from the Mac")
        await fixture.pasteboard.write([ClipboardItem(text: "from the phone")], localOnly: true)
        model.sendLocalClipboard()
        let session = fixture.backend.sessions[0]
        for _ in 0..<500 where session.remoteClipboard.first?.text != "from the phone" {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(session.remoteClipboard.first?.text == "from the phone")
        model.disconnect()
    }

    @Test func aTransferThatCannotBrowseSendsToItsDefaultFolder() async throws {
        var scenario = fastScenario()
        scenario.fileTransferCanBrowse = false
        let fixture = try Fixture([scenario])
        let model = try await fixture.connectedModel()
        try await waitUntil { model.files.state == .ready }
        #expect(!model.files.canBrowse)
        #expect(model.fileBrowser == nil, "nothing to browse: the Files sheet shows its send-only screen")
        let file = FileManager.default.temporaryDirectory.appending(path: "send-only-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        _ = model.transfers.upload(file, toDirectory: nil)
        try await waitUntil { model.transfers.items.first?.state == .finished }
        model.disconnect()
    }

    @Test func disconnectingSavesAThumbnail() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        try await waitUntil { model.hasFirstFrame }
        model.disconnect()
        try await waitUntil { fixture.repository.record(id: fixture.computer.id)?.thumbnail != nil }
        let data = try #require(fixture.repository.record(id: fixture.computer.id)?.thumbnail)
        #expect(data.starts(with: [0xFF, 0xD8]))
    }

    @Test func fitToDeviceAsksForAVirtualDisplayShapedLikeThePane() async throws {
        var fixture = try Fixture()
        fixture.computer.display = .fitToDevice
        let model = fixture.makeModel()
        // An iPad on its side: big enough for a HiDPI display of exactly the pane's size.
        model.stageLayoutChanged(size: CGSize(width: 1376, height: 1032), safeArea: .zero, deviceScale: 2)
        model.start()
        try await waitUntil { model.phase == .connected }
        #expect(model.selectedDisplay?.kind == .virtual)
        #expect(model.selectedDisplay?.pointSize == ViewSize(width: 1376, height: 1032))
        #expect(model.selectedDisplay?.scale == 2)
        // Turning the device asks again, once the size has settled: a portrait display, within the
        // server's pixel limits.
        model.stageLayoutChanged(size: CGSize(width: 1032, height: 1376), safeArea: .zero, deviceScale: 2)
        try await waitUntil { (model.selectedDisplay?.pixelSize.height ?? 0) > (model.selectedDisplay?.pixelSize.width ?? 0) }
        let portrait = try #require(model.selectedDisplay)
        #expect(portrait.pixelSize.width <= 3840 && portrait.pixelSize.height <= 2160)
        #expect(abs(Double(portrait.pixelSize.width) / Double(portrait.pixelSize.height) - 1032.0 / 1376.0) < 0.02)
        model.disconnect()
    }
}
