// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopInteraction
import Testing
@testable import MarionetteKit

@MainActor
@Suite struct RememberedStateTests {
    @Test func aFirstSessionShowsTheWholeInterface() throws {
        let model = try Fixture().makeModel()
        #expect(model.uiState.inputPanel == .hidden)
        #expect(!model.uiState.isKeyboardRequested)
        #expect(model.uiState.deckSurface == nil)
        #expect(!model.uiState.isFullScreen)
        #expect(!model.uiState.areControlsCollapsed)
        #expect(model.uiState.inputMode == .touch)
    }

    @Test func theKeyboardControlShowsAndHidesTheOnScreenInput() throws {
        let fixture = try Fixture()
        let model = fixture.makeModel()
        // With nothing chosen yet, the one in Settings: the system keyboard unless changed.
        model.toggleInputPanel()
        #expect(model.uiState.inputPanel == .systemKeyboard)
        #expect(model.uiState.isKeyboardRequested)
        model.toggleInputPanel()
        #expect(model.uiState.inputPanel == .hidden)
        #expect(!model.uiState.isKeyboardRequested)
        // One chosen from the menu is what the control brings back afterwards.
        model.setInputPanel(.trackpad)
        #expect(model.uiState.deckSurface == .trackpad)
        model.toggleInputPanel()
        #expect(model.uiState.inputPanel == .hidden)
        #expect(model.uiState.deckSurface == nil)
        model.toggleInputPanel()
        #expect(model.uiState.inputPanel == .trackpad)

        var preferences = SessionPreferences(defaults: fixture.defaults)
        preferences.inputPanel = .hidden
        preferences.defaultInputPanel = .deckKeyboard
        preferences.save(to: fixture.defaults)
        let next = fixture.makeModel()
        next.toggleInputPanel()
        #expect(next.uiState.inputPanel == .deckKeyboard)
        #expect(next.uiState.deckSurface == .keyboard)
    }


    @Test func theNextSessionStartsTheWayTheLastOneWasLeft() throws {
        let fixture = try Fixture()
        let first = fixture.makeModel()
        first.setInputPanel(.deckKeyboard)
        first.setFullScreen(true)
        first.setControlsCollapsed(true)
        first.setAccessoryPage(.functionKeys)
        first.setScaleToFit(false)
        first.setInputMode(.trackpad)

        let next = fixture.makeModel()
        #expect(next.uiState.inputPanel == .deckKeyboard)
        #expect(next.uiState.isFullScreen)
        #expect(next.uiState.areControlsCollapsed)
        #expect(next.uiState.accessoryPage == .functionKeys)
        #expect(next.uiState.zoomMode == .actualSize)
        #expect(next.uiState.inputMode == .trackpad)
    }

    /// The picture has the whole screen in full screen or not: the bars and the home indicator come
    /// and go over it, and nothing about the picture changes with them.
    @Test func fullScreenChangesNothingAboutThePicture() async throws {
        let model = try await Fixture().connectedModel()
        let insets = ViewInsets(top: 100, bottom: 34)
        model.stageLayoutChanged(size: CGSize(width: 400, height: 800), safeArea: insets, deviceScale: 2)
        #expect(model.uiState.viewport.safeAreaInsets == ViewInsets.zero)
        #expect(model.uiState.viewport.availableRect.height == 800)
        let before = model.uiState.viewport

        model.setFullScreen(true)
        #expect(model.uiState.viewport == before)
        model.stageLayoutChanged(size: CGSize(width: 400, height: 800), safeArea: insets, deviceScale: 2)
        #expect(model.uiState.viewport == before)

        model.setFullScreen(false)
        #expect(model.uiState.viewport == before)
        model.disconnect()
    }

    @Test func inAWindowTheSessionIsAlwaysFullScreenAndTheSavedChoiceIsLeftAlone() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let insets = ViewInsets(top: 60, bottom: 20)
        model.stageLayoutChanged(size: CGSize(width: 700, height: 500), safeArea: insets, deviceScale: 2)
        #expect(!model.uiState.showsFullScreen)

        model.setWindowed(true)
        #expect(model.uiState.showsFullScreen)
        #expect(!model.uiState.isFullScreen)
        #expect(model.uiState.viewport.safeAreaInsets == ViewInsets.zero)
        // There is no leaving full screen in a window, and no entering it for later either.
        model.setFullScreen(false)
        #expect(model.uiState.showsFullScreen)
        model.setFullScreen(true)
        #expect(!model.uiState.isFullScreen)
        #expect(!SessionPreferences(defaults: fixture.defaults).isFullScreen)
        model.stageLayoutChanged(size: CGSize(width: 900, height: 640), safeArea: insets, deviceScale: 2)
        #expect(model.uiState.viewport.availableRect.width == 900)
        #expect(model.uiState.viewport.availableRect.height == 640)

        // Back to the whole screen: the title bar returns, as the user had it, over the picture.
        model.setWindowed(false)
        #expect(!model.uiState.showsFullScreen)
        #expect(model.uiState.viewport.safeAreaInsets == ViewInsets.zero)

        // A user who chose full screen keeps it through a spell in a window.
        model.setFullScreen(true)
        model.setWindowed(true)
        model.setWindowed(false)
        #expect(model.uiState.isFullScreen)
        #expect(SessionPreferences(defaults: fixture.defaults).isFullScreen)
        model.disconnect()
    }

    @Test func foldedLikeALaptopTheLowerPaneFollowsTheKeyboardControl() throws {
        let fixture = try Fixture()
        let model = fixture.makeModel()
        model.setInputPanel(.systemKeyboard)
        model.setDeckDocked(true)
        // The pane below the fold is always in use: the system keyboard becomes the Mac keyboard.
        #expect(!model.uiState.isKeyboardRequested)
        #expect(model.uiState.inputPanel == .deckKeyboard)
        #expect(model.uiState.deckSurface == .keyboard)
        // The pointer control is the picture's own business; the pane does not follow it.
        model.setInputMode(.trackpad)
        #expect(model.uiState.deckSurface == .keyboard)
        // The two the pane cannot hold cannot be chosen.
        model.setInputPanel(.hidden)
        model.setInputPanel(.systemKeyboard)
        #expect(model.uiState.inputPanel == .deckKeyboard)
        // Unfolded, the panel docking replaced is back, and it was what stayed remembered.
        #expect(SessionPreferences(defaults: fixture.defaults).inputPanel == .systemKeyboard)
        model.setDeckDocked(false)
        #expect(model.uiState.inputPanel == .systemKeyboard)
        #expect(model.uiState.isKeyboardRequested)

        // Docked again, the keyboard control switches between the trackpad and the Mac keyboard only.
        model.setDeckDocked(true)
        model.toggleInputPanel()
        #expect(model.uiState.deckSurface == .trackpad)
        model.toggleInputPanel()
        #expect(model.uiState.deckSurface == .keyboard)
        model.setDeckDocked(false)

        // Nothing at the bottom becomes the trackpad.
        model.setInputPanel(.hidden)
        model.setDeckDocked(true)
        #expect(model.uiState.deckSurface == .trackpad)
        // Switching the lower pane is about that pane only: unfolded, nothing is at the bottom
        // again, and the keyboard control still brings up what it did before.
        model.toggleInputPanel()
        #expect(model.uiState.deckSurface == .keyboard)
        model.setDeckDocked(false)
        #expect(model.uiState.inputPanel == .hidden)
        #expect(SessionPreferences(defaults: fixture.defaults).inputPanel == .hidden)
        #expect(model.panelForKeyboardControl == .systemKeyboard)
        model.toggleInputPanel()
        #expect(model.uiState.inputPanel == .systemKeyboard)
    }

    @Test func dockingFoldsTheControlStripAwayAndUnfoldingBringsItBack() throws {
        let fixture = try Fixture()
        let model = fixture.makeModel()
        #expect(!model.uiState.areControlsCollapsed)
        model.setDeckDocked(true)
        #expect(model.uiState.areControlsCollapsed)
        // Folding the strip away by itself is not the user's choice, and is not kept as one.
        #expect(!SessionPreferences(defaults: fixture.defaults).areControlsCollapsed)
        model.setDeckDocked(false)
        #expect(!model.uiState.areControlsCollapsed)

        // A choice made while docked is the user's, and stays.
        model.setDeckDocked(true)
        model.setControlsCollapsed(false)
        model.setDeckDocked(false)
        #expect(!model.uiState.areControlsCollapsed)
        model.setDeckDocked(true)
        model.setControlsCollapsed(false)
        model.setControlsCollapsed(true)
        model.setDeckDocked(false)
        #expect(model.uiState.areControlsCollapsed)
        #expect(SessionPreferences(defaults: fixture.defaults).areControlsCollapsed)
    }

    @Test func theHandleOfACollapsedStripFadesAndATouchBringsItBack() async throws {
        var fixture = try Fixture()
        fixture.controlsHandleTimeout = .milliseconds(40)
        let model = try await fixture.connectedModel()
        model.setControlsCollapsed(true)
        #expect(model.uiState.isControlsHandleVisible)
        try await waitUntil { !model.uiState.isControlsHandleVisible }

        for samples in tap(at: ViewPoint(x: 10, y: 10)) { model.handleTouches(samples, on: .stage) }
        #expect(model.uiState.isControlsHandleVisible)
        try await waitUntil { !model.uiState.isControlsHandleVisible }

        // A mouse or trackpad does not: with one attached, nothing needs to be on screen.
        model.pointerMoved(to: ViewPoint(x: 50, y: 50))
        #expect(!model.uiState.isControlsHandleVisible)

        model.setControlsCollapsed(false)
        #expect(model.uiState.isControlsHandleVisible)
        try await Task.sleep(for: .milliseconds(120))
        #expect(model.uiState.isControlsHandleVisible)
        #expect(!model.uiState.areControlsCollapsed)
        model.disconnect()
    }

    @Test func muteIsRemembered() throws {
        let fixture = try Fixture()
        fixture.makeModel().setAudioMuted(true)
        #expect(SessionPreferences(defaults: fixture.defaults).isAudioMuted)
    }

    @Test func aPinchedZoomIsNotRememberedButTheModeBeforeItIs() throws {
        let fixture = try Fixture()
        let first = fixture.makeModel()
        first.setZoomMode(.actualSize)
        first.uiState.viewport.setMode(.free)
        first.setInputPanel(.trackpad)   // saves again while the zoom is free
        #expect(fixture.makeModel().uiState.zoomMode == .actualSize)
    }

    @Test func aComputerFoundOnTheNetworkIsSavedWhenTheUserKeepsItsPassword() async throws {
        var fixture = try Fixture(savePassword: false)
        fixture.computer = ComputerConfiguration(name: "Found Mac", host: "found.local")
        let model = fixture.makeModel()
        #expect(!model.prompts.isComputerSaved)
        model.start()
        try await waitUntil { model.prompts.pending != nil }
        model.prompts.reply(.credentials(username: "demo", password: "demo"), remember: true)
        try await waitUntil { model.phase == .connected }

        let saved = try #require(fixture.repository.record(id: model.computer.id))
        #expect(saved.configuration.host == "found.local")
        #expect(saved.configuration.username == "demo")
        #expect(saved.lastConnected != nil)
        #expect(try fixture.secrets.secret(for: .remoteDesktopPassword(for: model.computer)) == "demo")
        #expect(model.prompts.isComputerSaved)
        model.disconnect()
    }

    @Test func aComputerFoundOnTheNetworkIsLeftOutWhenTheUserDoesNotKeepIt() async throws {
        var fixture = try Fixture(savePassword: false)
        fixture.computer = ComputerConfiguration(name: "Found Mac", host: "found.local")
        let model = fixture.makeModel()
        model.start()
        try await waitUntil { model.prompts.pending != nil }
        model.prompts.reply(.credentials(username: "demo", password: "demo"), remember: false)
        try await waitUntil { model.phase == .connected }

        #expect(fixture.repository.record(id: model.computer.id) == nil)
        #expect(try fixture.secrets.secret(for: .remoteDesktopPassword(for: model.computer)) == nil)
        model.disconnect()
    }

    @Test func theAddressDemoIsTheDemo() {
        #expect(ComputerConfiguration(host: "demo").isDemoAddress)
        #expect(ComputerConfiguration(host: " Demo ").isDemoAddress)
        #expect(!ComputerConfiguration(host: "demo.local").isDemoAddress)
        #expect(!ComputerConfiguration.demo.isDemoAddress)
    }
}
