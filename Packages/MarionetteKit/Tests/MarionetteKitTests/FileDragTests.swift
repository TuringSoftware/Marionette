// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopInteraction
import RemoteDesktopSimulated
import Testing
@testable import MarionetteKit

private func staged(_ name: String, contents: String = "contents") throws -> StagedUpload {
    let folder = FileManager.default.temporaryDirectory.appending(path: "FileDragTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appending(path: name)
    try Data(contents.utf8).write(to: source)
    return try StagedUpload(copying: source)
}

private func exists(_ copy: StagedUpload) -> Bool {
    FileManager.default.fileExists(atPath: copy.file.path)
}

private func centre(_ rect: PixelRect) -> PixelPoint {
    PixelPoint(x: Double(rect.x) + Double(rect.width) / 2, y: Double(rect.y) + Double(rect.height) / 2)
}

@MainActor
@Suite struct OutgoingFileDragTests {
    /// The connected model is laid out in a 400×300 pt view; its 640×400 display is fitted, which
    /// leaves 25 pt of black above and below the picture.
    private let besideThePicture = ViewPoint(x: 200, y: 10)

    @Test func aDragOverThePictureEntersMovesAndLandsInTheFolderItIsLetGoOver() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        let display = try #require(session.layout.displays.first)
        let viewport = model.uiState.viewport
        let folder = centre(try #require(session.desktopFolderFrame(on: display.id)))
        let (entry, across) = (ViewPoint(x: 50, y: 150), ViewPoint(x: 120, y: 160))
        let names = ["Report.pdf", "Notes.txt"]

        #expect(model.fileDrags.dragMoved(names: names, to: entry) == .copy)
        #expect(model.fileDrags.dragMoved(names: names, to: across) == .copy)
        #expect(model.uiState.pointer == viewport.remotePoint(for: across), "the remote pointer goes along")

        let copies = [try staged("Report.pdf"), try staged("Notes.txt")]
        #expect(model.fileDrags.drop(names: names, at: viewport.viewPoint(for: folder)) { copies })
        try await waitUntil { model.transfers.items.count == 2 && !model.transfers.hasActiveTransfers }

        #expect(session.fileDragEvents == [
            .began(names: names, display: display.id, position: viewport.remotePoint(for: entry)),
            .moved(display: display.id, position: viewport.remotePoint(for: across)),
            .moved(display: display.id, position: folder),
            .dropped(folder: "/Users/demo/Documents"),
        ])
        #expect(model.transfers.items.map(\.state) == [.finished, .finished])
        let files = try #require(session.capabilities.fileTransfer.value)
        let listed = try await files.list(directory: "/Users/demo/Documents").map(\.name)
        #expect(listed.contains("Report.pdf") && listed.contains("Notes.txt"))
        #expect(!exists(copies[0]) && !exists(copies[1]), "the copies go once they are sent")
        #expect(model.banner == nil)
        model.disconnect()
    }

    @Test func besideThePictureTheDragIsNotOverTheRemoteMachine() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        let inside = ViewPoint(x: 200, y: 150)

        #expect(model.fileDrags.dragMoved(names: ["a.txt"], to: besideThePicture) == .forbidden)
        #expect(session.fileDragEvents.isEmpty)
        #expect(model.fileDrags.dragMoved(names: ["a.txt"], to: inside) == .copy)
        #expect(model.fileDrags.dragMoved(names: ["a.txt"], to: besideThePicture) == .forbidden)
        #expect(session.fileDragEvents.last == .cancelled, "leaving the picture ends the remote machine's drag")
        // Coming back starts it again; leaving the session's view ends it for good.
        #expect(model.fileDrags.dragMoved(names: ["a.txt"], to: inside) == .copy)
        model.fileDrags.dragExited()
        #expect(session.fileDragEvents.map { event -> String in
            switch event {
            case .began: "began"
            case .cancelled: "cancelled"
            default: "other"
            }
        } == ["began", "cancelled", "began", "cancelled"])
        #expect(!model.fileDrags.drop(names: ["a.txt"], at: besideThePicture) { [] })
        model.disconnect()
    }

    @Test func aDropWhereNothingTakesFilesSendsNothingAndSaysWhy() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        let copy = try staged("a.txt")

        #expect(model.fileDrags.drop(names: ["a.txt"], at: ViewPoint(x: 60, y: 200)) { [copy] })
        try await waitUntil { model.banner != nil }
        #expect(session.fileDragEvents.last == .dropped(folder: nil))
        #expect(model.banner?.title == "Not Copied")
        #expect(model.banner?.message == "Drop files on a folder or the desktop.")
        try await waitUntil { !exists(copy) }
        #expect(model.transfers.items.isEmpty)
        model.disconnect()
    }

    @Test func aSessionWithoutDragsSendsADropToItsDefaultFolder() async throws {
        var scenario = fastScenario()
        scenario.fileDrags = nil
        let fixture = try Fixture([scenario])
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        #expect(!model.fileDrags.isAvailable)
        // Where it is let go does not matter: there is no place on the remote machine to aim at.
        #expect(model.fileDrags.dragMoved(names: ["a.txt"], to: besideThePicture) == .copy)
        let copy = try staged("a.txt")
        #expect(model.fileDrags.drop(names: ["a.txt"], at: besideThePicture) { [copy] })
        try await waitUntil { model.transfers.items.first?.state == .finished }
        let files = try #require(session.capabilities.fileTransfer.value)
        #expect(try await files.list(directory: try await files.defaultUploadDirectory()).map(\.name) == ["a.txt"])
        #expect(session.fileDragEvents.isEmpty)
        model.disconnect()
    }

    @Test func aSessionThatCannotMoveFilesRefusesTheDrag() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.files.setBuiltIn(nil)
        #expect(model.fileDrags.dragMoved(names: ["a.txt"], to: ViewPoint(x: 200, y: 150)) == .forbidden)
        #expect(!model.fileDrags.drop(names: ["a.txt"], at: ViewPoint(x: 200, y: 150)) { [] })
        #expect(session.fileDragEvents.isEmpty)
        model.disconnect()
    }

    @Test func theSessionEndingEndsADragUnderWay() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        #expect(model.fileDrags.dragMoved(names: ["a.txt"], to: ViewPoint(x: 200, y: 150)) == .copy)
        model.disconnect()
        #expect(session.fileDragEvents.last == .cancelled)
        #expect(!model.fileDrags.holdsRemotePointer)
        #expect(model.fileDrags.dragMoved(names: ["a.txt"], to: ViewPoint(x: 200, y: 150)) == .forbidden)
    }

    @Test func aDropTheSessionEndsOnSendsNothing() async throws {
        var scenario = fastScenario()
        scenario.fileDrags?.refusalDelay = .seconds(600)
        var fixture = try Fixture([scenario])
        fixture.reconnection = ReconnectionPolicy(attempts: 0)
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        let copy = try staged("a.txt")
        #expect(model.fileDrags.drop(names: ["a.txt"], at: ViewPoint(x: 60, y: 200)) { [copy] })
        try await waitUntil { session.fileDragEvents.last == .dropped(folder: nil) }
        session.simulateDisconnect(.connectionLost(detail: ""))
        try await waitUntil { !exists(copy) }
        #expect(model.transfers.items.isEmpty)
        #expect(model.banner == nil, "the session's end says enough")
    }

    @Test func theSessionsOwnPointerWaitsWhileADragHoldsTheRemoteButton() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        #expect(model.fileDrags.dragMoved(names: ["a.txt"], to: ViewPoint(x: 200, y: 150)) == .copy)
        // A click from here would let go of the button the remote machine's drag hangs on.
        model.pointerButtons(.primary, at: ViewPoint(x: 100, y: 100))
        model.pointerButtons([], at: ViewPoint(x: 100, y: 100))
        #expect(session.receivedInput.compactMap(\.pointer).isEmpty)
        model.fileDrags.dragExited()
        model.pointerButtons(.primary, at: ViewPoint(x: 100, y: 100))
        model.pointerButtons([], at: ViewPoint(x: 100, y: 100))
        #expect(session.receivedInput.compactMap(\.pointer).map(\.buttons).contains(.primary))
        model.disconnect()
    }

    @Test func lettingGoOfAllInputEndsADragUnderWay() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        #expect(model.fileDrags.dragMoved(names: ["a.txt"], to: ViewPoint(x: 200, y: 150)) == .copy)
        model.sceneDidResignActive()
        #expect(session.fileDragEvents.last == .cancelled)
        model.disconnect()
    }

    @Test func itemsThatCouldNotBeReadAreMentioned() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        let display = try #require(session.layout.displays.first)
        let folder = model.uiState.viewport.viewPoint(for: centre(try #require(session.desktopFolderFrame(on: display.id))))
        let copy = try staged("a.txt")
        #expect(model.fileDrags.drop(names: ["a.txt", "b.txt", "c.txt"], at: folder) { [copy] })
        try await waitUntil { model.banner != nil }
        #expect(model.banner?.title == "2 Items Couldn’t Be Read")
        #expect(model.transfers.items.map(\.name) == ["a.txt"])
        model.disconnect()
    }

    @Test func withThePictureOnTheMonitorADropGoesToTheDefaultFolder() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.externalScreenChanged(ExternalScreen(size: ViewSize(width: 1920, height: 1080), scale: 1), preferredMode: .externalOnly)
        #expect(model.externalDisplayMode == .externalOnly)
        // The device is a trackpad now: nothing under the finger says where on the Mac this is.
        let copy = try staged("a.txt")
        #expect(model.fileDrags.drop(names: ["a.txt"], at: ViewPoint(x: 200, y: 150)) { [copy] })
        try await waitUntil { model.transfers.items.first?.state == .finished }
        #expect(session.fileDragEvents.isEmpty)
        let files = try #require(session.capabilities.fileTransfer.value)
        #expect(try await files.list(directory: "/Users/demo/Downloads").map(\.name) == ["a.txt"])
        model.disconnect()
    }
}

@MainActor
@Suite struct RemoteFileDragTests {
    private let paths = ["/Users/demo/Documents/Readme.txt", "/Users/demo/Documents/Notes.txt"]
    /// Inside the picture of the 400×300 pt view the connected model is laid out in.
    private let well = ViewRect(x: 120, y: 40, width: 160, height: 50)
    private let onTheWell = ViewPoint(x: 200, y: 60)
    private let elsewhere = ViewPoint(x: 200, y: 200)

    private func fixture() throws -> (Fixture, URL) {
        var fixture = try Fixture()
        let downloads = FileManager.default.temporaryDirectory.appending(path: "RemoteFileDragTests-\(UUID().uuidString)")
        fixture.downloadsDirectory = downloads
        return (fixture, downloads)
    }

    /// Puts a finger down and keeps it still until the press is long: moving it then drags with
    /// the primary button, in touch mode and in trackpad mode alike.
    private func longPress(_ model: SessionModel, at location: ViewPoint) async throws {
        var isLong = false
        model.onFeedback = { if $0 == .longPress { isLong = true } }
        model.handleTouches([TouchSample(id: 1, phase: .began, location: location, timestamp: ProcessInfo.processInfo.systemUptime)], on: .stage)
        try await waitUntil { isLong }
    }

    @Test func aDragOnTheRemoteMachineIsShownUntilItEnds() async throws {
        let (fixture, _) = try fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        #expect(model.fileDrags.remoteDrag == nil)
        session.simulateRemoteDrag(paths: paths)
        try await waitUntil { model.fileDrags.remoteDrag != nil }
        #expect(model.fileDrags.remoteDrag?.paths == paths)
        #expect(model.fileDrags.remoteDrag?.previewPNG != nil)
        session.simulateRemoteDragEnd()
        try await waitUntil { model.fileDrags.remoteDrag == nil }
        #expect(model.transfers.items.isEmpty)
        model.disconnect()
    }

    @Test func lettingGoOverTheWellTakesTheDragBeforeTheButtonComesUpAndFetchesTheFiles() async throws {
        let (fixture, downloads) = try fixture()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.fileDrags.setDropWellFrame(well)
        session.simulateRemoteDrag(paths: paths)
        try await waitUntil { model.fileDrags.remoteDrag != nil }

        model.pointerButtons(.primary, at: elsewhere)
        #expect(!model.fileDrags.isPointerOverDropWell)
        model.pointerMoved(to: onTheWell)
        #expect(model.fileDrags.isPointerOverDropWell)
        model.pointerButtons([], at: onTheWell)

        // Had the release reached the machine first, it would have dropped the files itself.
        #expect(session.fileDragEvents == [.remoteDragStarted(paths: paths), .remoteDragTaken])
        #expect(session.receivedInput.compactMap(\.pointer).last?.buttons == [])
        #expect(model.fileDrags.remoteDrag == nil)
        #expect(!model.fileDrags.isPointerOverDropWell)

        #expect(model.transfers.items.map(\.name) == ["Readme.txt", "Notes.txt"])
        #expect(model.transfers.items.allSatisfy { $0.direction == .download })
        try await waitUntil { !model.transfers.hasActiveTransfers }
        let received = try #require(model.transfers.items.first?.localURL)
        #expect(received == downloads.appending(path: "Readme.txt"))
        #expect(try String(contentsOf: received, encoding: .utf8) == "Hello from the demo Mac.\n")
        model.disconnect()
    }

    @Test func lettingGoAnywhereElseLeavesTheRemoteDragAlone() async throws {
        let (fixture, _) = try fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.fileDrags.setDropWellFrame(well)
        session.simulateRemoteDrag(paths: paths)
        try await waitUntil { model.fileDrags.remoteDrag != nil }

        model.pointerButtons(.primary, at: onTheWell)
        model.pointerMoved(to: elsewhere)
        model.pointerButtons([], at: elsewhere)

        #expect(session.fileDragEvents == [.remoteDragStarted(paths: paths), .remoteDragDropped])
        try await waitUntil { model.fileDrags.remoteDrag == nil }
        #expect(model.transfers.items.isEmpty)
        model.disconnect()
    }

    /// A release the person did not make (the app leaving the foreground here) must neither
    /// fetch the files nor leave the remote machine to drop them where its pointer happens to be.
    @Test func aReleaseTheAppMakesCallsTheRemoteDragOffAndFetchesNothing() async throws {
        for place in [onTheWell, elsewhere] {
            let (fixture, _) = try fixture()
            let model = try await fixture.connectedModel()
            let session = fixture.backend.sessions[0]
            model.fileDrags.setDropWellFrame(well)
            session.simulateRemoteDrag(paths: paths)
            try await waitUntil { model.fileDrags.remoteDrag != nil }
            model.pointerButtons(.primary, at: elsewhere)
            model.pointerMoved(to: place)

            model.sceneDidResignActive()

            #expect(session.fileDragEvents == [.remoteDragStarted(paths: paths), .remoteDragTaken])
            #expect(session.receivedInput.last == .releaseAll)
            #expect(model.fileDrags.remoteDrag == nil)
            #expect(model.transfers.items.isEmpty)
            model.disconnect()
        }
    }

    @Test func touchesTheSystemTakesAwayCallTheRemoteDragOff() async throws {
        let (fixture, _) = try fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        let display = try #require(session.layout.displays.first)
        let file = model.uiState.viewport.viewPoint(for: centre(try #require(session.desktopFileFrame(on: display.id))))
        let well = ViewRect(x: 20, y: 26, width: 120, height: 30)
        model.fileDrags.setDropWellFrame(well)
        try await longPress(model, at: file)
        for location in [ViewPoint(x: (file.x + well.midX) / 2, y: (file.y + well.midY) / 2), well.center] {
            model.handleTouches([TouchSample(id: 1, phase: .moved, location: location, timestamp: ProcessInfo.processInfo.systemUptime)], on: .stage)
        }
        try await waitUntil { model.fileDrags.remoteDrag != nil }
        #expect(model.fileDrags.isPointerOverDropWell)

        model.handleTouches([TouchSample(id: 1, phase: .cancelled, location: well.center, timestamp: ProcessInfo.processInfo.systemUptime)], on: .stage)

        #expect(session.fileDragEvents == [.remoteDragStarted(paths: ["/Users/demo/Documents/Readme.txt"]), .remoteDragTaken])
        #expect(session.receivedInput.compactMap(\.pointer).last?.buttons == [])
        #expect(model.transfers.items.isEmpty)
        model.disconnect()
    }

    /// Someone at the remote machine may be dragging with its own mouse. That drag is theirs
    /// until this session is about to let go of a button on the machine.
    @Test func aDragThisSessionDoesNotHoldIsLeftAloneUntilEverythingIsLetGo() async throws {
        let (fixture, _) = try fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        session.simulateRemoteDrag(paths: paths)
        try await waitUntil { model.fileDrags.remoteDrag != nil }
        // Gestures abandoned with no button down send nothing to the machine.
        model.setInputMode(.trackpad)
        #expect(session.fileDragEvents == [.remoteDragStarted(paths: paths)])
        #expect(model.fileDrags.remoteDrag != nil)
        // Letting go of everything tells the machine to let go, whoever holds the button.
        model.releaseAllInput()
        #expect(session.fileDragEvents == [.remoteDragStarted(paths: paths), .remoteDragTaken])
        #expect(model.transfers.items.isEmpty)
        model.disconnect()
    }

    @Test func aPointerOverTheWellTakesNothingWhileNothingIsDragged() async throws {
        let (fixture, _) = try fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.fileDrags.setDropWellFrame(well)
        model.pointerButtons(.primary, at: onTheWell)
        model.pointerButtons([], at: onTheWell)
        #expect(session.fileDragEvents.isEmpty)
        #expect(model.transfers.items.isEmpty)
        model.disconnect()
    }

    /// The file on the simulated desktop, picked up with a long press and carried to the well by
    /// the finger: touch mode from end to end.
    @Test func aFilePickedUpWithTheFingerIsTakenWhenTheFingerLiftsOverTheWell() async throws {
        let (fixture, downloads) = try fixture()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        let display = try #require(session.layout.displays.first)
        let file = model.uiState.viewport.viewPoint(for: centre(try #require(session.desktopFileFrame(on: display.id))))
        // Where the remote menu bar is: nothing of the simulated desktop is in the way there.
        let well = ViewRect(x: 20, y: 26, width: 120, height: 30)
        model.fileDrags.setDropWellFrame(well)
        #expect(!well.contains(file))

        try await longPress(model, at: file)
        let steps = 8
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            let location = ViewPoint(x: file.x + (well.midX - file.x) * fraction, y: file.y + (well.midY - file.y) * fraction)
            model.handleTouches([TouchSample(id: 1, phase: .moved, location: location, timestamp: ProcessInfo.processInfo.systemUptime)], on: .stage)
        }
        try await waitUntil { model.fileDrags.remoteDrag != nil }
        #expect(model.fileDrags.isPointerOverDropWell)
        model.handleTouches([TouchSample(id: 1, phase: .ended, location: well.center, timestamp: ProcessInfo.processInfo.systemUptime)], on: .stage)

        #expect(session.fileDragEvents == [.remoteDragStarted(paths: ["/Users/demo/Documents/Readme.txt"]), .remoteDragTaken])
        try await waitUntil { model.transfers.items.first?.state == .finished }
        #expect(model.transfers.items.map(\.name) == ["Readme.txt"])
        model.disconnect()
    }

    /// Trackpad mode moves the pointer from where it is; the well is wherever the pointer ends up.
    @Test func theWellWorksInTrackpadModeToo() async throws {
        let (fixture, downloads) = try fixture()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.setInputMode(.trackpad)
        session.simulateRemoteDrag(paths: paths)
        try await waitUntil { model.fileDrags.remoteDrag != nil }

        let finger = ViewPoint(x: 300, y: 250)
        try await longPress(model, at: finger)
        let before = model.uiState.pointer
        for step in 1...6 {
            let location = ViewPoint(x: finger.x - Double(step) * 8, y: finger.y - Double(step) * 6)
            model.handleTouches([TouchSample(id: 1, phase: .moved, location: location, timestamp: ProcessInfo.processInfo.systemUptime)], on: .stage)
        }
        #expect(model.uiState.pointer != before)
        let pointer = model.uiState.viewport.viewPoint(for: model.uiState.pointer)
        #expect(!model.fileDrags.isPointerOverDropWell)
        model.fileDrags.setDropWellFrame(ViewRect(x: pointer.x - 40, y: pointer.y - 20, width: 80, height: 40))
        #expect(model.fileDrags.isPointerOverDropWell)
        model.handleTouches([TouchSample(id: 1, phase: .ended, location: ViewPoint(x: 252, y: 214), timestamp: ProcessInfo.processInfo.systemUptime)], on: .stage)

        #expect(session.fileDragEvents == [.remoteDragStarted(paths: paths), .remoteDragTaken])
        #expect(model.transfers.items.count == 2)
        try await waitUntil { !model.transfers.hasActiveTransfers }
        model.disconnect()
    }

    /// With the picture only on the monitor the device is a trackpad, and the well is on the
    /// monitor, where the pointer can be seen reaching it.
    @Test func withThePictureOnTheMonitorTheWellIsThere() async throws {
        let (fixture, downloads) = try fixture()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        #expect(model.dropWellSurface == .device)
        #expect(model.visiblePicture(on: .device) == ViewRect(x: 0, y: 25, width: 400, height: 250))
        #expect(model.visiblePicture(on: .externalDisplay) == nil)

        model.externalScreenChanged(ExternalScreen(size: ViewSize(width: 1920, height: 1080), scale: 1), preferredMode: .externalOnly)
        #expect(model.dropWellSurface == .externalDisplay)
        // 640×400 fitted into 1920×1080: 1728×1080, centred.
        let picture = try #require(model.visiblePicture(on: .externalDisplay))
        #expect(picture == ViewRect(x: 96, y: 0, width: 1728, height: 1080))
        // A well at the top of the monitor's picture, where remote pixel (320, 30) is at (960, 81).
        model.fileDrags.setDropWellFrame(ViewRect(x: 860, y: 40, width: 200, height: 80))
        session.simulateRemoteDrag(paths: paths)
        try await waitUntil { model.fileDrags.remoteDrag != nil }

        let viewport = model.uiState.viewport
        model.pointerButtons(.primary, at: viewport.viewPoint(for: PixelPoint(x: 320, y: 300)))
        #expect(!model.fileDrags.isPointerOverDropWell)
        model.pointerMoved(to: viewport.viewPoint(for: PixelPoint(x: 320, y: 30)))
        #expect(model.fileDrags.isPointerOverDropWell)
        model.pointerButtons([], at: viewport.viewPoint(for: PixelPoint(x: 320, y: 30)))
        #expect(session.fileDragEvents == [.remoteDragStarted(paths: paths), .remoteDragTaken])
        #expect(model.transfers.items.count == 2)
        try await waitUntil { !model.transfers.hasActiveTransfers }
        model.disconnect()
    }

    @Test func aViewerThatOnlyWatchesIsShownNoDrag() async throws {
        var fixture = try Fixture()
        fixture.computer.observeOnly = true
        let model = try await fixture.connectedModel()
        #expect(!model.fileDrags.isAvailable)
        #expect(model.fileDrags.remoteDrag == nil)
        // Nor can it steer a drag of its own files: they go to the default folder.
        #expect(model.fileDrags.dragMoved(names: ["a.txt"], to: ViewPoint(x: 200, y: 10)) == .copy)
        model.disconnect()
    }

    @Test func theSessionEndingEndsTheRemoteDrag() async throws {
        let (fixture, _) = try fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        session.simulateRemoteDrag(paths: paths)
        try await waitUntil { model.fileDrags.remoteDrag != nil }
        model.disconnect()
        #expect(model.fileDrags.remoteDrag == nil)
    }

    @Test func aDraggedPathBecomesAnEntryToFetch() {
        #expect(FileDragModel.entry(forDraggedPath: "/Users/demo/Pictures/Empty.png") == RemoteFileEntry(path: "/Users/demo/Pictures/Empty.png", name: "Empty.png", isDirectory: false))
        #expect(FileDragModel.entry(forDraggedPath: "/Users/demo/Pictures/") == RemoteFileEntry(path: "/Users/demo/Pictures/", name: "Pictures", isDirectory: true))
    }
}

@MainActor
@Suite struct TransferActivityTests {
    private func connected(_ change: (inout SimulationScenario) -> Void = { _ in }) async throws -> (SessionModel, Fixture) {
        var scenario = fastScenario()
        change(&scenario)
        let fixture = try Fixture([scenario])
        return (try await fixture.connectedModel(), fixture)
    }

    @Test func aRunOfTransfersIsToldFromItsFirstToAMomentAfterItsLast() async throws {
        let (model, _) = try await connected()
        let queue = model.transfers
        queue.activityLinger = .milliseconds(150)
        #expect(queue.activity == nil)
        queue.upload(try staged("a.txt"))
        queue.upload(try staged("b.txt"))
        #expect(queue.activity?.phase == .active(remaining: 2))
        #expect(queue.activity?.direction == .upload)
        #expect(queue.activity?.fraction == 0)
        try await waitUntil { queue.activity?.phase == .active(remaining: 1) }
        #expect((queue.activity?.fraction ?? 0) >= 0.5)
        try await waitUntil { queue.activity?.phase == .finished(count: 2) }
        #expect(queue.activity?.fraction == 1)
        try await waitUntil { queue.activity == nil }
        model.disconnect()
    }

    @Test func transfersBothWaysHaveNoDirectionAndFailuresAreCounted() async throws {
        let (model, _) = try await connected()
        let queue = model.transfers
        queue.activityLinger = .seconds(600)
        queue.upload(try staged("a.txt"))
        queue.download(RemoteFileEntry(path: "/nowhere/Missing.txt", name: "Missing.txt", isDirectory: false), to: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        #expect(queue.activity?.direction == nil)
        try await waitUntil { !queue.hasActiveTransfers }
        #expect(queue.activity?.phase == .failed(count: 1))
        // The next transfer starts a run of its own.
        queue.upload(try staged("b.txt"))
        #expect(queue.activity?.phase == .active(remaining: 1))
        #expect(queue.activity?.direction == .upload)
        try await waitUntil { queue.activity?.phase == .finished(count: 1) }
        model.disconnect()
    }

    @Test func cancellingEverythingLeavesNothingToTell() async throws {
        let (model, _) = try await connected { $0.transferRate = 1 }
        let queue = model.transfers
        let (first, second) = (try staged("a.txt"), try staged("b.txt"))
        let ids = [queue.upload(first), queue.upload(second)]
        try await waitUntil { queue.items.first?.state == .running }
        queue.cancel(ids[1])
        #expect(!exists(second), "a copy that will not be sent goes at once")
        #expect(queue.activity?.phase == .active(remaining: 1))
        queue.cancel(ids[0])
        try await waitUntil { !queue.hasActiveTransfers }
        #expect(queue.activity == nil)
        try await waitUntil { !exists(first) }
        model.disconnect()
    }

    @Test func copiesAreRemovedWhenTheSessionGoesBeforeTheyAreSent() async throws {
        let (model, _) = try await connected { $0.transferRate = 1 }
        let queue = model.transfers
        let (first, second) = (try staged("a.txt"), try staged("b.txt"))
        queue.upload(first)
        queue.upload(second)
        try await waitUntil { queue.items.first?.state == .running }
        model.disconnect()
        try await waitUntil { !queue.hasActiveTransfers }
        try await waitUntil { !exists(first) && !exists(second) }
        #expect(queue.activity?.phase == .failed(count: 2))
        let late = try staged("c.txt")
        queue.upload(late)
        #expect(!exists(late))
        #expect(queue.items.last?.state == .failed(message: "File transfer is not available."))
    }

    @Test func aFolderIsSetAsideWhole() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "FileDragTests-\(UUID().uuidString)")
        let folder = root.appending(path: "Trip")
        try FileManager.default.createDirectory(at: folder.appending(path: "Day 1"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("photo".utf8).write(to: folder.appending(path: "Day 1/Photo.jpg"))
        let copy = try StagedUpload(copying: folder)
        #expect(copy.file.lastPathComponent == "Trip")
        #expect(try String(contentsOf: copy.file.appending(path: "Day 1/Photo.jpg"), encoding: .utf8) == "photo")
        copy.discard()
        #expect(!exists(copy))
        #expect(throws: (any Error).self) { try StagedUpload(copying: root.appending(path: "Missing")) }
    }
}

@Suite struct DroppedFileTests {
    @Test func whatComesOutOfAFileBrowserIsAFileWhateverItsType() {
        #expect(DroppedFile.typeIdentifier(registered: ["public.plain-text"], openableInPlace: ["public.plain-text"], hasName: true) == "public.plain-text")
        #expect(DroppedFile.typeIdentifier(registered: ["public.folder"], openableInPlace: ["public.folder"], hasName: true) == "public.folder")
    }

    @Test func picturesAndDocumentsAreFilesButWordsAndLinksAreNot() {
        #expect(DroppedFile.typeIdentifier(registered: ["public.heic", "public.jpeg"], openableInPlace: [], hasName: false) == "public.heic")
        #expect(DroppedFile.typeIdentifier(registered: ["com.adobe.pdf"], openableInPlace: [], hasName: true) == "com.adobe.pdf")
        #expect(DroppedFile.typeIdentifier(registered: ["public.folder"], openableInPlace: [], hasName: true) == "public.folder")
        // Words picked out of a page, and a link dragged from it.
        #expect(DroppedFile.typeIdentifier(registered: ["public.utf8-plain-text"], openableInPlace: [], hasName: false) == nil)
        #expect(DroppedFile.typeIdentifier(registered: ["public.url", "public.utf8-plain-text"], openableInPlace: [], hasName: false) == nil)
        // A text attachment has a name, and is a file.
        #expect(DroppedFile.typeIdentifier(registered: ["public.plain-text"], openableInPlace: [], hasName: true) == "public.plain-text")
        #expect(DroppedFile.typeIdentifier(registered: [], openableInPlace: [], hasName: true) == nil)
    }

    @Test func aNameWithoutAnEndingGetsTheOneOfItsType() {
        #expect(DroppedFile.name(suggested: "IMG_0042", typeIdentifier: "public.jpeg") == "IMG_0042.jpeg")
        #expect(DroppedFile.name(suggested: "Report.pdf", typeIdentifier: "com.adobe.pdf") == "Report.pdf")
        #expect(DroppedFile.name(suggested: "Trip", typeIdentifier: "public.folder") == "Trip")
        #expect(DroppedFile.name(suggested: nil, typeIdentifier: "public.png") == "Untitled.png")
    }
}
