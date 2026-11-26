// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopInteraction
import RemoteDesktopSimulated
import Testing
@testable import MarionetteKit

@MainActor
@Suite struct ExternalDisplayTests {
    private let monitor = ExternalScreen(size: ViewSize(width: 1920, height: 1080), scale: 1)

    @Test func nothingIsOfferedWithoutAMonitor() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        #expect(model.availableExternalDisplayModes.isEmpty)
        #expect(model.externalDisplay == nil)
        model.setExternalDisplayMode(.externalOnly)
        #expect(model.externalDisplayMode == .mirror)
        model.disconnect()
    }

    @Test func oneDisplayOffersMirrorAndExternalOnly() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        model.externalScreenChanged(monitor)
        #expect(model.availableExternalDisplayModes == [.mirror, .externalOnly])
        #expect(model.externalDisplayMode == .mirror)
        #expect(model.externalDisplay == nil, "the system mirrors; Marionette draws nothing there")
        model.setExternalDisplayMode(.dual)
        #expect(model.externalDisplayMode == .mirror, "Both Displays needs two")
        model.disconnect()
    }

    @Test func externalOnlyMovesThePictureAndForcesTrackpadMode() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        #expect(model.uiState.inputMode == .touch)
        model.externalScreenChanged(monitor, preferredMode: .externalOnly)
        #expect(model.externalDisplayMode == .externalOnly)
        #expect(model.externalDisplay?.id == model.selectedDisplay?.id)
        #expect(model.uiState.inputMode == .trackpad)
        model.setInputMode(.touch)
        #expect(model.uiState.inputMode == .trackpad, "touch mode cannot point at a picture that is elsewhere")

        // The display (2560×1600 in the fast scenario, quartered) is fitted to 1920×1080, centred.
        let frame = try #require(model.externalContentFrame)
        #expect(abs(frame.height - 1080) < 0.5)
        #expect(abs(frame.width - 1080 * 1.6) < 0.5)
        #expect(abs(frame.x - (1920 - 1728) / 2) < 0.5 && abs(frame.y) < 0.5)

        try await waitUntil { model.externalRenderer.hasFrame }

        // Unplugged: back to the device, with the input mode the user had, which was never saved over.
        model.externalScreenDisconnected()
        #expect(model.externalDisplayMode == .mirror)
        #expect(model.uiState.inputMode == .touch)
        #expect(model.availableExternalDisplayModes.isEmpty)
        model.disconnect()
        #expect(SessionPreferences(defaults: fixture.defaults).inputMode == .touch)
    }

    @Test func closingDuringExternalOnlySavesTheUsersInputMode() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        model.externalScreenChanged(monitor, preferredMode: .externalOnly)
        model.disconnect()
        #expect(SessionPreferences(defaults: fixture.defaults).inputMode == .touch)
    }

    @Test func dualShowsTheOtherDisplayAndFollowsTheDevicesChoice() async throws {
        var scenario = fastScenario(.twoDisplays)
        scenario.playsTone = false
        let fixture = try Fixture([scenario])
        let model = try await fixture.connectedModel()
        model.externalScreenChanged(monitor)
        #expect(model.availableExternalDisplayModes == [.mirror, .externalOnly, .dual])
        model.setExternalDisplayMode(.dual)
        let displays = model.layout.displays
        #expect(model.selectedDisplay?.id == displays[0].id)
        #expect(model.externalDisplay?.id == displays[1].id)
        #expect(model.uiState.inputMode == .touch, "each screen has its own picture; touch still works")
        try await waitUntil { model.externalRenderer.hasFrame }

        model.selectDisplay(displays[1].id)
        #expect(model.externalDisplay?.id == displays[0].id)
        // The first display is 16:10: pillarboxed on the 16:9 monitor.
        let frame = try #require(model.externalContentFrame)
        #expect(abs(frame.width - 1728) < 0.5 && abs(frame.height - 1080) < 0.5)
        model.selectDisplay(displays[0].id)
        // The second display is 16:9 like the monitor: it fills it exactly.
        let full = try #require(model.externalContentFrame)
        #expect(abs(full.width - 1920) < 0.5 && abs(full.height - 1080) < 0.5)
        model.disconnect()
    }

    @Test func aMonitorAttachedWhileConnectingGetsBothDisplaysOnceThereAreTwo() async throws {
        let fixture = try Fixture([fastScenario(.twoDisplays)])
        let model = fixture.makeModel()
        model.externalScreenChanged(monitor, preferredMode: .dual)
        #expect(model.externalDisplayMode == .mirror, "no layout yet")
        model.start()
        try await waitUntil { model.externalDisplayMode == .dual }
        #expect(model.externalDisplay?.id == model.layout.displays[1].id)
        model.disconnect()
    }

    @Test func aMonitorWithoutSystemMirroringShowsTheDevicesPicture() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        model.externalScreenChanged(monitor, preferredMode: .mirror, mirrorsPicture: true)
        #expect(model.externalDisplayMode == .mirror)
        #expect(model.externalDisplay?.id == model.selectedDisplay?.id)
        #expect(model.uiState.inputMode == .touch)
        model.disconnect()
    }

    @Test func aFittedDisplayIsSizedForTheMonitorWhileThePictureIsThere() async throws {
        var fixture = try Fixture()
        fixture.computer.display = .fitToDevice
        let model = try await fixture.connectedModel()
        model.stageLayoutChanged(size: CGSize(width: 402, height: 874), safeArea: .zero, deviceScale: 3)
        try await waitUntil(timeout: .seconds(10)) { (model.selectedDisplay?.pixelSize.height ?? 0) > (model.selectedDisplay?.pixelSize.width ?? 0) }
        model.externalScreenChanged(monitor, preferredMode: .externalOnly)
        try await waitUntil(timeout: .seconds(10)) {
            guard let size = model.selectedDisplay?.pointSize else { return false }
            return abs(size.width / size.height - 1920.0 / 1080.0) < 0.02
        }
        model.disconnect()
    }

    /// Secondary Display: two virtual displays from the start, the second one put on a monitor and
    /// sized for it when one comes, and like the first again when it goes.
    @Test func aSecondaryDisplayIsMadeAtTheStartAndGoesToTheMonitor() async throws {
        var fixture = try Fixture()
        fixture.computer.display = .fitToDevice
        fixture.computer.hasSecondaryDisplay = true
        let model = fixture.makeModel()
        // The pane is known before connecting, as the session screen reports it while connecting.
        model.stageLayoutChanged(size: CGSize(width: 1032, height: 1376), safeArea: .zero, deviceScale: 2)
        model.start()
        try await waitUntil { model.phase == .connected }
        #expect(model.layout.displays.count == 2)
        #expect(model.layout.displays.allSatisfy { $0.kind == .virtual })
        #expect(model.layout.displays[0].pixelSize == model.layout.displays[1].pixelSize, "without a monitor, like the first")

        model.externalScreenChanged(monitor, preferredMode: .mirror)
        try await waitUntil(timeout: .seconds(10)) { model.externalDisplayMode == .dual }
        try await waitUntil(timeout: .seconds(10)) { model.layout.displays.count == 2 && model.layout.displays[1].pixelSize == PixelSize(width: 1920, height: 1080) }
        #expect(model.externalDisplay?.id == model.layout.displays[1].id)

        model.externalScreenDisconnected()
        try await waitUntil(timeout: .seconds(10)) { model.layout.displays.count == 2 && model.layout.displays[1].pixelSize == model.layout.displays[0].pixelSize }
        model.disconnect()
    }

    // MARK: HDR

    /// A display is HDR when the screen that shows it can show HDR; the session's window moving to
    /// such a screen, or off it, asks again.
    @Test func theDisplayFollowsTheWindowsScreen() async throws {
        var fixture = try Fixture()
        fixture.computer.display = .fitToDevice
        let model = fixture.makeModel()
        model.stageLayoutChanged(size: CGSize(width: 1032, height: 1376), safeArea: .zero, deviceScale: 2)
        model.windowScreenChanged(showsHDR: true)
        model.start()
        try await waitUntil { model.phase == .connected }
        #expect(model.selectedDisplay?.isHDR == true, "asked for in HDR from the start")
        #expect(model.isShowingHDR)

        model.windowScreenChanged(showsHDR: false)
        try await waitUntil(timeout: .seconds(10)) { model.selectedDisplay?.isHDR == false }
        #expect(!model.isShowingHDR)
        model.windowScreenChanged(showsHDR: true)
        try await waitUntil(timeout: .seconds(10)) { model.selectedDisplay?.isHDR == true }
        model.disconnect()
    }

    /// With two displays, each follows its own screen: the first the window's, the secondary the
    /// monitor's while there is one.
    @Test func eachDisplayFollowsItsOwnScreen() async throws {
        var fixture = try Fixture()
        fixture.computer.display = .fitToDevice
        fixture.computer.hasSecondaryDisplay = true
        let model = fixture.makeModel()
        model.stageLayoutChanged(size: CGSize(width: 1032, height: 1376), safeArea: .zero, deviceScale: 2)
        model.windowScreenChanged(showsHDR: true)
        model.start()
        try await waitUntil { model.phase == .connected }
        #expect(model.layout.displays.map(\.isHDR) == [true, true], "without a monitor both are the window's")

        model.externalScreenChanged(ExternalScreen(size: monitor.size, scale: monitor.scale, showsHDR: false), preferredMode: .mirror)
        try await waitUntil(timeout: .seconds(10)) { model.layout.displays.map(\.isHDR) == [true, false] }

        // The same monitor, now in HDR (its own setting changed).
        model.externalScreenChanged(ExternalScreen(size: monitor.size, scale: monitor.scale, showsHDR: true))
        try await waitUntil(timeout: .seconds(10)) { model.layout.displays.map(\.isHDR) == [true, true] }

        model.externalScreenDisconnected()
        model.windowScreenChanged(showsHDR: false)
        try await waitUntil(timeout: .seconds(10)) { model.layout.displays.map(\.isHDR) == [false, false] }
        model.disconnect()
    }

    /// The window's screen is often reported only once the connection is under way; the displays
    /// asked for at the start are then asked for again, in HDR, as soon as the session is up.
    @Test(arguments: [false, true])
    func anHDRScreenReportedWhileConnectingStillGetsHDR(secondaryDisplay: Bool) async throws {
        var fixture = try Fixture()
        fixture.computer.display = .fitToDevice
        fixture.computer.hasSecondaryDisplay = secondaryDisplay
        let model = fixture.makeModel()
        model.stageLayoutChanged(size: CGSize(width: 1032, height: 1376), safeArea: .zero, deviceScale: 2)
        model.start()
        try await waitUntil { model.connectionProgress >= 1 }
        model.windowScreenChanged(showsHDR: true)
        try await waitUntil { model.phase == .connected }
        try await waitUntil(timeout: .seconds(10)) { !model.layout.displays.isEmpty && model.layout.displays.allSatisfy(\.isHDR) }
        #expect(model.layout.displays.count == (secondaryDisplay ? 2 : 1))
        model.disconnect()
    }

    /// High Dynamic Range can be turned off, which makes the displays SDR at once, and stays off for
    /// the next session.
    @Test func highDynamicRangeCanBeTurnedOffAndStaysOff() async throws {
        var fixture = try Fixture()
        fixture.computer.display = .fitToDevice
        let model = fixture.makeModel()
        #expect(model.isHDREnabled, "on by default")
        model.stageLayoutChanged(size: CGSize(width: 1032, height: 1376), safeArea: .zero, deviceScale: 2)
        model.windowScreenChanged(showsHDR: true)
        model.start()
        try await waitUntil { model.phase == .connected }
        #expect(model.offersHDR)
        #expect(model.selectedDisplay?.isHDR == true)

        model.setHDREnabled(false)
        try await waitUntil(timeout: .seconds(10)) { model.selectedDisplay?.isHDR == false }
        model.disconnect()
        #expect(SessionPreferences(defaults: fixture.defaults).isHDREnabled == false)

        let next = fixture.makeModel()
        #expect(!next.isHDREnabled)
        next.stageLayoutChanged(size: CGSize(width: 1032, height: 1376), safeArea: .zero, deviceScale: 2)
        next.windowScreenChanged(showsHDR: true)
        next.start()
        try await waitUntil { next.phase == .connected }
        #expect(next.selectedDisplay?.isHDR == false)
        next.setHDREnabled(true)
        try await waitUntil(timeout: .seconds(10)) { next.selectedDisplay?.isHDR == true }
        next.disconnect()
    }

    /// Without a screen that can show HDR the option can do nothing: the menus show it off and
    /// disabled. Only the screens a display is shown on count: in External Only the device's own
    /// screen shows none, however capable.
    @Test func highDynamicRangeNeedsAScreenThatShowsIt() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        #expect(model.isHDREnabled)
        #expect(!model.canShowHDR)
        model.externalScreenChanged(ExternalScreen(size: monitor.size, scale: monitor.scale, showsHDR: true), preferredMode: .externalOnly)
        #expect(model.canShowHDR)
        model.externalScreenDisconnected()
        #expect(!model.canShowHDR)
        model.windowScreenChanged(showsHDR: true)
        #expect(model.canShowHDR)
        // An AirPlay display without HDR takes the picture away from the HDR screen.
        model.externalScreenChanged(monitor, preferredMode: .externalOnly)
        #expect(model.externalDisplayMode == .externalOnly)
        #expect(!model.canShowHDR)
        model.disconnect()
    }

    /// A session that cannot give HDR pictures makes the option unavailable, however capable the
    /// screen.
    @Test func highDynamicRangeNeedsASessionThatGivesIt() async throws {
        var scenario = fastScenario(.highPerformance)
        scenario.makesHDRDisplays = false
        let fixture = try Fixture([scenario])
        let model = try await fixture.connectedModel()
        model.windowScreenChanged(showsHDR: true)
        #expect(model.offersHDR)
        #expect(model.canShowHDR)
        #expect(!model.isHDRAvailable)
        model.disconnect()
    }

    /// In External Only the picture is on the monitor, so the monitor decides.
    @Test func externalOnlyFollowsTheMonitor() async throws {
        var fixture = try Fixture()
        fixture.computer.display = .fitToDevice
        let model = fixture.makeModel()
        model.stageLayoutChanged(size: CGSize(width: 402, height: 874), safeArea: .zero, deviceScale: 3)
        model.windowScreenChanged(showsHDR: true)
        model.start()
        try await waitUntil { model.phase == .connected }
        #expect(model.selectedDisplay?.isHDR == true)
        model.externalScreenChanged(monitor, preferredMode: .externalOnly)
        try await waitUntil(timeout: .seconds(10)) { model.selectedDisplay?.isHDR == false }
        model.externalScreenDisconnected()
        try await waitUntil(timeout: .seconds(10)) { model.selectedDisplay?.isHDR == true }
        model.disconnect()
    }

    @Test func retinaCanBeTurnedOff() async throws {
        var fixture = try Fixture()
        fixture.computer.display = .fitToDevice
        fixture.computer.prefersRetina = false
        let model = fixture.makeModel()
        model.stageLayoutChanged(size: CGSize(width: 1032, height: 1376), safeArea: .zero, deviceScale: 2)
        model.start()
        try await waitUntil { model.phase == .connected }
        #expect(model.selectedDisplay?.scale == 1)
        model.disconnect()
    }
}
