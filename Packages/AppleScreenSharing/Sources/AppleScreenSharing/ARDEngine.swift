// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
import Foundation
import RemoteDesktopCore

/// Runs one session: reads the Mac's messages and turns them into layouts, frames and cursor
/// updates, and drives the mode's own negotiation. Owns everything that is not thread-safe.
actor ARDEngine {
    private struct HighPerformance {
        var offer: MediaOffer
        /// What the displays were asked for in, before fitting them to what a Mac accepts.
        var requests: [VirtualDisplayRequest]
        var ports: MediaStreamReceiver.Ports?
        var boundPorts: MediaStreamReceiver.Ports?
        /// The Mac has named its ports since the last answer, so it will take another offer.
        var portsAnnounced = false
        var offerOutstanding = false
        /// A display configuration is out and the Mac has not yet named ports for it.
        var changeOutstanding = false
        /// A layout has arrived since the latest display configuration was sent.
        var layoutSinceChange = false
        /// The session's own size has been asked for; before that only the opening displays exist.
        var sessionSizeApplied = false
        var desired: [VirtualDisplayMode]
        /// What was last asked for; empty when that is unknown (a request the Mac never answered).
        var applied: [VirtualDisplayMode] = []
        /// The Mac moved the session to other displays while a request of this side's was out:
        /// the session's displays are asked for again once it is answered.
        var reassertPending = false
        /// Re-assertions made for layouts that were not of the session's displays, since the last
        /// layout that was. A Mac that will not make them (the Login Window) is asked once.
        var reassertsWithoutVirtualLayout = 0
        /// Offers that went unanswered in a row, each followed by a fresh request for the displays.
        var unansweredOffers = 0
        /// Tags the change or offer now out, so that the timer of an earlier one does nothing.
        var requestSerial: UInt64 = 0
    }

    private enum Waiter {
        case virtualDisplays(CheckedContinuation<Result<Void, DisplayChangeError>, Never>)
        case physicalSelection(UInt32?, CheckedContinuation<Result<Void, DisplayChangeError>, Never>)
    }

    private weak var core: ARDSessionCore?
    private let connection: ARDConnection
    private let mode: SessionMode

    private var layout: DisplayLayout?
    /// The Mac has sent a layout of its own; until it does, Standard mode goes by the framebuffer's size.
    private var hasServerLayout = false
    private var generation: UInt64 = 0
    private var cursors = CursorCache()
    private var waiters: [(id: UInt64, waiter: Waiter)] = []
    private var nextWaiterID: UInt64 = 0

    private var framebuffer: Framebuffer?
    private var damage = DamageRegion()
    private var quality: QualityPreset
    private var selection: UInt32??

    private var highPerformance: HighPerformance?

    init(core: ARDSessionCore) {
        self.core = core
        connection = core.connection
        mode = core.info.mode
        quality = core.options.quality
    }

    // MARK: Start

    func start() async {
        guard let core else { return }
        switch mode {
        case .standard:
            await connection.setPixelFormat(.bgrx)
            connection.send(ClientMessage.setEncodings(quality == .adaptive ? Encoding.standardAdaptive : Encoding.standardFull))
            // Which displays the session shows, said even when it is all of them, as Screen
            // Sharing.app does.
            if case .physical(.single(let id)) = core.options.displays {
                selection = .some(id.rawValue)
                connection.send(ClientMessage.setDisplay(id.rawValue))
            } else if core.timing.saysEveryDisplay {
                selection = .some(nil)
                connection.send(ClientMessage.setDisplay(nil))
            }
            // A Mac answers the encodings with its layout at once, and the picture is asked for
            // then. A server that sends no layout gets asked for its framebuffer as it is.
            Task { [weak self] in
                try? await Task.sleep(for: Self.layoutGrace)
                try? await self?.assumeLayoutIfNoneCame()
            }
        case .highPerformance:
            let limit = max(1, core.serverInit.flags?.maximumVirtualDisplays ?? 1)
            if case .virtual(let wanted) = core.options.displays, !wanted.isEmpty {
                beginHighPerformance(requests: Array(wanted.prefix(limit)))
                return
            }
            // The Mac's own displays, as far as High Performance can show them: virtual displays
            // made like them. Its layout says what they are. A Mac sends it at once for Standard
            // mode's encodings, before any picture is asked for (a list naming layouts alone gets
            // no answer from macOS 15.6), and High Performance's list replaces them right after.
            awaitingPhysicalLayout = true
            core.note("asking for the Mac's own displays, to make the virtual ones like them")
            await connection.setPixelFormat(.bgrx)
            connection.send(ClientMessage.setEncodings(Encoding.standardFull))
            let grace = core.timing.physicalLayoutGrace
            Task { [weak self] in
                try? await Task.sleep(for: grace)
                await self?.physicalLayoutArrived(nil)
            }
        }
    }

    /// While High Performance waits for the Mac's own layout before making its displays.
    private var awaitingPhysicalLayout = false

    /// Makes High Performance's displays like the Mac's own ones in `layout`, or, with none (the
    /// Mac sent none in time), at a size any Mac shows well.
    private func physicalLayoutArrived(_ layout: DisplayLayout?) {
        guard awaitingPhysicalLayout, let core else { return }
        awaitingPhysicalLayout = false
        let limit = max(1, core.serverInit.flags?.maximumVirtualDisplays ?? 1)
        var requests = layout.map { Self.requests(matching: $0, limit: limit) } ?? []
        if requests.isEmpty {
            core.note("the Mac did not say what its displays are; making one of 1440 × 900 points")
            requests = [VirtualDisplayRequest(pointSize: PixelSize(width: 1440, height: 900))]
        } else {
            core.note("the Mac's displays: " + requests.map { "\($0.pointSize.width) × \($0.pointSize.height) pt @\($0.scale)x" }.joined(separator: ", "))
        }
        beginHighPerformance(requests: requests)
    }

    /// Virtual displays like the Mac's own screens, its main one first, then the others from left to
    /// right, as many as the Mac makes. Each keeps its screen's size in points (what the person at the
    /// Mac sees as its resolution), so windows keep their size and place. A screen whose pixels at
    /// its own density are more than a Mac makes for a virtual display (a 5K or 6K one) is made at
    /// 1x instead: the same points, fewer pixels.
    static func requests(matching layout: DisplayLayout, limit: Int) -> [VirtualDisplayRequest] {
        // Another viewer's virtual displays are no guide: while they show, the Mac lists them alone.
        var screens = layout.screens.filter { !$0.flags.contains(.dynamicVirtual) }
        screens.sort { first, second in
            let firstIsMain = first.flags.contains(.main)
            let secondIsMain = second.flags.contains(.main)
            if firstIsMain != secondIsMain { return firstIsMain }
            return (first.pointLeft, first.pointTop) < (second.pointLeft, second.pointTop)
        }
        return screens.prefix(max(1, limit)).map { screen in
            let density = screen.density >= 1.5 ? 2 : 1
            let fitsAtDensity = screen.pointWidth * density <= Int(VirtualDisplayMode.maximumPixelWidth)
                && screen.pointHeight * density <= Int(VirtualDisplayMode.maximumPixelHeight)
            return VirtualDisplayRequest(
                pointSize: PixelSize(width: screen.pointWidth, height: screen.pointHeight),
                scale: fitsAtDensity ? density : 1
            )
        }
    }

    private func beginHighPerformance(requests: [VirtualDisplayRequest]) {
        guard let core else { return }
        var offer = Self.makeOffer(legs: requests.count, codec: core.videoCodec)
        offer.bandwidthProfile = core.timing.bandwidthProfile
        let desired = requests.map { Self.mode(for: $0, profile: offer.bandwidthProfile) }
        highPerformance = HighPerformance(offer: offer, requests: requests, desired: desired)
        core.note("asking for \(core.videoCodec == .hevc ? "HEVC 4:4:4" : "H.264") pictures")
        // Every virtual display is created at one canonical mode first; the session's own size
        // follows once the stream has been agreed for it. That lets macOS restore the displays'
        // arrangement and window placement before their live sizes apply.
        connection.send(ClientMessage.setDisplayConfiguration(Array(repeating: .opening, count: desired.count), dynamic: false))
        connection.send(ClientMessage.setEncodings(Encoding.highPerformance))
        highPerformance?.changeOutstanding = true
        startTimer(for: .change)
    }

    /// How long Standard mode waits for a layout before going by the framebuffer's size.
    static let layoutGrace: Duration = .milliseconds(1500)

    private func assumeLayoutIfNoneCame() async throws {
        guard let core, mode == .standard, layout == nil, !hasServerLayout else { return }
        core.note("no display layout arrived; going by the framebuffer's size")
        try await apply(.single(width: Int(core.serverInit.framebufferWidth), height: Int(core.serverInit.framebufferHeight)))
    }

    /// The mode a display is asked for. In the constrained profile a Mac pads its pictures to a
    /// multiple of 16 points on each side (a 1440 × 900 pt display came as 2880 × 1824 pixels), and
    /// a picture larger than its display would never show; such displays are asked for in whole
    /// multiples of 16 points instead.
    private static func mode(for request: VirtualDisplayRequest, profile: MediaOffer.BandwidthProfile) -> VirtualDisplayMode {
        var width = request.pointSize.width
        var height = request.pointSize.height
        if profile == .constrained {
            width = max(16, width / 16 * 16)
            height = max(16, height / 16 * 16)
        }
        var mode = VirtualDisplayMode.fitting(
            pointWidth: width, pointHeight: height, scale: request.scale,
            refreshRate: Double(request.refreshRate), isHDR: request.wantsHDR
        )
        if profile == .constrained {
            // Clamping may have moved a side off the grid again.
            let scale = mode.pixelWidth / max(1, mode.pointWidth)
            mode.pointWidth = mode.pointWidth / 16 * 16
            mode.pointHeight = mode.pointHeight / 16 * 16
            mode.pixelWidth = mode.pointWidth * scale
            mode.pixelHeight = mode.pointHeight * scale
        }
        return mode
    }

    private static func makeOffer(legs: Int, codec: MediaVideoCodec) -> MediaOffer {
        var flags: MediaOffer.Flags = [.sixtyFramesPerSecond, .omitCursor]
        if legs > 1 { flags.insert(.sixtyFramesPerSecondSecondStream) }
        let unkeyed = MediaKey(bytes: Data(count: MediaKey.length))
        return renewed(MediaOffer(
            sessionID: UUID(), flags: flags,
            audioSSRC: 0, audioKeys: MediaLegKeys(viewerToServer: unkeyed, serverToViewer: unkeyed),
            videos: (0..<legs).map { _ in
                MediaOffer.Video(ssrc: 0, keys: MediaLegKeys(viewerToServer: unkeyed, serverToViewer: unkeyed), width: 0, height: 0, codec: codec, tilesPerFrame: 1)
            }
        ))
    }

    /// The offer with new SSRCs and keys on every leg. Each offer starts a stream of its own, so
    /// nothing a late packet of an earlier stream carries can pass for the new one.
    private static func renewed(_ offer: MediaOffer) -> MediaOffer {
        var generator = SystemRandomNumberGenerator()
        func key() -> MediaKey {
            MediaKey(bytes: Data((0..<MediaKey.length).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
        }
        func keys() -> MediaLegKeys { MediaLegKeys(viewerToServer: key(), serverToViewer: key()) }
        var renewed = offer
        renewed.audioSSRC = .random(in: 1 ... .max, using: &generator)
        renewed.audioKeys = keys()
        for index in renewed.videos.indices {
            renewed.videos[index].ssrc = .random(in: 1 ... .max, using: &generator)
            renewed.videos[index].keys = keys()
        }
        return renewed
    }

    // MARK: Event loop

    func run() async {
        do {
            while let event = try await connection.nextEvent() {
                try await handle(event)
            }
            core?.finish(closedReason(.remoteClosed(detail: nil)))
        } catch let error as ARDError {
            core?.finish(closedReason(ARDSessionCore.disconnectReason(for: error)))
        } catch {
            core?.finish(ARDSessionCore.disconnectReason(for: ARDError(error)))
        }
        failWaiters(.sessionEnded)
    }

    /// Why the session ended when the Mac closed it. Right after the stream stalled, the close is
    /// the end of the user session the stream belonged to (a logout: the Mac goes on with its
    /// heartbeat, then closes when the stream is asked for again), and a new connection reaches the
    /// Login Window, so it counts as lost rather than ended.
    private func closedReason(_ reason: DisconnectReason) -> DisconnectReason {
        guard case .remoteClosed = reason, let core,
              let restarted = core.shared.withLock({ $0.streamRestartedForStallAt }),
              ContinuousClock.now - restarted < .seconds(10)
        else { return reason }
        return .connectionLost(detail: String(localized: "The Mac closed the connection after its picture stopped, as it does after a logout.", bundle: #bundle))
    }

    private func handle(_ event: ServerEvent) async throws {
        guard let core else { throw ARDError.cancelled }
        switch event {
        case .updateBegan, .bell, .cutText:
            if case .bell = event { core.events.send(.notice(.bell)) }
        case .updateEnded:
            publishDamage()
        case .status(let status):
            handle(status)
        case .pasteboard(let data):
            core.deliverPasteboard(data)
        case .rectangle(let rectangle):
            try await handle(rectangle)
        case .drag(let drag):
            core.note("the Mac's drag: \((try? drag.contents().paths) ?? [])")
            core.fileDrags.receive(drag)
        case .dropDestination(let destination):
            core.note("drop destination \(destination.path)")
            core.fileDrags.receive(destination)
        case .fileTransfer:
            // May wait while a download's writer catches up, which pauses reading the socket.
            await core.fileTransfers.receive(event)
        case .notice(let notice):
            core.note("\(notice)")
        }
    }

    private func handle(_ status: MiscStatus) {
        guard let core else { return }
        core.note("status \(status.rawValue)")
        switch status {
        case .pasteboardChanged:
            core.announceRemotePasteboardChange()
        case .pointerHidden, .pointerShown:
            let state = core.shared.withLock { shared in
                shared.cursor.isVisible = status == .pointerShown
                return shared.cursor
            }
            core.cursorUpdates.send(state)
        case .sessionEndedByUser:
            core.events.send(.notice(.message(String(localized: "The person at the Mac ended screen sharing.", bundle: #bundle))))
        case .userSessionChanged:
            // A login or logout moved the session to another user's displays. A virtual display
            // belongs to the user session it was made in, so ask for ours again.
            reassertVirtualDisplays()
        case .controlAllowed, .observeOnly:
            // The Mac says whether it takes this viewer's input: 10 in answer to the viewer's
            // identity when the account may only observe, 9 on an update request when it may control.
            core.setRemoteControlAllowed(status == .controlAllowed)
        case .displaysAsleep, .displaysAwake:
            core.shared.withLock { $0.areRemoteDisplaysAsleep = status == .displaysAsleep }
        default:
            break
        }
    }

    private func handle(_ rectangle: Rectangle) async throws {
        guard let core else { return }
        let header = rectangle.header
        if mode == .standard, !hasServerLayout, layout == nil {
            switch rectangle.body {
            case .raw, .zlib, .adaptive:
                // Pixels before any layout: a server that sends none. Its framebuffer is one screen.
                try await assumeLayoutIfNoneCame()
            default:
                break
            }
        }
        switch rectangle.body {
        case .displayLayout(let newLayout) where awaitingPhysicalLayout:
            // The Mac's own displays, asked for to make High Performance's like them. The session
            // shows none of them.
            core.note("the Mac's own layout: " + newLayout.screens.map { "\($0.pointWidth) × \($0.pointHeight) pt @\(Int($0.density))x" }.joined(separator: ", "))
            physicalLayoutArrived(newLayout)
        case .displayLayout(let newLayout):
            core.note("layout: " + newLayout.screens.map { "\($0.pixelWidth) × \($0.pixelHeight)" }.joined(separator: ", ") + ", flags 0x" + String(newLayout.flags.rawValue, radix: 16))
            hasServerLayout = true
            try await apply(newLayout)
        case .desktopSize:
            // A server without layouts resizes this way; a Mac's layout says more and comes too.
            if mode == .standard, !hasServerLayout, header.width > 0, header.height > 0 {
                core.note("desktop size \(header.width) × \(header.height)")
                try await apply(.single(width: Int(header.width), height: Int(header.height)))
            }
        case .cursorImage(let cacheID, let deflated):
            let update = cursors.apply(cacheID: cacheID, hotspotX: header.x, hotspotY: header.y, width: header.width, height: header.height, deflated: deflated)
            if case .shape(let image) = update {
                let state = core.shared.withLock { shared in
                    shared.cursor.image = image
                    return shared.cursor
                }
                core.cursorUpdates.send(state)
            }
        case .keyboardSource(let source):
            let changed: Bool = core.shared.withLock { shared in
                defer { shared.isSecureInputActive = source.isSecureInputActive }
                // Not secure is the normal state; only a change is worth a notice.
                return (shared.isSecureInputActive ?? false) != source.isSecureInputActive
            }
            if changed { core.events.send(.notice(.remoteSecureInput(source.isSecureInputActive))) }
        case .mediaStream(let body):
            try await handle(try MediaReply.parse(body))
        case .raw(let pixels):
            try writePixels(to: header) { framebuffer, rect in try framebuffer.write(pixels, to: rect) }
        case .zlib(let chunk):
            try writePixels(to: header) { framebuffer, rect in try framebuffer.writeZlib(chunk, to: rect) }
        case .adaptive(let body):
            try writeAdaptive(body, to: header)
        case .zrle:
            // In High Performance this is listed only so the Mac has a codec to name; the picture
            // is the media stream, and whatever arrives this way is stepped over. Standard mode does
            // not list it, and one a Mac sends anyway is stepped over too: the area is repainted the
            // next time it changes, which costs less than the session.
            if mode == .standard {
                core.note("the Mac sent a ZRLE rectangle, which was not asked for; stepped over")
            }
        case .rekey:
            throw ARDError.protocolViolation("the server re-keyed mid-session")
        case .unusable(let reason):
            core.note("stepped over \(rectangle.header.encoding): \(reason)")
        case .cursorPosition:
            // Where the Mac's pointer now is, in framebuffer pixels: it moves when someone uses the
            // Mac's own mouse, or a program moves it.
            core.movePointerFromRemote(x: header.x, y: header.y)
        case .lastRectangle, .ignored:
            break
        }
    }

    // MARK: Standard pixels

    private func writePixels(to header: RectangleHeader, _ write: (Framebuffer, PixelRect) throws -> Void) throws {
        guard mode == .standard else { return }
        guard let framebuffer else { throw ARDError.protocolViolation("pixels arrived before a display layout") }
        let rect = PixelRect(x: Int(header.x), y: Int(header.y), width: Int(header.width), height: Int(header.height))
        do {
            try write(framebuffer, rect)
        } catch {
            throw ARDError.protocolViolation("framebuffer update: \(error)")
        }
        damage.add(rect)
    }

    /// Applies a rectangle of Adaptive quality's tiles. A rectangle that cannot be decoded leaves
    /// this side's tiles out of step with the Mac's for good, so the session then asks for Full
    /// quality, which depends on nothing that came before, and for the whole picture again.
    private func writeAdaptive(_ body: Data, to header: RectangleHeader) throws {
        guard mode == .standard else { return }
        guard let framebuffer else { throw ARDError.protocolViolation("pixels arrived before a display layout") }
        let rect = PixelRect(x: Int(header.x), y: Int(header.y), width: Int(header.width), height: Int(header.height))
        do {
            if try framebuffer.writeAdaptive(body, to: rect) { damage.add(rect) }
        } catch {
            core?.note("Adaptive quality's picture could not be decoded (\(error)); going on at Full quality")
            quality = .full
            connection.send(ClientMessage.setEncodings(Encoding.standardFull))
            connection.send(ClientMessage.framebufferUpdateRequest(
                incremental: false, x: 0, y: 0,
                width: UInt16(clamping: framebuffer.size.width), height: UInt16(clamping: framebuffer.size.height)
            ))
        }
    }

    /// Arms the Mac's automatic updates over the whole framebuffer, as Apple's viewer does in every
    /// mode: at interval 0 (as often as the Mac captures) while the app is in front, and off
    /// (0xffffffff) while it is in the background. The Mac paces cursor shapes through the same
    /// gate as pictures, so a longer interval would delay them as much. Like Apple's viewer, a
    /// request for an update goes just before the arming.
    private func armUpdates(requestingWholePicture: Bool) {
        guard let core, let layout else { return }
        let width = UInt16(clamping: layout.framebufferWidth)
        let height = UInt16(clamping: layout.framebufferHeight)
        let suspended = core.shared.withLock { $0.isSuspended }
        if !suspended {
            connection.send(ClientMessage.framebufferUpdateRequest(incremental: !requestingWholePicture, x: 0, y: 0, width: width, height: height))
        }
        connection.send(ClientMessage.autoFramebufferUpdate(interval: suspended ? nil : .zero, width: width, height: height))
    }

    /// Called when the app goes to the background: the Mac stops pushing updates.
    func suspendUpdates() {
        armUpdates(requestingWholePicture: false)
    }

    /// Publishes what changed since the last update ended, one frame per display it touched.
    private func publishDamage() {
        guard mode == .standard, let core, let framebuffer, !damage.isEmpty else { return }
        // What a display could not be given now (its earlier pictures are all still in use) waits
        // for the next update, which publishes it together with whatever that one changes.
        var kept = DamageRegion()
        defer { damage = kept }
        let (displays, hubs, suspended) = core.shared.withLock { ($0.layout.displays, $0.hubs, $0.isSuspended) }
        guard !suspended else { return }
        for display in displays {
            let frame = display.frameInDesktop
            let touched = damage.clipped(to: frame)
            guard !touched.isEmpty, let hub = hubs[display.id] else { continue }
            guard let surface = framebuffer.snapshot(of: frame) else {
                for rectangle in touched.rectangles { kept.add(rectangle) }
                continue
            }
            let local = DamageRegion(touched.rectangles.map { PixelRect(x: $0.x - frame.x, y: $0.y - frame.y, width: $0.width, height: $0.height) })
            hub.publish(DisplayFrame(display: display.id, surface: surface, pixelSize: frame.size, damage: local, layoutGeneration: generation))
        }
        core.ready.resolve(.success(()))
        // A still screen sends no further update to carry what was kept; try again shortly.
        if !kept.isEmpty, !isRetryingPublish {
            isRetryingPublish = true
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(20))
                await self?.retryPublish()
            }
        }
    }

    private var isRetryingPublish = false

    private func retryPublish() {
        isRetryingPublish = false
        publishDamage()
    }

    // MARK: Layout

    private func apply(_ newLayout: DisplayLayout) async throws {
        guard let core else { return }
        let previous = layout
        layout = newLayout
        let isVirtual = newLayout.flags.contains(.onVirtualDisplay)

        if previous?.flags.intersection([.lockScreen, .loginWindow]) != newLayout.flags.intersection([.lockScreen, .loginWindow]) {
            core.events.send(.notice(.remoteScreenLocked(!newLayout.flags.intersection([.lockScreen, .loginWindow]).isEmpty)))
        }
        if mode == .standard {
            core.setCurtainState(newLayout.curtainState)
        }

        // With one screen selected the framebuffer is that screen alone.
        var screens = newLayout.screens
        if mode == .standard {
            // The Mac's main display (the one with the menu bar) first, so that it is "Display 1" and
            // the one shown first. High Performance keeps the Mac's order: its displays are its legs.
            screens = screens.filter { $0.flags.contains(.main) } + screens.filter { !$0.flags.contains(.main) }
        }
        if mode == .standard, let current = newLayout.currentScreen {
            screens = screens.filter { $0.id == current }
            if screens.isEmpty { screens = Array(newLayout.screens.prefix(1)) }
        }
        let single = mode == .standard && newLayout.currentScreen != nil
        var displays: [RemoteDisplay] = []
        var placements: [DisplayID: DisplayPlacement] = [:]
        var legDisplays: [DisplayID] = []
        for (index, screen) in screens.enumerated() {
            // Virtual displays are recreated under new ids at every change; their position in the
            // layout is what stays the same. Physical screens keep the Mac's own id.
            let id = mode == .highPerformance ? DisplayID(UInt32(index + 1)) : DisplayID(screen.id)
            let frame = single
                ? PixelRect(x: 0, y: 0, width: newLayout.framebufferWidth, height: newLayout.framebufferHeight)
                : PixelRect(x: screen.pixelLeft, y: screen.pixelTop, width: screen.pixelWidth, height: screen.pixelHeight)
            let name = screens.count == 1 && isVirtual ? String(localized: "Virtual Display", bundle: #bundle) : String(localized: "Display \(index + 1)", bundle: #bundle)
            displays.append(RemoteDisplay(
                id: id, name: name, kind: isVirtual ? .virtual : .physical,
                // A High Performance display is live once its stream delivers a picture of it.
                state: mode == .highPerformance ? .reconfiguring : .live,
                frameInDesktop: frame, scale: screen.density * screen.serverScale
            ))
            placements[id] = DisplayPlacement(originX: frame.x, originY: frame.y, scale: screen.density * screen.serverScale, serverScale: screen.serverScale)
            legDisplays.append(id)
        }

        let geometryChanged = previous.map { old in
            old.framebufferWidth != newLayout.framebufferWidth || old.framebufferHeight != newLayout.framebufferHeight
                || old.currentScreen != newLayout.currentScreen || old.screens != newLayout.screens
        } ?? true

        if geometryChanged {
            generation += 1
            publish(DesktopLayout(generation: generation, displays: displays), placements: placements, legDisplays: mode == .highPerformance ? legDisplays : [])
        }

        switch mode {
        case .standard:
            let size = PixelSize(width: newLayout.framebufferWidth, height: newLayout.framebufferHeight)
            guard size.width * size.height * 4 <= Framebuffer.byteBudget else {
                throw ARDError.unsupported(String(localized: "the Mac's screens (\(size.width) × \(size.height) pixels) are too large for this device; choose one display", bundle: #bundle))
            }
            if let framebuffer { framebuffer.resize(to: size) } else { framebuffer = Framebuffer(size: size) }
            damage = DamageRegion()
            // A layout drops the Mac's update arming. Ask for all of the framebuffer once and arm
            // it; from then on the Mac pushes what changes.
            armUpdates(requestingWholePicture: true)
            resolvePhysicalSelection(current: newLayout.currentScreen)
        case .highPerformance:
            await connection.setPixelFormat(.bgrx)
            // The picture never travels this way; the arming paces cursor shapes and layouts.
            armUpdates(requestingWholePicture: false)
            if core.options.wantsClipboard {
                connection.send(ClientMessage.autoPasteboard(true))
            }
            guard var state = highPerformance else { return }
            if isVirtual {
                if !state.layoutSinceChange, state.changeOutstanding {
                    // The Mac re-centres its pointer on the new displays and discards input meanwhile.
                    core.holdInputAfterDisplayChange(until: .now + core.timing.displayChangeInputHold)
                }
                state.layoutSinceChange = true
                state.reassertsWithoutVirtualLayout = 0
                highPerformance = state
            } else if state.reassertsWithoutVirtualLayout < 1 {
                highPerformance?.reassertsWithoutVirtualLayout += 1
                reassertVirtualDisplays()
            } else {
                core.note("the layout is not of this session's displays, and asking for them again did not bring them back")
            }
            try await offerIfReady()
        }
    }

    private func publish(_ desktop: DesktopLayout, placements: [DisplayID: DisplayPlacement], legDisplays: [DisplayID]) {
        guard let core else { return }
        let retired: [FrameHub] = core.shared.withLock { shared in
            var hubs: [DisplayID: FrameHub] = [:]
            for display in desktop.displays {
                hubs[display.id] = shared.hubs[display.id] ?? FrameHub()
            }
            let retired = shared.hubs.filter { hubs[$0.key] == nil }.map(\.value)
            shared.hubs = hubs
            shared.layout = desktop
            shared.placements = placements
            shared.legDisplays = legDisplays
            shared.awaitingNewLayout = false
            return retired
        }
        for hub in retired { hub.finish() }
        core.events.send(.layoutChanged(desktop))
    }

    // MARK: High Performance negotiation

    private func handle(_ reply: MediaReply) async throws {
        guard let core, var state = highPerformance else { return }
        switch reply {
        case .ports(let audio, let video, let second):
            var videoPorts = [video]
            if let second { videoPorts.append(second) }
            let all = [audio] + videoPorts
            // Media comes from these ports to the same port numbers here, so each must be one this
            // side can bind, and no two the same.
            guard all.allSatisfy({ $0 >= 1024 }), Set(all).count == all.count else {
                core.note("the Mac named unusable media ports: sound \(audio), pictures \(videoPorts)")
                core.ready.resolve(.failure(.modeUnavailable(mode: .highPerformance, reason: .notSupportedByServer)))
                throw ARDError.unsupported(String(localized: "the Mac named media ports this viewer cannot use (sound \(audio), pictures \(videoPorts))", bundle: #bundle))
            }
            guard !state.offerOutstanding else {
                // A Mac repeats its port message while it waits; the offer that is out is for them.
                core.note("the Mac named its media ports again while an offer is out")
                return
            }
            state.ports = MediaStreamReceiver.Ports(audio: audio, video: videoPorts)
            state.portsAnnounced = true
            // Ports are named once a configuration has taken effect, including one that asked for the
            // displays already showing, which brings no new layout.
            state.changeOutstanding = false
            highPerformance = state
            core.shared.withLock { $0.awaitingNewLayout = false }
            core.note("the Mac named its media ports: sound \(audio), pictures \(videoPorts)")
            if try await !offerIfReady(), highPerformance?.reassertPending == true {
                // No stream can start on these displays; ask for the session's own now.
                highPerformance?.reassertPending = false
                sendDisplayChange(isReassertion: true)
            }
        case .answer:
            guard state.offerOutstanding else {
                core.note("the Mac answered an offer that is not out")
                return
            }
            core.note("the Mac accepted the media offer")
            state.offerOutstanding = false
            state.portsAnnounced = false
            state.unansweredOffers = 0
            highPerformance = state
            core.shared.withLock { $0.lastAnswerAt = .now }
            // Apple's viewer sends its encoding list again after every answer.
            connection.send(ClientMessage.setEncodings(Encoding.highPerformance))
            if !state.sessionSizeApplied {
                highPerformance?.sessionSizeApplied = true
                sendDisplayChange()
            } else if state.desired != state.applied {
                sendDisplayChange()
            } else {
                resolveVirtualDisplayWaiters(.success(()))
                if state.reassertPending {
                    highPerformance?.reassertPending = false
                    sendDisplayChange(isReassertion: true)
                }
            }
        case .failure(let failure):
            let reason: ConnectionFailure
            switch failure {
            case .heldByAnotherViewer:
                reason = .busy(detail: String(localized: "Another viewer is using this Mac's High Performance stream.", bundle: #bundle))
            case .noConfiguration, .other:
                reason = .modeUnavailable(mode: .highPerformance, reason: .notSupportedByServer)
            }
            core.ready.resolve(.failure(reason))
            throw ARDError.refused(reason: String(localized: "the Mac could not start the media stream (\(failure))", bundle: #bundle))
        case .unknown:
            break
        }
    }

    /// Offers the stream when the Mac has named its ports for the displays now laid out and no
    /// earlier offer is unanswered. A second offer while one is starting breaks the Mac's capture.
    /// Returns whether it offered.
    @discardableResult
    private func offerIfReady() async throws -> Bool {
        guard let core, var state = highPerformance, let layout, let ports = state.ports,
              state.portsAnnounced, !state.offerOutstanding, layout.flags.contains(.onVirtualDisplay)
        else { return false }
        let legs = state.offer.videos.count
        let screens = Array(layout.screens.prefix(legs))
        guard screens.count == legs else { return false }
        // Ports may come before the layout they are for. Without a layout since the request, the
        // one showing is the right one only if it already has the size asked for.
        if !state.layoutSinceChange {
            let showing = screens.map { [UInt32($0.pixelWidth), UInt32($0.pixelHeight)] }
            guard showing == state.applied.map({ [$0.pixelWidth, $0.pixelHeight] }) else { return false }
        }
        guard ports.video.count >= legs else {
            core.note("the Mac named \(ports.video.count) picture ports for \(legs) displays")
            core.ready.resolve(.failure(.modeUnavailable(mode: .highPerformance, reason: .notSupportedByServer)))
            throw ARDError.unsupported(String(localized: "the Mac named \(ports.video.count) picture ports for \(legs) displays", bundle: #bundle))
        }
        var offer = Self.renewed(state.offer)
        for (index, screen) in screens.enumerated() {
            offer.videos[index].width = UInt16(clamping: screen.pixelWidth)
            offer.videos[index].height = UInt16(clamping: screen.pixelHeight)
        }
        let usedPorts = MediaStreamReceiver.Ports(audio: ports.audio, video: Array(ports.video.prefix(legs)))
        // Claimed before binding sockets suspends this actor, so that nothing else (a resize)
        // starts a request meanwhile.
        state.portsAnnounced = false
        state.offerOutstanding = true
        state.requestSerial += 1
        highPerformance = state

        var receiver = core.shared.withLock { $0.mediaReceiver }
        if let existing = receiver, state.boundPorts != usedPorts {
            core.note("the Mac's media ports changed; binding the new ones")
            existing.stop()
            core.shared.withLock { $0.mediaReceiver = nil }
            receiver = nil
        }
        if receiver == nil {
            do {
                let created = try await bindReceiver(ports: usedPorts, offer: offer)
                core.shared.withLock { $0.mediaReceiver = created }
                receiver = created
                highPerformance?.boundPorts = usedPorts
            } catch let error as TransportError {
                highPerformance?.offerOutstanding = false
                if case .addressInUse = error {
                    core.ready.resolve(.failure(.busy(detail: String(localized: "Another High Performance session from this device to this Mac is using its media ports.", bundle: #bundle))))
                } else if case .localNetworkDenied = error {
                    core.ready.resolve(.failure(.localNetworkDenied))
                }
                throw ARDError.transport(error)
            }
        }
        // Whatever changed while the sockets were bound stays; only the offer is new.
        highPerformance?.offer = offer
        do {
            try receiver?.beginStream(offer)
        } catch {
            highPerformance?.offerOutstanding = false
            throw ARDError.protocolViolation("the media keys could not be set up: \(error)")
        }
        core.prepareDecoders(legs: legs)
        #if DEBUG
        if let keyLog = core.timing.keyLog {
            keyLog("SRTP audio viewer-ssrc=\(offer.audioSSRC) to-viewer=\(offer.audioKeys.serverToViewer.bytes.hexString) to-mac=\(offer.audioKeys.viewerToServer.bytes.hexString)")
            for (index, video) in offer.videos.enumerated() {
                keyLog("SRTP video\(index) viewer-ssrc=\(video.ssrc) to-viewer=\(video.keys.serverToViewer.bytes.hexString) to-mac=\(video.keys.viewerToServer.bytes.hexString)")
            }
        }
        #endif
        connection.send(offer.message())
        core.restartMediaWatch()
        core.note("offered media for " + offer.videos.map { "\($0.width) × \($0.height)" }.joined(separator: " and "))
        startTimer(for: .offer)
        return true
    }

    /// Binds the media ports. A port released a moment ago may still be closing; that is retried
    /// briefly before it counts as taken.
    private func bindReceiver(ports: MediaStreamReceiver.Ports, offer: MediaOffer) async throws -> MediaStreamReceiver {
        guard let core else { throw ARDError.cancelled }
        var attempt = 0
        while true {
            do {
                let created = try await MediaStreamReceiver(transport: core.transport, ports: ports, offer: offer, diagnostics: core.diagnostics) { [weak core] event in
                    core?.handleMedia(event)
                }
                created.start()
                return created
            } catch TransportError.addressInUse(let port) where attempt < 5 {
                attempt += 1
                try? await Task.sleep(for: .milliseconds(20))
                if attempt == 5 { throw TransportError.addressInUse(port: port) }
            }
        }
    }

    /// Sends the desired display configuration. The change stops the stream, and the Mac answers
    /// with a layout and its ports, on which the stream is offered again.
    ///
    /// A re-assertion asks again for displays the session already had; it does not restart the
    /// media watchdog, so a Mac that never brings them back cannot keep the watchdog quiet.
    private func sendDisplayChange(isReassertion: Bool = false) {
        guard var state = highPerformance, let core else { return }
        // The configuration's count is fixed for the stream's legs.
        let modes = Array(state.desired.prefix(state.offer.videos.count))
        guard modes.count == state.offer.videos.count else { return }
        connection.send(ClientMessage.setDisplayConfiguration(modes, dynamic: true))
        if !isReassertion { core.restartMediaWatch() }
        core.note((isReassertion ? "asked again for virtual displays: " : "asked for virtual displays: ") + modes.map { "\($0.pointWidth) × \($0.pointHeight) pt (\($0.pixelWidth) × \($0.pixelHeight) px)" }.joined(separator: " and "))
        state.applied = state.desired
        state.changeOutstanding = true
        state.layoutSinceChange = false
        state.requestSerial += 1
        highPerformance = state
        startTimer(for: .change)
        // Input sent while the Mac makes the displays is lost with the old ones; it waits for the
        // new layout, and a while after it.
        core.holdInputAfterDisplayChange(until: .now + core.timing.displayChangeTimeout)
        let reconfiguring: DesktopLayout = core.shared.withLock { shared in
            for index in shared.layout.displays.indices { shared.layout.displays[index].state = .reconfiguring }
            shared.awaitingNewLayout = true
            shared.hasSessionDisplays = true
            shared.lastAnswerAt = nil
            return shared.layout
        }
        core.events.send(.layoutChanged(reconfiguring))
    }

    /// Asks for the session's displays again, now or once the request that is out is answered.
    private func reassertVirtualDisplays() {
        guard var state = highPerformance, state.sessionSizeApplied else { return }
        if state.changeOutstanding || state.offerOutstanding {
            state.reassertPending = true
            highPerformance = state
            return
        }
        sendDisplayChange(isReassertion: true)
    }

    // MARK: Request time limits

    private enum Request {
        case change
        case offer
    }

    private func startTimer(for request: Request) {
        guard let core, let serial = highPerformance?.requestSerial else { return }
        let limit = request == .change ? core.timing.displayChangeTimeout : core.timing.offerTimeout
        Task { [weak self] in
            try? await Task.sleep(for: limit)
            await self?.expire(request, serial: serial)
        }
    }

    private func expire(_ request: Request, serial: UInt64) {
        guard let core, !core.shared.withLock({ $0.state.isDisconnected }), var state = highPerformance, state.requestSerial == serial else { return }
        switch request {
        case .change:
            guard state.changeOutstanding else { return }
            // The Mac ignored the configuration (some sizes and refresh rates it silently refuses).
            // Its displays stay as they were, and the next request is sent whatever it asks for.
            core.note("the Mac did not take up the display configuration in \(core.timing.displayChangeTimeout)")
            let unanswered = state.applied
            state.changeOutstanding = false
            state.applied = []
            state.reassertPending = false
            highPerformance = state
            core.shared.withLock { $0.awaitingNewLayout = false }
            core.holdInputAfterDisplayChange(until: .now)
            if state.desired != unanswered, state.sessionSizeApplied {
                sendDisplayChange()
            } else {
                resolveVirtualDisplayWaiters(.failure(.timedOut))
            }
        case .offer:
            guard state.offerOutstanding else { return }
            core.note("the Mac did not answer the media offer in \(core.timing.offerTimeout)")
            state.offerOutstanding = false
            state.unansweredOffers += 1
            highPerformance = state
            resolveVirtualDisplayWaiters(.failure(.timedOut))
            if state.unansweredOffers > 1 || !state.sessionSizeApplied {
                core.finish(.mediaStalled(.silent))
            } else {
                // A configuration brings fresh ports, and with them a fresh offer.
                sendDisplayChange(isReassertion: true)
            }
        }
    }

    // MARK: Requests from capabilities

    enum DisplayChangeError: Error, Sendable, Equatable {
        case notAvailableInThisMode
        case tooManyDisplays(maximum: Int)
        case unknownDisplay
        case timedOut
        case sessionEnded
    }

    /// Resizes the session's virtual displays. Returns once the stream for the new displays is agreed.
    func setVirtualDisplays(_ requests: [VirtualDisplayRequest]) async throws(DisplayChangeError) {
        guard var state = highPerformance, let core else { throw .notAvailableInThisMode }
        guard requests.count == state.offer.videos.count else {
            // A Mac keeps the number of displays the session started with (macOS 27):
            // asked for another number later, it names a port for each but lays out only the ones
            // it has, and no stream can start. A different number needs a new session.
            throw .tooManyDisplays(maximum: state.offer.videos.count)
        }
        state.requests = requests
        state.desired = requests.map { Self.mode(for: $0, profile: state.offer.bandwidthProfile) }
        highPerformance = state
        if state.desired == state.applied, !state.changeOutstanding, !state.offerOutstanding { return }
        // Earlier requests are superseded: only the newest size is worth applying.
        resolveVirtualDisplayWaiters(.success(()))
        if state.sessionSizeApplied, !state.changeOutstanding, !state.offerOutstanding {
            sendDisplayChange()
        }
        // The change and the offer each have their own limit; this only bounds a wait that neither
        // would end.
        let backstop = core.timing.displayChangeTimeout + core.timing.offerTimeout
        try await wait(backstop) { .virtualDisplays($0) }
    }

    func selectPhysicalDisplays(_ selection: PhysicalDisplaySelection) async throws(DisplayChangeError) {
        guard mode == .standard, let layout else { throw .notAvailableInThisMode }
        let target: UInt32?
        switch selection {
        case .all:
            target = nil
        case .single(let id):
            guard layout.screens.contains(where: { $0.id == id.rawValue }) else { throw .unknownDisplay }
            target = id.rawValue
        }
        if layout.currentScreen == target { return }
        connection.send(ClientMessage.setDisplay(target))
        try await wait(core?.timing.displayChangeTimeout ?? .seconds(15)) { .physicalSelection(target, $0) }
    }

    func setQuality(_ preset: QualityPreset) {
        guard mode == .standard, preset != quality else { return }
        quality = preset
        switch preset {
        case .adaptive:
            connection.send(ClientMessage.setEncodings(Encoding.standardAdaptive))
        case .full:
            connection.send(ClientMessage.setEncodings(Encoding.standardFull))
        }
        // Either way the whole picture is wanted afresh: exact pixels in place of approximate
        // ones, or tiles the Mac and this side both start from.
        if let framebuffer {
            connection.send(ClientMessage.framebufferUpdateRequest(
                incremental: false, x: 0, y: 0,
                width: UInt16(clamping: framebuffer.size.width), height: UInt16(clamping: framebuffer.size.height)
            ))
        }
    }

    /// Called when the app returns to the foreground.
    func resumeMedia() {
        guard let core else { return }
        switch mode {
        case .standard:
            armUpdates(requestingWholePicture: true)
        case .highPerformance:
            armUpdates(requestingWholePicture: false)
            let (receiver, legs, suspendedAt) = core.shared.withLock { ($0.mediaReceiver, $0.legDisplays.count, $0.suspendedAt) }
            if let suspendedAt, ContinuousClock.now - suspendedAt > core.timing.resumeRestartThreshold {
                // In the background the Mac's packet numbers ran on by more than the receive path
                // and SRTP can follow; a fresh stream, with new keys, starts clean.
                restartStream()
            } else {
                for leg in 0..<legs { receiver?.requestKeyframe(leg: leg) }
            }
        }
    }

    /// Starts the stream afresh on the same connection: the displays are asked for again, which
    /// brings new ports and a new offer. A request already out does the same once it is answered.
    func restartStream() {
        guard highPerformance != nil else { return }
        reassertVirtualDisplays()
    }

    /// Goes on in the constrained media profile (0.33–6 Mbit/s instead of 20–60), with a fresh
    /// stream. Returns false when the stream is constrained already: then only Standard mode is left.
    func stepDown() -> Bool {
        guard var state = highPerformance, state.offer.bandwidthProfile == .full else { return false }
        core?.note("the path cannot carry the full rate; going on in the constrained media profile")
        state.offer.bandwidthProfile = .constrained
        state.desired = state.requests.map { Self.mode(for: $0, profile: .constrained) }
        highPerformance = state
        if state.sessionSizeApplied, !state.changeOutstanding, !state.offerOutstanding {
            sendDisplayChange()
        } else {
            highPerformance?.reassertPending = true
        }
        return true
    }

    // MARK: Waiters

    private func wait(_ limit: Duration, _ make: (CheckedContinuation<Result<Void, DisplayChangeError>, Never>) -> Waiter) async throws(DisplayChangeError) {
        nextWaiterID += 1
        let id = nextWaiterID
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            await self?.expire(id)
        }
        let result: Result<Void, DisplayChangeError> = await withCheckedContinuation { continuation in
            waiters.append((id, make(continuation)))
        }
        timeout.cancel()
        try result.get()
    }

    private func expire(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        resume(waiters.remove(at: index).waiter, with: .failure(.timedOut))
    }

    private func resume(_ waiter: Waiter, with result: Result<Void, DisplayChangeError>) {
        switch waiter {
        case .virtualDisplays(let continuation), .physicalSelection(_, let continuation):
            continuation.resume(returning: result)
        }
    }

    private func resolveVirtualDisplayWaiters(_ result: Result<Void, DisplayChangeError>) {
        let matching = waiters.filter { if case .virtualDisplays = $0.waiter { true } else { false } }
        waiters.removeAll { if case .virtualDisplays = $0.waiter { true } else { false } }
        for entry in matching { resume(entry.waiter, with: result) }
    }

    private func resolvePhysicalSelection(current: UInt32?) {
        let matching = waiters.filter { if case .physicalSelection(let target, _) = $0.waiter { target == current } else { false } }
        waiters.removeAll { if case .physicalSelection(let target, _) = $0.waiter { target == current } else { false } }
        for entry in matching { resume(entry.waiter, with: .success(())) }
    }

    private func failWaiters(_ error: DisplayChangeError) {
        let all = waiters
        waiters.removeAll()
        for entry in all { resume(entry.waiter, with: .failure(error)) }
    }
}
