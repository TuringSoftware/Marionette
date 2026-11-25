// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopSimulated
import Testing

/// Drags of files with the simulated machine, which plays them as a Mac does.
@Suite struct SimulatedFileDragTests {
    private func connect(
        _ change: (inout SimulationScenario) -> Void = { _ in },
        options: SessionOptions = SessionOptions()
    ) async throws -> SimulatedSession {
        var scenario = SimulationScenario.highPerformance
        scenario.phaseDelay = .milliseconds(1)
        scenario.frameRate = 60
        scenario.transferRate = 10_000_000
        scenario.fileDrags?.refusalDelay = .milliseconds(20)
        change(&scenario)
        return try await SimulatedBackend(scenario: scenario).connectSimulated(
            ConnectionRequest(options: options, transport: SimulatedTransport(), prompts: StaticPromptHandler(username: "demo", password: "demo"))
        )
    }

    private func centre(_ rect: PixelRect) -> PixelPoint {
        PixelPoint(x: Double(rect.x) + Double(rect.width) / 2, y: Double(rect.y) + Double(rect.height) / 2)
    }

    private func pointer(_ session: SimulatedSession, _ position: PixelPoint, pressed: Bool) {
        let display = session.layout.displays[0]
        session.input.send(.pointer(PointerEvent(display: display.id, position: position, buttons: pressed ? .primary : [], layoutGeneration: session.layout.generation)))
    }

    @Test func aDragLetGoOverTheFolderLandsThereAndTheFilesCanFollow() async throws {
        let session = try await connect()
        let drags = try #require(session.capabilities.fileDrag.value)
        let display = try #require(session.layout.displays.first)
        let folder = centre(try #require(session.desktopFolderFrame(on: display.id)))
        let start = PixelPoint(x: 10, y: 300)

        let drag = try drags.beginDrag(names: ["Report.pdf"], at: start, on: display.id)
        drag.move(to: folder, on: display.id)
        let destination = try await drag.drop()
        #expect(destination == "/Users/demo/Documents")
        #expect(session.fileDragEvents == [
            .began(names: ["Report.pdf"], display: display.id, position: start),
            .moved(display: display.id, position: folder),
            .dropped(folder: "/Users/demo/Documents"),
        ])

        // The files follow through file transfer, to the folder the machine named.
        let local = FileManager.default.temporaryDirectory.appending(path: "marionette-drag-\(UUID().uuidString)/Report.pdf")
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }
        try Data("report".utf8).write(to: local)
        let files = try #require(session.capabilities.fileTransfer.value)
        for try await _ in files.upload(from: local, toDirectory: destination) {}
        #expect(try await files.list(directory: destination).map(\.name).contains("Report.pdf"))
        await session.disconnect()
    }

    @Test func aDragLetGoAnywhereElseIsNotAccepted() async throws {
        let session = try await connect()
        let drags = try #require(session.capabilities.fileDrag.value)
        let display = try #require(session.layout.displays.first)
        let drag = try drags.beginDrag(names: ["a.txt", "b.txt"], at: PixelPoint(x: 10, y: 300), on: display.id)
        await #expect(throws: FileDragError.notAccepted) { _ = try await drag.drop() }
        #expect(session.fileDragEvents.last == .dropped(folder: nil))
        // Answered, the machine is free for the next drag.
        let next = try drags.beginDrag(names: ["c.txt"], at: PixelPoint(x: 10, y: 300), on: display.id)
        next.cancel()
        await session.disconnect()
    }

    @Test func oneDragAtATimeAndACancelledOneLeavesNothingBehind() async throws {
        let session = try await connect()
        let drags = try #require(session.capabilities.fileDrag.value)
        let display = try #require(session.layout.displays.first)
        let drag = try drags.beginDrag(names: ["a.txt"], at: PixelPoint(x: 10, y: 300), on: display.id)
        #expect(throws: FileDragError.busy) { _ = try drags.beginDrag(names: ["b.txt"], at: .zero, on: display.id) }
        drag.cancel()
        #expect(session.fileDragEvents.last == .cancelled)
        // A drag that is over neither moves nor drops.
        drag.move(to: PixelPoint(x: 50, y: 50), on: display.id)
        await #expect(throws: FileDragError.sessionEnded) { _ = try await drag.drop() }
        #expect(session.fileDragEvents.last == .cancelled)
        _ = try drags.beginDrag(names: ["b.txt"], at: .zero, on: display.id)
        await session.disconnect()
    }

    @Test func aDragCarriesThePointerAlong() async throws {
        let session = try await connect()
        let drags = try #require(session.capabilities.fileDrag.value)
        let display = try #require(session.layout.displays.first)
        var cursor = session.cursor().makeAsyncIterator()
        _ = await cursor.next()
        let drag = try drags.beginDrag(names: ["a.txt"], at: PixelPoint(x: 120, y: 80), on: display.id)
        #expect(await cursor.next()?.position == PixelPoint(x: 120, y: 80))
        drag.move(to: PixelPoint(x: 300, y: 200), on: display.id)
        #expect(await cursor.next()?.position == PixelPoint(x: 300, y: 200))
        drag.cancel()
        await session.disconnect()
    }

    @Test func aDropStillUnansweredWhenTheSessionEndsSaysSo() async throws {
        let session = try await connect { $0.fileDrags?.refusalDelay = .seconds(600) }
        let drags = try #require(session.capabilities.fileDrag.value)
        let display = try #require(session.layout.displays.first)
        let drag = try drags.beginDrag(names: ["a.txt"], at: PixelPoint(x: 10, y: 300), on: display.id)
        async let outcome: Result<String, any Error> = {
            do { return .success(try await drag.drop()) } catch { return .failure(error) }
        }()
        while session.fileDragEvents.last != .dropped(folder: nil) { await Task.yield() }
        await session.disconnect()
        guard case .failure(let error) = await outcome else {
            Issue.record("a drop answered after the session ended")
            return
        }
        #expect(error as? FileDragError == .sessionEnded)
    }

    @Test func pressingOnTheFileAndMovingStartsADragThatEndsWithTheButton() async throws {
        let session = try await connect()
        let drags = try #require(session.capabilities.fileDrag.value)
        let display = try #require(session.layout.displays.first)
        let file = centre(try #require(session.desktopFileFrame(on: display.id)))
        var announced = drags.remoteDrags().makeAsyncIterator()

        pointer(session, file, pressed: true)
        // A press that stays put is a click, not a drag.
        pointer(session, PixelPoint(x: file.x + 1, y: file.y), pressed: true)
        #expect(session.fileDragEvents.isEmpty)
        pointer(session, PixelPoint(x: file.x - 60, y: file.y + 40), pressed: true)
        let drag = try #require(await announced.next() ?? nil)
        #expect(drag.paths == ["/Users/demo/Documents/Readme.txt"])
        // The picture the machine shows under its pointer comes along, as PNG.
        #expect(drag.previewPNG?.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        pointer(session, PixelPoint(x: 100, y: 300), pressed: false)
        #expect(await announced.next() == .some(nil))
        #expect(session.fileDragEvents == [
            .remoteDragStarted(paths: ["/Users/demo/Documents/Readme.txt"]),
            .remoteDragDropped,
        ])
        await session.disconnect()
    }

    @Test func aDragTakenBeforeTheButtonComesUpIsDroppedNowhere() async throws {
        let session = try await connect()
        let drags = try #require(session.capabilities.fileDrag.value)
        var announced = drags.remoteDrags().makeAsyncIterator()
        session.simulateRemoteDrag(paths: ["/Users/demo/Documents/Readme.txt", "/Users/demo/Documents/Notes.txt"])
        #expect((await announced.next() ?? nil)?.paths.count == 2)

        drags.takeRemoteDrag()
        #expect(await announced.next() == .some(nil))
        pointer(session, PixelPoint(x: 100, y: 300), pressed: true)
        pointer(session, PixelPoint(x: 100, y: 300), pressed: false)
        session.simulateRemoteDragEnd()
        #expect(session.fileDragEvents == [
            .remoteDragStarted(paths: ["/Users/demo/Documents/Readme.txt", "/Users/demo/Documents/Notes.txt"]),
            .remoteDragTaken,
        ])

        // The files are fetched like any other, by the paths the drag named.
        let files = try #require(session.capabilities.fileTransfer.value)
        let local = FileManager.default.temporaryDirectory.appending(path: "marionette-drag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        for try await _ in files.download("/Users/demo/Documents/Readme.txt", to: local) {}
        #expect(try String(contentsOf: local, encoding: .utf8) == "Hello from the demo Mac.\n")
        await session.disconnect()
    }

    @Test func takingADragAfterItsButtonCameUpIsTooLate() async throws {
        let session = try await connect()
        let drags = try #require(session.capabilities.fileDrag.value)
        session.simulateRemoteDrag(paths: ["/Users/demo/Documents/Readme.txt"])
        session.simulateRemoteDragEnd()
        drags.takeRemoteDrag()
        #expect(session.fileDragEvents == [
            .remoteDragStarted(paths: ["/Users/demo/Documents/Readme.txt"]),
            .remoteDragDropped,
        ])
        await session.disconnect()
    }

    @Test func aDragUnderWayIsReplayedToANewSubscriberAndEndsWithTheSession() async throws {
        let session = try await connect()
        let drags = try #require(session.capabilities.fileDrag.value)
        session.simulateRemoteDrag(paths: ["/Users/demo/Documents/Readme.txt"])
        var announced = drags.remoteDrags().makeAsyncIterator()
        #expect((await announced.next() ?? nil)?.paths == ["/Users/demo/Documents/Readme.txt"])
        await session.disconnect()
        #expect(await announced.next() == .some(nil))
        #expect(await announced.next() == nil)
    }

    @Test func aScenarioCanStartADragByItself() async throws {
        let session = try await connect {
            $0.fileDrags?.automaticDrag = (.milliseconds(10), ["/Users/demo/Documents/Notes.txt"])
        }
        let drags = try #require(session.capabilities.fileDrag.value)
        for await drag in drags.remoteDrags() {
            guard let drag else { continue }
            #expect(drag.paths == ["/Users/demo/Documents/Notes.txt"])
            break
        }
        await session.disconnect()
    }

    @Test func aMachineWithoutDragsOrAViewerThatOnlyWatchesHasNone() async throws {
        let plain = try await connect { $0.fileDrags = nil }
        #expect(plain.capabilities.fileDrag.unavailableReason == .notSupportedByServer)
        #expect(plain.desktopFolderFrame(on: plain.layout.displays[0].id) == nil)
        await plain.disconnect()

        let watching = try await connect(options: SessionOptions(controlMode: .observe))
        #expect(watching.capabilities.fileDrag.unavailableReason == .notPermitted)
        await watching.disconnect()
    }

    @Test func aFolderIsUploadedWithEverythingInIt() async throws {
        let session = try await connect()
        let files = try #require(session.capabilities.fileTransfer.value)
        let root = FileManager.default.temporaryDirectory.appending(path: "marionette-drag-\(UUID().uuidString)")
        let folder = root.appending(path: "Trip")
        try FileManager.default.createDirectory(at: folder.appending(path: "Day 1"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("plan".utf8).write(to: folder.appending(path: "Plan.txt"))
        try Data("photo".utf8).write(to: folder.appending(path: "Day 1/Photo.jpg"))

        var last: TransferProgress?
        for try await progress in files.upload(from: folder, toDirectory: "/Users/demo/Documents") { last = progress }
        #expect(last == TransferProgress(bytesTransferred: 9, totalBytes: 9))
        #expect(try await files.list(directory: "/Users/demo/Documents/Trip").map(\.name) == ["Day 1", "Plan.txt"])
        #expect(try await files.list(directory: "/Users/demo/Documents/Trip/Day 1").map(\.name) == ["Photo.jpg"])
        await session.disconnect()
    }

    @Test func theFolderAndTheFileLieApartOnDisplaysOfEveryShape() async throws {
        let shapes = [PixelSize(width: 2560, height: 1600), PixelSize(width: 1748, height: 804), PixelSize(width: 804, height: 1748), PixelSize(width: 640, height: 400)]
        for shape in shapes {
            let session = try await connect { $0.displays = [.init(name: "Display", pixelSize: shape, scale: 2)] }
            let display = try #require(session.layout.displays.first)
            let folder = try #require(session.desktopFolderFrame(on: display.id))
            let file = try #require(session.desktopFileFrame(on: display.id))
            let bounds = PixelRect(size: shape)
            #expect(bounds.contains(folder) && bounds.contains(file), "\(shape)")
            #expect(!folder.isEmpty && !file.isEmpty)
            #expect(!folder.contains(centre(file)) && !file.contains(centre(folder)), "\(shape)")
            await session.disconnect()
        }
    }
}
