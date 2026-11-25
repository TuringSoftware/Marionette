// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopInteraction
import RemoteDesktopSimulated
import Testing
@testable import MarionetteKit

@MainActor
@Suite struct DisplayCrossingTests {
    private let monitor = ExternalScreen(size: ViewSize(width: 1920, height: 1080), scale: 1)

    private func twoDisplays(edge: DisplayEdge? = nil) throws -> Fixture {
        let fixture = try Fixture([fastScenario(.twoDisplays)])
        if let edge {
            var preferences = SessionPreferences(defaults: fixture.defaults)
            preferences.secondaryDisplayEdge = edge
            preferences.save(to: fixture.defaults)
        }
        return fixture
    }

    private func stroke(_ model: SessionModel, dx: Double, dy: Double = 0, time: inout Double) {
        let steps = Int(max(abs(dx), abs(dy)) / 5)
        var location = ViewPoint(x: 200, y: 150)
        model.handleTouches([TouchSample(id: 1, phase: .began, location: location, timestamp: time)], on: .deck)
        for _ in 0..<steps {
            time += 0.01
            location = ViewPoint(x: location.x + dx / Double(steps), y: location.y + dy / Double(steps))
            model.handleTouches([TouchSample(id: 1, phase: .moved, location: location, timestamp: time)], on: .deck)
        }
        time += 0.01
        model.handleTouches([TouchSample(id: 1, phase: .ended, location: location, timestamp: time)], on: .deck)
        time += 1
    }

    @Test func thePointerGoesOnToTheSecondaryDisplayAndBack() async throws {
        let fixture = try twoDisplays()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        let displays = model.layout.displays
        #expect(model.selectedDisplay?.id == displays[0].id)
        let startY = model.uiState.pointer.y
        var time = 1.0

        stroke(model, dx: 600, time: &time)
        #expect(model.selectedDisplay?.id == displays[1].id, "the secondary display is shown")
        let arrived = try #require(session.receivedInput.compactMap(\.pointer).first { $0.display == displays[1].id })
        #expect(arrived.position.x == 0, "in at its left edge")
        let fraction = startY / Double(displays[0].pixelSize.height - 1)
        #expect(abs(arrived.position.y - fraction * Double(displays[1].pixelSize.height - 1)) < 0.001, "as far down as it went out")
        #expect(arrived.buttons.isEmpty)

        stroke(model, dx: -1200, time: &time)
        #expect(model.selectedDisplay?.id == displays[0].id, "back across the opposite edge")
        let back = try #require(session.receivedInput.compactMap(\.pointer).last { $0.display == displays[0].id })
        #expect(back.position.x <= Double(displays[0].pixelSize.width - 1))
        #expect(model.uiState.pointer.x < Double(displays[0].pixelSize.width - 1), "and on into it")

        // Further left there is no display: the pointer stays at the edge.
        stroke(model, dx: -1200, time: &time)
        #expect(model.selectedDisplay?.id == displays[0].id)
        #expect(model.uiState.pointer.x == 0)
        model.disconnect()
    }

    @Test func theEdgeIsTheOneSettingsNames() async throws {
        let fixture = try twoDisplays(edge: .left)
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        let displays = model.layout.displays
        var time = 1.0
        stroke(model, dx: 600, time: &time)
        #expect(model.selectedDisplay?.id == displays[0].id, "the right edge leads nowhere")
        stroke(model, dx: -1200, time: &time)
        #expect(model.selectedDisplay?.id == displays[1].id)
        let arrived = try #require(session.receivedInput.compactMap(\.pointer).first { $0.display == displays[1].id })
        #expect(arrived.position.x == Double(displays[1].pixelSize.width - 1), "in at its right edge")
        stroke(model, dx: 1200, time: &time)
        #expect(model.selectedDisplay?.id == displays[0].id)
        model.disconnect()
    }

    @Test func aHeldButtonStaysHeldAcrossTheEdge() async throws {
        let fixture = try twoDisplays()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        let displays = model.layout.displays
        // Long-press, then move: a drag with the primary button. The touch is stamped long ago, so
        // the long-press timer fires at once.
        var location = ViewPoint(x: 200, y: 150)
        var time = 1.0
        model.handleTouches([TouchSample(id: 1, phase: .began, location: location, timestamp: time)], on: .deck)
        time += 0.6
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<120 {
            time += 0.01
            location.x += 5
            model.handleTouches([TouchSample(id: 1, phase: .moved, location: location, timestamp: time)], on: .deck)
        }
        let arrived = try #require(session.receivedInput.compactMap(\.pointer).first { $0.display == displays[1].id })
        #expect(arrived.buttons == .primary, "a window is dragged from one display to the other")
        model.handleTouches([TouchSample(id: 1, phase: .ended, location: location, timestamp: time + 0.01)], on: .deck)
        let released = try #require(session.receivedInput.compactMap(\.pointer).last)
        #expect(released.display == displays[1].id && released.buttons.isEmpty)
        model.disconnect()
    }

    @Test func withBothDisplaysThePointerMovesToTheMonitor() async throws {
        let fixture = try twoDisplays()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.externalScreenChanged(monitor)
        model.setExternalDisplayMode(.dual)
        let displays = model.layout.displays
        #expect(model.externalDisplay?.id == displays[1].id)
        var time = 1.0

        stroke(model, dx: 600, time: &time)
        #expect(model.selectedDisplay?.id == displays[0].id, "the device keeps its display")
        #expect(model.pointerDisplay?.id == displays[1].id)
        #expect(model.uiState.pointerDisplay == displays[1].id)
        let sent = session.receivedInput.compactMap(\.pointer).last
        #expect(sent?.display == displays[1].id)
        #expect(model.uiState.pointer.x > 0, "and on into the monitor's display")

        for samples in tap(at: ViewPoint(x: 200, y: 150), time: time) { model.handleTouches(samples, on: .stage) }
        #expect(model.pointerDisplay?.id == displays[0].id)
        #expect(session.receivedInput.compactMap(\.pointer).last?.display == displays[0].id)

        stroke(model, dx: 1200, time: &time)
        #expect(model.pointerDisplay?.id == displays[1].id)
        stroke(model, dx: -2400, time: &time)
        #expect(model.pointerDisplay?.id == displays[0].id)
        #expect(model.uiState.pointerDisplay == nil)

        stroke(model, dx: 2400, time: &time)
        #expect(model.uiState.pointerDisplay == displays[1].id)
        model.externalScreenDisconnected()
        #expect(model.uiState.pointerDisplay == nil)
        #expect(model.pointerDisplay?.id == model.selectedDisplay?.id)
        model.disconnect()
    }

    @Test func oneDisplayHasNowhereToGo() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let display = try #require(model.selectedDisplay)
        var time = 1.0
        stroke(model, dx: 1200, time: &time)
        #expect(model.selectedDisplay?.id == display.id)
        #expect(model.uiState.pointer.x == Double(display.pixelSize.width - 1))
        model.disconnect()
    }

    @Test func theEdgeIsKeptInSettings() throws {
        let defaults = UserDefaults(suiteName: "DisplayCrossingTests.\(UUID().uuidString)")!
        #expect(SessionPreferences(defaults: defaults).secondaryDisplayEdge == .right)
        var preferences = SessionPreferences(defaults: defaults)
        preferences.secondaryDisplayEdge = .bottom
        preferences.save(to: defaults)
        #expect(SessionPreferences(defaults: defaults).secondaryDisplayEdge == .bottom)
    }
}
