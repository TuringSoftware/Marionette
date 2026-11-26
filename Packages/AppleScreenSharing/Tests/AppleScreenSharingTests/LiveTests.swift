// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

@testable import AppleScreenSharing
import CoreVideo
import Foundation
import RemoteDesktopConformance
import RemoteDesktopCore
import RemoteDesktopTransport
import Synchronization
import Testing

/// Tests against a real Mac. They run only when `MARIONETTE_TEST_HOST` names one, with `MARIONETTE_TEST_USER` and
/// `MARIONETTE_TEST_PASSWORD` for an account allowed to share its screen (`Scripts/test.sh --live`).
///
/// A Mac gives its High Performance stream to one viewer at a time and the viewer binds fixed
/// ports, so the suite runs one test at a time.
enum LiveHost {
    static let environment = ProcessInfo.processInfo.environment
    static let host = environment["MARIONETTE_TEST_HOST"]
    static let user = environment["MARIONETTE_TEST_USER"] ?? ""
    static let password = environment["MARIONETTE_TEST_PASSWORD"] ?? "password"
    static var isConfigured: Bool { host != nil }

    static func request(_ mode: SessionOptions.ModePreference, password: String = password, displays: SessionOptions.DisplayPreference = .physical(.all)) -> ConnectionRequest {
        var options = SessionOptions(mode: mode)
        options.displays = displays
        return ConnectionRequest(
            options: options,
            transport: DirectTransportProvider(peer: Endpoint(host: host ?? "", port: 5900)),
            prompts: StaticPromptHandler(username: user, password: password)
        )
    }

    static let smallDisplay = SessionOptions.DisplayPreference.virtual([VirtualDisplayRequest(pointSize: PixelSize(width: 1024, height: 768), scale: 1)])
}

@Suite(.serialized, .enabled(if: LiveHost.isConfigured))
struct LiveAppleScreenSharingTests {
    @Test(arguments: BackendConformance.allChecks)
    func standardModeConforms(check: BackendConformance.Check) async throws {
        let suite = BackendConformance(backend: AppleScreenSharingBackend(), timeout: .seconds(30)) {
            LiveHost.request(.require(.standard))
        }
        try await suite.run(check)
    }

    @Test(arguments: BackendConformance.allChecks)
    func highPerformanceModeConforms(check: BackendConformance.Check) async throws {
        let suite = BackendConformance(backend: AppleScreenSharingBackend(), timeout: .seconds(40)) {
            LiveHost.request(.require(.highPerformance), displays: LiveHost.smallDisplay)
        }
        try await suite.run(check)
        // The Mac keeps a virtual display for a moment after its session; let it settle.
        try await Task.sleep(for: .seconds(1))
    }

    /// The fallback for devices that cannot decode HEVC 4:4:4 in hardware: the same session with
    /// the Mac's H.264. (It recovers from a lost packet only at a whole keyframe, which a lossy
    /// path rarely delivers; on a clean one it behaves like HEVC.)
    @Test(arguments: BackendConformance.allChecks)
    func highPerformanceInH264Conforms(check: BackendConformance.Check) async throws {
        var backend = AppleScreenSharingBackend()
        backend.videoCodec = .h264
        let suite = BackendConformance(backend: backend, timeout: .seconds(40)) {
            LiveHost.request(.require(.highPerformance), displays: LiveHost.smallDisplay)
        }
        try await suite.run(check)
        try await Task.sleep(for: .seconds(1))
    }

    @Test func wrongPasswordFailsAsAuthentication() async {
        await #expect(throws: ConnectionFailure.self) {
            _ = try await AppleScreenSharingBackend().connect(LiveHost.request(.require(.standard), password: "definitely-wrong"))
        }
        do {
            _ = try await AppleScreenSharingBackend().connect(LiveHost.request(.require(.standard), password: "definitely-wrong"))
        } catch {
            // The fixed prompt handler declines to retry, which ends the attempt as cancelled after
            // the Mac refused the first password.
            #expect(error == .cancelled || error == .authenticationFailed(detail: nil))
        }
    }

    @Test func automaticModePicksHighPerformanceOnADirectPath() async throws {
        let session = try await AppleScreenSharingBackend().connect(LiveHost.request(.automatic, displays: LiveHost.smallDisplay))
        #expect(session.info.mode == .highPerformance)
        #expect(session.capabilities.audio.isAvailable)
        #expect(session.capabilities.quality.unavailableReason == .requiresMode(.standard))
        let display = try #require(session.layout.displays.first)
        #expect(display.kind == .virtual)
        #expect(display.pixelSize == PixelSize(width: 1024, height: 768))
        #expect(display.scale == 1)
        await session.disconnect()
        try await Task.sleep(for: .seconds(1))
    }

    @Test func clipboardRoundTripsThroughTheMac() async throws {
        let session = try await AppleScreenSharingBackend().connect(LiveHost.request(.require(.standard)))
        let clipboard = try #require(session.capabilities.clipboard.value)
        let text = "Marionette clipboard \(UUID().uuidString) — ünïcödé ✓"
        try await clipboard.sendToRemote([ClipboardItem(text: text)])
        // A Mac does not announce a change the viewer made itself, so ask it what it now holds.
        let core = try #require((session as? ARDSession)?.core)
        var items: [ClipboardItem] = []
        for _ in 0..<10 {
            items = try await core.fetchPasteboard()
            if items.contains(where: { $0.text == text }) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(items.contains { $0.text == text })

        try await clipboard.sendToRemote([])
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await core.fetchPasteboard().allSatisfy { $0.text == nil })
        await session.disconnect()
    }

    /// Screen Sharing's own transfer, both ways, in both modes: a folder with a nested folder, an
    /// empty file and a file of several pieces goes to the Mac and comes back the same.
    @Test(arguments: [SessionMode.standard, .highPerformance])
    func nativeFileTransferRoundTrips(mode: SessionMode) async throws {
        let request = mode == .standard
            ? LiveHost.request(.require(.standard))
            : LiveHost.request(.require(.highPerformance), displays: LiveHost.smallDisplay)
        let session = try await AppleScreenSharingBackend().connect(request)
        let files = try #require(session.capabilities.fileTransfer.value)
        #expect(!files.canBrowse)
        #expect(try await files.defaultUploadDirectory() == "~/Downloads")

        let local = FileManager.default.temporaryDirectory.appendingPathComponent("marionette-live-\(UUID().uuidString)")
        let name = local.lastPathComponent
        let tree = local.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: tree.appendingPathComponent("nested/deeper"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        var random = SystemRandomNumberGenerator()
        let big = Data((0..<300_000).map { _ in UInt8.random(in: 0...255, using: &random) })
        try big.write(to: tree.appendingPathComponent("big.bin"))
        let notes = Data("ünïcödé ✓\n".utf8)
        try notes.write(to: tree.appendingPathComponent("nested/notes.txt"))
        try Data().write(to: tree.appendingPathComponent("nested/deeper/empty"))

        var last: TransferProgress?
        for try await progress in files.upload(from: tree, toDirectory: "~/Downloads/marionette-live-tests") { last = progress }
        let total = UInt64(big.count + notes.count)
        #expect(last?.bytesTransferred == total && last?.totalBytes == total)

        let back = local.appendingPathComponent("back")
        for try await _ in files.download("/Users/\(LiveHost.user)/Downloads/marionette-live-tests/\(name)", to: back) {}
        #expect(try Data(contentsOf: back.appendingPathComponent("big.bin")) == big)
        #expect(try String(contentsOf: back.appendingPathComponent("nested/notes.txt"), encoding: .utf8) == "ünïcödé ✓\n")
        #expect(try Data(contentsOf: back.appendingPathComponent("nested/deeper/empty")).isEmpty)

        await #expect(throws: NativeFileTransferError.notFound(path: "/Users/\(LiveHost.user)/no-such-\(name)")) {
            for try await _ in files.download("/Users/\(LiveHost.user)/no-such-\(name)", to: local.appendingPathComponent("missing")) {}
        }
        #expect(!FileManager.default.fileExists(atPath: local.appendingPathComponent("missing").path))
        await #expect(throws: NativeFileTransferError.refused(directory: "/System", status: 5)) {
            for try await _ in files.upload(from: tree.appendingPathComponent("nested/notes.txt"), toDirectory: "/System") {}
        }
        #expect(session.state == .connected)
        await session.disconnect()
        try await Task.sleep(for: .seconds(1))
    }

    /// The parts of native transfer that the round trip above does not reach: a framework's symbolic
    /// links, a name with a colon (which the wire spells with a slash), and a download stopped part
    /// way, after which the next transfer must not wait behind the rest of it.
    @Test func nativeFileTransferKeepsLinksAndColonsAndStops() async throws {
        let session = try await AppleScreenSharingBackend().connect(LiveHost.request(.require(.standard)))
        let files = try #require(session.capabilities.fileTransfer.value)
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("marionette-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }

        // IOSurface.framework: IOSurface and Resources link into Versions/Current, itself a link to A.
        let framework = local.appendingPathComponent("IOSurface.framework")
        for try await _ in files.download("/System/Library/Frameworks/IOSurface.framework", to: framework) {}
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: framework.appendingPathComponent("Resources").path) == "Versions/Current/Resources")
        #expect(FileManager.default.fileExists(atPath: framework.appendingPathComponent("Resources/Info.plist").path))

        let tree = local.appendingPathComponent(local.lastPathComponent)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("colon".utf8).write(to: tree.appendingPathComponent("a:b.txt"))
        var random = SystemRandomNumberGenerator()
        try Data((0..<(4 << 20)).map { _ in UInt8.random(in: 0...255, using: &random) }).write(to: tree.appendingPathComponent("big.bin"))
        for try await _ in files.upload(from: tree, toDirectory: "~/Downloads/marionette-live-tests") {}
        let remote = "/Users/\(LiveHost.user)/Downloads/marionette-live-tests/\(tree.lastPathComponent)"

        // Stopped after its first piece: nothing is left behind, and the Mac stops sending.
        for try await progress in files.download(remote + "/big.bin", to: local.appendingPathComponent("partial.bin")) where progress.bytesTransferred > 0 {
            break
        }
        let started = ContinuousClock.now
        let colon = local.appendingPathComponent("a:b.txt")
        for try await _ in files.download(remote + "/a:b.txt", to: colon) {}
        #expect(try String(contentsOf: colon, encoding: .utf8) == "colon")
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(try FileManager.default.contentsOfDirectory(atPath: local.path).sorted() == ["IOSurface.framework", "a:b.txt", tree.lastPathComponent].sorted())
        #expect(session.state == .connected)
        await session.disconnect()
        try await Task.sleep(for: .seconds(1))
    }

    /// A drag from this device onto the Mac's desktop, as the app makes one: the Mac names the
    /// folder under the drop, and a file sent there is the file fetched back from it. A Mac goes
    /// along with a drag only for a viewer whose pointer events are sealed, so the answer also
    /// shows that sealed pointer events reach it, in both modes.
    ///
    /// The drop is at 29 % across and 81 % down the screen, which must be bare desktop there (on
    /// the test Mac the icons are in a column on the right, sorted by name). Each run leaves one
    /// small file on the Mac's desktop, named by the time so that runs do not collide, and to
    /// sort after everything else there: an icon higher up would move the one that
    /// `aFileDraggedOnTheMacIsTakenOverAndFetched` presses on.
    @Test(arguments: [SessionMode.standard, .highPerformance])
    func aFileDraggedOntoTheDesktopLandsThere(mode: SessionMode) async throws {
        let request = mode == .standard
            ? LiveHost.request(.require(.standard))
            : LiveHost.request(.require(.highPerformance), displays: LiveHost.smallDisplay)
        let session = try await AppleScreenSharingBackend().connect(request)
        let drags = try #require(session.capabilities.fileDrag.value)
        let files = try #require(session.capabilities.fileTransfer.value)
        let display = try #require(session.layout.displays.first)

        let local = FileManager.default.temporaryDirectory.appendingPathComponent("marionette-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }
        let name = "zz-marionette-drag-\(Int(Date().timeIntervalSince1970)).txt"
        let contents = Data("dragged in by the live tests, \(UUID().uuidString) — ünïcödé ✓\n".utf8)
        try contents.write(to: local.appendingPathComponent(name))

        // A Mac discards input in the first seconds after the login and the session holds it
        // until then; the wait for the Mac's answer should not be spent there.
        try await Task.sleep(for: .seconds(3))
        let width = Double(display.pixelSize.width)
        let height = Double(display.pixelSize.height)
        let drag = try drags.beginDrag(names: [name], at: PixelPoint(x: width * 0.29, y: height * 0.81), on: display.id)
        for step in 1...4 {
            try await Task.sleep(for: .milliseconds(100))
            drag.move(to: PixelPoint(x: width * 0.29 + Double(step * 10), y: height * 0.81 + Double(step * 5)), on: display.id)
        }
        try await Task.sleep(for: .milliseconds(100))
        let started = ContinuousClock.now
        let folder = try await drag.drop()
        #expect(folder == "/Users/\(LiveHost.user)/Desktop")
        #expect(ContinuousClock.now - started < .seconds(1), "the Mac took \(ContinuousClock.now - started) to name the folder")

        for try await _ in files.upload(from: local.appendingPathComponent(name), toDirectory: folder) {}
        let back = local.appendingPathComponent("back.txt")
        for try await _ in files.download("\(folder)/\(name)", to: back) {}
        #expect(try Data(contentsOf: back) == contents)
        #expect(session.state == .connected)
        await session.disconnect()
        try await Task.sleep(for: .seconds(1))
    }

    /// A drag that starts on the Mac and is taken over here: the Mac says what is dragged as soon
    /// as Finder's drag starts under this viewer's pointer, taking it makes the Mac call its own
    /// drag off, and the file, still where it was, is fetched by the path the Mac named.
    ///
    /// Finder starts a drag only if the pointer moves within its double-click interval of the
    /// press (about half a second), so the first move follows the press closely.
    ///
    /// Nothing in the protocol says where an icon is, so this depends on the test Mac's desktop:
    /// `wfh-drag-test.txt` (400,001 bytes) is the third icon of the column on the right, 93.5 %
    /// across and 38.1 % down the screen, with bare desktop to its left.
    @Test(arguments: [SessionMode.standard, .highPerformance])
    func aFileDraggedOnTheMacIsTakenOverAndFetched(mode: SessionMode) async throws {
        let request = mode == .standard
            ? LiveHost.request(.require(.standard))
            : LiveHost.request(.require(.highPerformance), displays: LiveHost.smallDisplay)
        let session = try await AppleScreenSharingBackend().connect(request)
        let drags = try #require(session.capabilities.fileDrag.value)
        let files = try #require(session.capabilities.fileTransfer.value)
        let display = try #require(session.layout.displays.first)
        let seen = Mutex<[RemoteFileDrag?]>([])
        let watching = Task {
            for await drag in drags.remoteDrags() { seen.withLock { $0.append(drag) } }
        }
        defer { watching.cancel() }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("marionette-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: local) }

        let width = Double(display.pixelSize.width)
        let height = Double(display.pixelSize.height)
        var position = PixelPoint(x: width * 0.935, y: height * 0.381)
        func point(_ buttons: PointerButtons) {
            session.input.send(.pointer(PointerEvent(display: display.id, position: position, buttons: buttons, layoutGeneration: session.layout.generation)))
        }
        // Input sent in the first seconds after the login is held and then sent all at once,
        // which would not be a press followed by a movement.
        try await Task.sleep(for: .seconds(3))
        point([])
        try await Task.sleep(for: .milliseconds(300))
        point(.primary)
        try await Task.sleep(for: .milliseconds(100))
        let pressed = ContinuousClock.now
        for _ in 0..<12 {
            position.x -= width * 0.01
            point(.primary)
            try await Task.sleep(for: .milliseconds(30))
        }
        var dragged: RemoteFileDrag?
        while dragged == nil, ContinuousClock.now - pressed < .seconds(5) {
            dragged = seen.withLock { $0.compactMap { $0 }.first }
            try await Task.sleep(for: .milliseconds(20))
        }
        let path = "/Users/\(LiveHost.user)/Desktop/wfh-drag-test.txt"
        #expect(dragged?.paths == [path], "the Mac announced \(String(describing: dragged?.paths))")
        #expect(dragged?.previewPNG?.prefix(8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))

        if dragged != nil {
            drags.takeRemoteDrag()
            // Whatever comes of the fetch, the button must come up again on the Mac.
            do {
                let fetched = local.appendingPathComponent("wfh-drag-test.txt")
                for try await _ in files.download(path, to: fetched) {}
                #expect(try Data(contentsOf: fetched).count == 400_001)
            } catch {
                Issue.record("fetching the dragged file: \(error)")
            }
        }
        point([])
        try await Task.sleep(for: .seconds(1))
        #expect(seen.withLock { $0.last } == .some(nil))
        if dragged != nil {
            // Taken, not moved: the file is still where the Mac said it was.
            let again = local.appendingPathComponent("again.txt")
            for try await _ in files.download(path, to: again) {}
            #expect(try Data(contentsOf: again).count == 400_001)
        }
        #expect(session.state == .connected)
        await session.disconnect()
        try await Task.sleep(for: .seconds(1))
    }

    /// A Mac resends nothing and makes one keyframe a second, so a stream whose first picture
    /// keeps arriving broken cannot start. After trying the constrained media profile the back end
    /// must fail soon, with the reason, so the caller can fall back to Standard mode.
    @Test func highPerformanceGivesUpSoonOnAPathThatLosesPackets() async throws {
        let lossy = ImpairedTransportProvider(
            DirectTransportProvider(peer: Endpoint(host: LiveHost.host ?? "", port: 5900)),
            impairment: NetworkImpairment(inboundLoss: 0.03, outboundLoss: 0.03, seed: 11)
        )
        var options = SessionOptions(mode: .require(.highPerformance))
        options.displays = LiveHost.smallDisplay
        let started = ContinuousClock.now
        await #expect(throws: ConnectionFailure.modeUnavailable(mode: .highPerformance, reason: .unreliableNetwork)) {
            _ = try await AppleScreenSharingBackend().connect(ConnectionRequest(
                options: options, transport: lossy, prompts: StaticPromptHandler(username: LiveHost.user, password: LiveHost.password)
            ))
        }
        // Two starts of about 6 s each, and the step between them.
        #expect(ContinuousClock.now - started < .seconds(28))
        try await Task.sleep(for: .seconds(1))
    }

    /// Once a session is running, a lost packet costs one small refresh picture, not the session.
    /// Loss starts a few seconds in, while the screen is busy, and the pictures must keep coming.
    @Test(arguments: [0.01, 0.05])
    func aRunningHighPerformanceSessionRidesOutPacketLoss(loss: Double) async throws {
        let ledger = ImpairmentLedger()
        let lossy = ImpairedTransportProvider(
            DirectTransportProvider(peer: Endpoint(host: LiveHost.host ?? "", port: 5900)),
            impairment: NetworkImpairment(inboundLoss: loss, outboundLoss: loss, quietPeriod: .seconds(7), seed: 5),
            ledger: ledger
        )
        var options = SessionOptions(mode: .require(.highPerformance))
        options.displays = LiveHost.smallDisplay
        let opened = ContinuousClock.now
        let session = try await AppleScreenSharingBackend().connect(ConnectionRequest(
            options: options, transport: lossy, prompts: StaticPromptHandler(username: LiveHost.user, password: LiveHost.password)
        ))
        let display = try #require(session.layout.displays.first)
        let frames = session.frames(for: display.id)

        // Keep the screen moving: Mission Control in and out, an even number of times.
        let animation = Task {
            for _ in 0..<12 {
                session.input.send(.key(KeyEvent(key: .leftControl, phase: .down)))
                session.input.send(.key(KeyEvent(key: .upArrow, modifiers: .leftControl, phase: .down)))
                session.input.send(.key(KeyEvent(key: .upArrow, modifiers: .leftControl, phase: .up)))
                session.input.send(.key(KeyEvent(key: .leftControl, phase: .up)))
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        var count = 0
        var longestGap = Duration.zero
        var last: ContinuousClock.Instant?
        let lossBegins = opened + .seconds(10)
        let end = opened + .seconds(18)
        while ContinuousClock.now < end {
            guard await Self.frame(from: frames, within: .milliseconds(500)) != nil else { continue }
            let now = ContinuousClock.now
            guard now >= lossBegins else { continue }
            if let last { longestGap = max(longestGap, now - last) }
            last = now
            count += 1
        }
        await animation.value
        let dropped = ledger.snapshot
        #expect(dropped.droppedInbound > 5, "the test dropped only \(dropped.droppedInbound) datagrams")
        #expect(session.state == .connected)
        // About eight seconds of animation at fifteen pictures a second on a clean path. With loss
        // each repair costs up to a second; a session that only limped would show a handful.
        #expect(count >= 25, "\(count) frames arrived under \(loss * 100) % loss")
        #expect(longestGap < .seconds(4), "the picture stood still for \(longestGap)")
        await session.disconnect()
        try await Task.sleep(for: .seconds(1))
    }

    /// The control connection can outlive the media path. When the pictures' path goes dark the
    /// session must end, and as something a caller can recover from, not freeze on its last frame.
    @Test func aSessionWhoseMediaPathGoesDarkEndsAsStalled() async throws {
        let dark = ImpairedTransportProvider(
            DirectTransportProvider(peer: Endpoint(host: LiveHost.host ?? "", port: 5900)),
            impairment: NetworkImpairment(inboundLoss: 1, outboundLoss: 1, quietPeriod: .seconds(7))
        )
        var options = SessionOptions(mode: .require(.highPerformance))
        options.displays = LiveHost.smallDisplay
        let session = try await AppleScreenSharingBackend().connect(ConnectionRequest(
            options: options, transport: dark, prompts: StaticPromptHandler(username: LiveHost.user, password: LiveHost.password)
        ))
        let events = session.events()
        let watchdog = Task {
            try await Task.sleep(for: .seconds(30))
            await session.disconnect()
        }
        var reason: DisconnectReason?
        for await event in events {
            if case .stateChanged(.disconnected(let why)) = event {
                reason = why
                break
            }
        }
        watchdog.cancel()
        #expect(reason == DisconnectReason.mediaStalled(.silent))
        #expect(reason?.isRecoverable == true)
        try await Task.sleep(for: .seconds(1))
    }

    /// The next frame, or `nil` if none comes within `limit`.
    private static func frame(from mailbox: FrameMailbox, within limit: Duration) async -> DisplayFrame? {
        await withTaskGroup(of: DisplayFrame?.self) { group in
            group.addTask { await mailbox.next() }
            group.addTask {
                try? await Task.sleep(for: limit)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The picture once it has stopped changing: the last frame before `quiet` passed without one.
    private static func settledFrame(from mailbox: FrameMailbox, quiet: Duration, limit: Duration) async -> DisplayFrame? {
        let deadline = ContinuousClock.now + limit
        var latest: DisplayFrame?
        while ContinuousClock.now < deadline {
            guard let next = await frame(from: mailbox, within: quiet) else {
                if latest != nil { break }
                continue
            }
            latest = next
        }
        return latest
    }

    /// Blue, green and red of every pixel, without the fourth byte.
    private static func colours(of frame: DisplayFrame) -> [UInt8] {
        frame.surface.withUnsafeBuffer { buffer in
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            var output = [UInt8]()
            output.reserveCapacity(frame.pixelSize.width * frame.pixelSize.height * 3)
            for y in 0..<frame.pixelSize.height {
                for x in 0..<frame.pixelSize.width {
                    let pixel = base + y * stride + x * 4
                    output.append(pixel[0])
                    output.append(pixel[1])
                    output.append(pixel[2])
                }
            }
            return output
        }
    }

    /// A Mac from macOS 27.3 takes a viewer's fingers as a touch screen of its own: a finger on the
    /// Apple menu opens it, and Escape closes it again. In High Performance, whose pictures show a
    /// menu at once where Standard mode on a virtual machine can miss it.
    @Test func aFingerOnTheAppleMenuOpensIt() async throws {
        let session = try await AppleScreenSharingBackend().connect(LiveHost.request(.require(.highPerformance), displays: LiveHost.smallDisplay))
        guard session.capabilities.touch.isAvailable else {
            await session.disconnect()
            try Test.cancel("the Mac takes no touches: \(String(describing: session.capabilities.touch.unavailableReason))")
        }
        let display = try #require(session.layout.displays.first)
        let frames = session.frames(for: display.id)
        let before = Self.colours(of: try #require(await Self.settledFrame(from: frames, quiet: .seconds(2), limit: .seconds(20))))
        // The Mac drops touches for 2 s after it reports its own pointer, as it does when a session starts.
        try await Task.sleep(for: .seconds(1))
        let apple = PixelPoint(x: 17 * display.scale, y: 11 * display.scale)
        func finger(_ phase: TouchEvent.Contact.Phase) {
            session.input.send(.touch(TouchEvent(display: display.id, contacts: [TouchEvent.Contact(id: 0, position: apple, phase: phase)], layoutGeneration: session.layout.generation)))
        }
        finger(.touching)
        try await Task.sleep(for: .milliseconds(80))
        finger(.lifted)
        let open = Self.colours(of: try #require(await Self.settledFrame(from: frames, quiet: .seconds(1), limit: .seconds(10))))
        // The menu covers the top left, under the menu bar.
        let menu = (x: 0..<Int(150 * display.scale), y: Int(30 * display.scale)..<Int(200 * display.scale))
        #expect(Self.difference(before, open, in: menu, width: display.pixelSize.width) > 20)

        session.input.send(.key(KeyEvent(key: .escape, phase: .down)))
        // Pressed and released back to back, Escape left the menu open.
        try await Task.sleep(for: .milliseconds(40))
        session.input.send(.key(KeyEvent(key: .escape, phase: .up)))
        let closed = Self.colours(of: try #require(await Self.settledFrame(from: frames, quiet: .seconds(1), limit: .seconds(10))))
        #expect(Self.difference(before, closed, in: menu, width: display.pixelSize.width) < 5)
        await session.disconnect()
    }

    /// The mean difference of each colour component between two pictures, over a region.
    private static func difference(_ first: [UInt8], _ second: [UInt8], in region: (x: Range<Int>, y: Range<Int>), width: Int) -> Double {
        var total = 0.0
        var count = 0
        for y in region.y {
            for x in region.x {
                for component in 0..<3 {
                    let index = (y * width + x) * 3 + component
                    guard index < first.count, index < second.count else { continue }
                    total += abs(Double(first[index]) - Double(second[index]))
                    count += 1
                }
            }
        }
        return count == 0 ? 0 : total / Double(count)
    }

    /// Peak signal-to-noise ratio between two pictures of the same size, in decibels.
    private static func similarity(_ first: [UInt8], _ second: [UInt8]) -> Double {
        precondition(first.count == second.count && !first.isEmpty)
        var squares = 0.0
        for index in first.indices {
            let difference = Double(first[index]) - Double(second[index])
            squares += difference * difference
        }
        let mean = squares / Double(first.count)
        return mean == 0 ? .infinity : 10 * log10(255 * 255 / mean)
    }

    /// Adaptive quality is Apple's own lossy codec, decoded here. The proof that it is decoded
    /// correctly is the same screen at Full quality, which is exact: the two must be near enough
    /// alike that only the codec's rounding separates them.
    @Test func adaptiveQualityShowsTheSamePictureAsFullQuality() async throws {
        var options = SessionOptions(mode: .require(.standard))
        options.quality = .adaptive
        let session = try await AppleScreenSharingBackend().connect(ConnectionRequest(
            options: options,
            transport: DirectTransportProvider(peer: Endpoint(host: LiveHost.host ?? "", port: 5900)),
            prompts: StaticPromptHandler(username: LiveHost.user, password: LiveHost.password)
        ))
        let quality = try #require(session.capabilities.quality.value)
        #expect(quality.supportedPresets == [.adaptive, .full])
        let display = try #require(session.layout.displays.first)
        let frames = session.frames(for: display.id)

        // The first picture is coarse and is refined in strips while the screen stays still.
        let adaptive = try #require(await Self.settledFrame(from: frames, quiet: .seconds(3), limit: .seconds(45)))
        #expect(adaptive.pixelSize == display.pixelSize)

        try await quality.setPreset(.full)
        let full = try #require(await Self.settledFrame(from: frames, quiet: .seconds(3), limit: .seconds(45)))
        let exact = Self.colours(of: full)
        let refined = Self.similarity(Self.colours(of: adaptive), exact)
        // A wrong bit anywhere in the tile streams smears everything after it, which scores under
        // 15 dB. The session's first picture is its coarsest, and the Mac's "your screen is being
        // observed" notice may be up in one capture and gone in the other, so this bound is loose.
        #expect(refined > 24, "Adaptive against Full: \(refined) dB")

        // And back: the Mac starts its tiles over on the picture this side now holds.
        try await quality.setPreset(.adaptive)
        let again = try #require(await Self.settledFrame(from: frames, quiet: .seconds(3), limit: .seconds(45)))
        let returned = Self.similarity(Self.colours(of: again), exact)
        // By now the screen is still and the tiles are sent at their finer precision and refined:
        // measured at 33–41 dB against the exact picture, depending on what the screen shows and
        // what changed between the two captures. A decoding error scores under 15 dB.
        #expect(returned > 30, "Adaptive again against Full: \(returned) dB")
        #expect(session.state == .connected)
        await session.disconnect()
    }

    /// The whole session through the Mac's own SSH server: Screen Sharing reached on localhost.
    private static func tunnelledRequest(_ mode: SessionOptions.ModePreference) async throws -> (ConnectionRequest, SSHConnection) {
        let prompts = StaticPromptHandler(username: LiveHost.user, password: LiveHost.password, trustsUnknownHosts: true)
        let connection = try await SSHConnection.establish(
            SSHLogin(server: Endpoint(host: LiveHost.host ?? "", port: 22), username: LiveHost.user),
            prompts: prompts, hostKeys: InMemoryHostKeyStore()
        )
        let transport = SSHTunnelTransportProvider(connection: connection, peer: Endpoint(host: LiveHost.host ?? "", port: 5900), hostFromServer: "localhost")
        return (ConnectionRequest(options: SessionOptions(mode: mode), transport: transport, prompts: prompts), connection)
    }

    /// A second account, while the first is at the display (`MARIONETTE_TEST_USER2`, `MARIONETTE_TEST_PASSWORD2`):
    /// the Mac asks how to connect, and logging in as oneself gives a display of one's own.
    /// Asking the console user needs someone at the Mac to answer, so it is checked by hand.
    @Test(.enabled(if: LiveHost.environment["MARIONETTE_TEST_USER2"] != nil))
    func aSecondAccountLogsInToItsOwnSession() async throws {
        final class Recorder: PromptHandler {
            let inner: StaticPromptHandler
            let seen = Mutex<[SessionSelectRequest]>([])
            init(_ inner: StaticPromptHandler) { self.inner = inner }
            func resolve(_ prompt: SessionPrompt) async -> PromptResponse {
                if case .sessionSelect(let request) = prompt { seen.withLock { $0.append(request) } }
                return await inner.resolve(prompt)
            }
        }
        let prompts = Recorder(StaticPromptHandler(
            username: LiveHost.environment["MARIONETTE_TEST_USER2"] ?? "",
            password: LiveHost.environment["MARIONETTE_TEST_PASSWORD2"] ?? LiveHost.password,
            sessionChoice: .logInAsSelf
        ))
        var backend = AppleScreenSharingBackend()
        // A first login sets up a home folder and can take a while.
        backend.firstPictureTimeout = .seconds(60)
        let session = try await backend.connect(ConnectionRequest(
            options: SessionOptions(mode: .require(.standard)),
            transport: DirectTransportProvider(peer: Endpoint(host: LiveHost.host ?? "", port: 5900)),
            prompts: prompts
        ))
        let asked = prompts.seen.withLock { $0 }
        #expect(asked.count == 1)
        #expect(asked.first?.choices == [.askToShareConsole, .logInAsSelf])
        #expect(asked.first?.consoleUser.isEmpty == false)
        let display = try #require(session.layout.displays.first)
        // Not the console's display: one the Mac made for this session.
        #expect(display.kind == .virtual)
        let frame = try #require(await session.frames(for: display.id).next())
        #expect(frame.pixelSize == display.pixelSize)
        await session.disconnect()
    }

    @Test func tunnelledSessionRunsInStandardModeWithoutSound() async throws {
        let (request, tunnel) = try await Self.tunnelledRequest(.automatic)
        let session = try await AppleScreenSharingBackend().connect(request)
        #expect(session.info.mode == .standard)
        #expect(session.info.isTunnelled)
        #expect(session.capabilities.audio.unavailableReason == .tunnelled)
        let display = try #require(session.layout.displays.first)
        let frame = try #require(await session.frames(for: display.id).next())
        #expect(frame.pixelSize == display.pixelSize)
        await session.disconnect()
        await tunnel.close()
    }

    @Test func highPerformanceCannotBeRequiredThroughATunnel() async throws {
        let (request, tunnel) = try await Self.tunnelledRequest(.require(.highPerformance))
        await #expect(throws: ConnectionFailure.modeUnavailable(mode: .highPerformance, reason: .tunnelled)) {
            _ = try await AppleScreenSharingBackend().connect(request)
        }
        await tunnel.close()
    }

    @Test func virtualDisplayFollowsResizeRequests() async throws {
        let session = try await AppleScreenSharingBackend().connect(LiveHost.request(.require(.highPerformance), displays: LiveHost.smallDisplay))
        let configuration = try #require(session.capabilities.displayConfiguration.value)
        let id = try #require(session.layout.displays.first?.id)
        let frames = session.frames(for: id)

        try await configuration.setVirtualDisplays([VirtualDisplayRequest(pointSize: PixelSize(width: 1280, height: 720), scale: 1)])
        #expect(session.layout.displays.first?.pixelSize == PixelSize(width: 1280, height: 720))
        // The same subscription goes on to deliver pictures of the new size.
        var resized = false
        for _ in 0..<200 {
            guard let frame = await frames.next() else { break }
            if frame.pixelSize == PixelSize(width: 1280, height: 720) {
                resized = true
                break
            }
        }
        #expect(resized)
        await session.disconnect()
        try await Task.sleep(for: .seconds(1))
    }
}
