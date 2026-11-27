// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoreGraphics
public import RemoteDesktopCore
import Synchronization

/// A session with a simulated remote machine.
///
/// Besides ``RemoteSession`` it exposes what the fake machine observed, so tests can assert on the
/// input that arrived, and hooks to make the fake machine do things on its own.
public final class SimulatedSession: RemoteSession {
    let core: SimulatedSessionCore

    init(scenario: SimulationScenario, mode: SessionMode, options: SessionOptions, isTunnelled: Bool) {
        core = SimulatedSessionCore(scenario: scenario, mode: mode, options: options, isTunnelled: isTunnelled)
    }

    deinit {
        core.finish(.userInitiated)
    }

    func start() async {
        await core.start()
    }

    // MARK: RemoteSession

    public var info: SessionInfo { core.info }
    public var state: SessionState { core.shared.withLock { $0.state } }
    public var layout: DesktopLayout { core.shared.withLock { $0.layout } }
    public var capabilities: SessionCapabilities { core.shared.withLock { $0.capabilities } }
    public var input: any InputSink { core }

    public func events() -> AsyncStream<SessionEvent> { core.events.subscribe() }
    public func cursor() -> AsyncStream<CursorState> { core.cursor.subscribe() }

    public func frames(for display: DisplayID) -> FrameMailbox {
        if let hub = core.shared.withLock({ $0.hubs[display] }) {
            return hub.subscribe()
        }
        let empty = FrameMailbox()
        empty.finish()
        return empty
    }

    public func suspend() async {
        if core.scenario.suspendDelay > .zero { try? await Task.sleep(for: core.scenario.suspendDelay) }
        core.setSuspended(true)
    }
    public func resume() async { core.setSuspended(false) }
    public func disconnect() async { core.finish(.userInitiated) }

    // MARK: Simulation hooks

    /// Every input event the simulated machine has received, in order.
    public var receivedInput: [InputEvent] { core.shared.withLock { $0.receivedInput } }

    /// Remote actions performed through the ``RemoteActions`` capability, in order.
    public var performedActions: [RemoteAction] { core.shared.withLock { $0.performedActions } }

    /// Every set of virtual displays asked for through ``DisplayConfiguration``, in order.
    public var requestedDisplays: [[VirtualDisplayRequest]] { core.shared.withLock { $0.requestedDisplays } }

    public var remoteClipboard: [ClipboardItem] { core.shared.withLock { $0.remoteClipboard } }

    /// Makes the simulated machine copy text, as if its user pressed Command-C.
    public func simulateRemoteCopy(_ text: String) {
        core.setRemoteClipboard([ClipboardItem(text: text)], announce: true)
    }

    /// Ends the session as if the remote side or the network did it.
    public func simulateDisconnect(_ reason: DisconnectReason) {
        core.finish(reason)
    }

    /// Moves the pointer as if someone used the simulated machine's own mouse. `position` is in
    /// desktop pixels.
    public func simulateRemotePointerMove(to position: PixelPoint) {
        let state = core.shared.withLock { shared in
            shared.cursorState.position = position
            shared.cursorState.remoteMoves &+= 1
            return shared.cursorState
        }
        core.cursor.send(state)
    }

    /// Posts a notice, as if the remote machine's state changed.
    public func simulateNotice(_ notice: SessionNotice) {
        core.events.send(.notice(notice))
    }

    /// What the simulated machine saw of drags of files.
    public enum FileDragEvent: Sendable, Hashable {
        /// A drag of the viewer's files entered the desktop, carrying these names.
        case began(names: [String], display: DisplayID, position: PixelPoint)
        case moved(display: DisplayID, position: PixelPoint)
        /// It was let go. `folder` is where the files belong; `nil` when what was under it takes none.
        case dropped(folder: String?)
        /// It ended without being let go.
        case cancelled
        /// A drag of the machine's own files started.
        case remoteDragStarted(paths: [String])
        /// The viewer took that drag over: the machine drops it nowhere.
        case remoteDragTaken
        /// The button came up on a drag nobody had taken, and the machine dropped the files where
        /// its pointer was.
        case remoteDragDropped
    }

    /// Every ``FileDragEvent`` so far, in order.
    public var fileDragEvents: [FileDragEvent] { core.shared.withLock { $0.fileDragEvents } }

    /// Where the desktop's folder is on a display, in the display's pixels. A viewer's drag let go
    /// inside it is taken; `nil` when the display is unknown or the machine knows no drags.
    public func desktopFolderFrame(on display: DisplayID) -> PixelRect? {
        core.desktopLayout(of: display).map { SimulatedDesktopLayout.pixelRect($0.folderRect, in: $0.bounds) }
    }

    /// Where the desktop's file is on a display: pressing there and moving starts a drag of it.
    public func desktopFileFrame(on display: DisplayID) -> PixelRect? {
        core.desktopLayout(of: display).map { SimulatedDesktopLayout.pixelRect($0.fileRect, in: $0.bounds) }
    }

    /// Starts a drag of files on the simulated machine, as if someone at it had picked them up. It
    /// is announced with the machine's picture of a file.
    public func simulateRemoteDrag(paths: [String]) {
        core.startOwnDrag(paths: paths)
    }

    /// Ends that drag as if the button had come up at the machine: unless the viewer took the
    /// drag, the machine drops the files where its pointer is.
    public func simulateRemoteDragEnd() {
        core.announce(core.shared.withLock { core.endOwnDrag(&$0) })
    }

    /// Waits until every input event sent so far has been drawn into a published frame.
    public func waitForInputToBeRendered() async {
        await core.engine.renderNow()
    }
}

/// Shared state and plumbing of a simulated session. Capability objects and the render engine hold
/// this; the public ``SimulatedSession`` owns it and tears it down when released.
final class SimulatedSessionCore: Sendable, InputSink {
    struct Shared {
        var state: SessionState = .connected
        var layout: DesktopLayout = .empty
        var capabilities = SessionCapabilities()
        var hubs: [DisplayID: FrameHub] = [:]
        var pendingInput: [InputEvent] = []
        var receivedInput: [InputEvent] = []
        var performedActions: [RemoteAction] = []
        var requestedDisplays: [[VirtualDisplayRequest]] = []
        var remoteClipboard: [ClipboardItem] = []
        var clipboardChangeCount: UInt64 = 0
        var controlMode: ControlMode = .control
        var isSuspended = false
        var cursorState = CursorState()
        var tasks: [Task<Void, Never>] = []
        var fileDragEvents: [SimulatedSession.FileDragEvent] = []
        /// The drag of the viewer's files, from when it enters until its drop is answered.
        var viewerDrag: ViewerDrag?
        var viewerDragCount: UInt64 = 0
        /// The drag of the machine's own files.
        var ownDrag: RemoteFileDrag?
        var isPrimaryButtonDown = false
        /// Where the primary button went down on the desktop's file, until it comes up or the
        /// pointer has moved far enough to drag the file away.
        var pressOnFile: PixelPoint?
        /// The last thing that happened to a drag of files, for the desktop's panel.
        var filesEcho = "—"
    }

    struct ViewerDrag {
        var id: UInt64
        var names: [String]
        var display: DisplayID
        var position: PixelPoint
        /// Let go where nothing takes files; the refusal is on its way.
        var isRefused = false
    }

    let scenario: SimulationScenario
    let info: SessionInfo
    let options: SessionOptions
    let shared = Mutex(Shared())
    let events = Broadcaster<SessionEvent>()
    let cursor = Broadcaster<CursorState>(replaysLatest: true, bufferingPolicy: .bufferingNewest(1))
    let clipboardOffers = Broadcaster<RemoteClipboardOffer>(replaysLatest: true, bufferingPolicy: .bufferingNewest(1))
    let remoteDrags = Broadcaster<RemoteFileDrag?>(replaysLatest: true, bufferingPolicy: .bufferingNewest(1))
    let engine: SimulatedEngine

    init(scenario: SimulationScenario, mode: SessionMode, options: SessionOptions, isTunnelled: Bool) {
        self.scenario = scenario
        self.options = options
        info = SessionInfo(
            backendID: SimulatedBackend.backendID,
            mode: mode,
            remoteName: scenario.remoteName,
            securityDescription: String(localized: "Simulated", bundle: #bundle),
            isTunnelled: isTunnelled,
            isEncrypted: scenario.encryptsSession,
            isServerAuthenticated: scenario.provesServerIdentity
        )
        engine = SimulatedEngine()
    }

    func start() async {
        shared.withLock { $0.controlMode = options.controlMode }
        let capabilities = makeCapabilities()
        shared.withLock { $0.capabilities = capabilities }

        let displays: [SimulationScenario.Display]
        if info.mode == .highPerformance, case .virtual(let requests) = options.displays, !requests.isEmpty {
            displays = requests.prefix(scenario.maximumVirtualDisplays).enumerated().map { index, request in
                SimulationScenario.Display(
                    name: index == 0 ? String(localized: "Virtual Display", bundle: #bundle) : String(localized: "Virtual Display #\(index + 1)", bundle: #bundle),
                    pixelSize: PixelSize(width: request.pointSize.width * request.scale, height: request.pointSize.height * request.scale),
                    scale: Double(request.scale),
                    isHDR: request.wantsHDR && scenario.makesHDRDisplays
                )
            }
            await engine.configure(core: self, displays: displays, kind: .virtual)
        } else {
            await engine.configure(core: self, displays: scenario.displays, kind: .physical)
        }

        if let text = scenario.initialRemoteClipboard {
            setRemoteClipboard([ClipboardItem(text: text)], announce: true)
        }

        let run = Task { [engine] in await engine.run() }
        shared.withLock { $0.tasks.append(run) }

        if let disconnect = scenario.disconnect {
            let timer = Task { [weak self] in
                try? await Task.sleep(for: disconnect.after)
                guard !Task.isCancelled else { return }
                self?.finish(disconnect.reason)
            }
            shared.withLock { $0.tasks.append(timer) }
        }

        if let automatic = scenario.fileDrags?.automaticDrag {
            let timer = Task { [weak self] in
                try? await Task.sleep(for: automatic.after)
                guard !Task.isCancelled else { return }
                self?.startOwnDrag(paths: automatic.paths)
            }
            shared.withLock { $0.tasks.append(timer) }
        }
    }

    // MARK: Input

    func send(_ event: InputEvent) {
        let (cursorUpdate, dragChange): (CursorState?, RemoteFileDrag??) = shared.withLock { shared in
            guard !shared.state.isDisconnected, !shared.isSuspended, shared.controlMode != .observe else { return (nil, nil) }
            shared.receivedInput.append(event)
            shared.pendingInput.append(event)
            if case .releaseAll = event {
                return (nil, primaryButtonChanged(isDown: false, at: nil, &shared))
            }
            guard case .pointer(let pointer) = event,
                  pointer.layoutGeneration == shared.layout.generation,
                  let display = shared.layout[pointer.display]
            else { return (nil, nil) }
            shared.cursorState.position = PixelPoint(
                x: Double(display.frameInDesktop.x) + pointer.position.x,
                y: Double(display.frameInDesktop.y) + pointer.position.y
            )
            return (shared.cursorState, primaryButtonChanged(isDown: pointer.buttons.contains(.primary), at: (pointer.position, display), &shared))
        }
        if let cursorUpdate { cursor.send(cursorUpdate) }
        announce(dragChange)
    }

    func drainInput() -> [InputEvent] {
        shared.withLock { shared in
            defer { shared.pendingInput.removeAll(keepingCapacity: true) }
            return shared.pendingInput
        }
    }

    // MARK: State changes

    func setSuspended(_ suspended: Bool) {
        let changed: Bool = shared.withLock { shared in
            guard !shared.state.isDisconnected, shared.isSuspended != suspended else { return false }
            shared.isSuspended = suspended
            shared.state = suspended ? .suspended : .connected
            return true
        }
        if changed {
            events.send(.stateChanged(suspended ? .suspended : .connected))
        }
    }

    func publishLayout(_ layout: DesktopLayout, hubs: [DisplayID: FrameHub], cursorScale: Double) {
        let retired: [FrameHub] = shared.withLock { shared in
            let retired = shared.hubs.filter { hubs[$0.key] == nil }.map(\.value)
            shared.layout = layout
            shared.hubs = hubs
            shared.cursorState.image = SimulatedCursor.arrow(scale: cursorScale)
            return retired
        }
        for hub in retired { hub.finish() }
        events.send(.layoutChanged(layout))
        cursor.send(shared.withLock { $0.cursorState })
    }

    func setRemoteClipboard(_ items: [ClipboardItem], announce: Bool) {
        let changeCount: UInt64 = shared.withLock { shared in
            shared.remoteClipboard = items
            shared.clipboardChangeCount += 1
            return shared.clipboardChangeCount
        }
        guard announce else { return }
        let types = items.first.map { Array($0.representations.keys).sorted() } ?? []
        clipboardOffers.send(RemoteClipboardOffer(changeCount: changeCount, typeIdentifiers: types) { items })
    }

    // MARK: Drags of files

    func desktopLayout(of display: DisplayID) -> SimulatedDesktopLayout? {
        guard scenario.fileDrags != nil, let display = shared.withLock({ $0.layout[display] }) else { return nil }
        return SimulatedDesktopLayout(pixelSize: display.pixelSize, scale: display.scale)
    }

    /// Tells subscribers that a drag of the machine's own files started (a value) or ended (`nil`).
    func announce(_ change: RemoteFileDrag??) {
        if let change { remoteDrags.send(change) }
    }

    /// Follows the primary button for the machine's own drag: pressing on the desktop's file and
    /// moving picks it up, and letting go ends the drag. Returns what there is to announce.
    private func primaryButtonChanged(isDown: Bool, at place: (position: PixelPoint, display: RemoteDisplay)?, _ shared: inout Shared) -> RemoteFileDrag?? {
        let wasDown = shared.isPrimaryButtonDown
        shared.isPrimaryButtonDown = isDown
        guard let drags = scenario.fileDrags else { return nil }
        guard isDown else {
            shared.pressOnFile = nil
            return wasDown ? endOwnDrag(&shared) : nil
        }
        guard let place else { return nil }
        if !wasDown {
            let layout = SimulatedDesktopLayout(pixelSize: place.display.pixelSize, scale: place.display.scale)
            let onFile = layout.fileRect.contains(CGPoint(x: place.position.x, y: place.position.y))
            shared.pressOnFile = onFile && shared.ownDrag == nil && shared.viewerDrag == nil ? place.position : nil
            return nil
        }
        // A press that stays put is a click; a few points of travel make it a drag, as on a Mac.
        guard let press = shared.pressOnFile,
              hypot(place.position.x - press.x, place.position.y - press.y) > 4 * place.display.scale
        else { return nil }
        shared.pressOnFile = nil
        return beginOwnDrag(paths: [drags.file], scale: place.display.scale, &shared)
    }

    private func beginOwnDrag(paths: [String], scale: Double, _ shared: inout Shared) -> RemoteFileDrag?? {
        guard !shared.state.isDisconnected, scenario.fileDrags != nil, !paths.isEmpty else { return nil }
        let drag = RemoteFileDrag(paths: paths, previewPNG: SimulatedDesktopArt.filePNG(scale: scale))
        shared.ownDrag = drag
        shared.fileDragEvents.append(.remoteDragStarted(paths: paths))
        shared.filesEcho = "dragging \(Self.describe(paths))"
        return .some(drag)
    }

    func startOwnDrag(paths: [String]) {
        announce(shared.withLock { shared in
            beginOwnDrag(paths: paths, scale: shared.layout.displays.first?.scale ?? 1, &shared)
        })
    }

    /// The button came up at the machine: a drag nobody took is dropped where the pointer is.
    func endOwnDrag(_ shared: inout Shared) -> RemoteFileDrag?? {
        guard let drag = shared.ownDrag else { return nil }
        shared.ownDrag = nil
        shared.fileDragEvents.append(.remoteDragDropped)
        shared.filesEcho = "dropped \(Self.describe(drag.paths)) here"
        return .some(nil)
    }

    /// The viewer takes the machine's drag over. Too late once the button has come up.
    func takeOwnDrag() {
        announce(shared.withLock { shared -> RemoteFileDrag?? in
            guard let drag = shared.ownDrag else { return nil }
            shared.ownDrag = nil
            shared.fileDragEvents.append(.remoteDragTaken)
            shared.filesEcho = "\(Self.describe(drag.paths)) taken by the viewer"
            return .some(nil)
        })
    }

    private static func describe(_ paths: [String]) -> String {
        let name = paths.first.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? ""
        return paths.count == 1 ? name : "\(name) and \(paths.count - 1) more"
    }

    private func folder(under drag: ViewerDrag, _ shared: Shared) -> String? {
        guard let drags = scenario.fileDrags, let display = shared.layout[drag.display] else { return nil }
        let layout = SimulatedDesktopLayout(pixelSize: display.pixelSize, scale: display.scale)
        return layout.folderRect.contains(CGPoint(x: drag.position.x, y: drag.position.y)) ? drags.folder : nil
    }

    /// Puts the viewer's drag, and the pointer with it, at a place on a display.
    private func place(_ drag: ViewerDrag, _ shared: inout Shared) -> CursorState? {
        shared.viewerDrag = drag
        let count = drag.names.count == 1 ? "1 file" : "\(drag.names.count) files"
        shared.filesEcho = folder(under: drag, shared).map { "\(count) over \($0)" } ?? "\(count) over the desktop"
        guard let display = shared.layout[drag.display] else { return nil }
        shared.cursorState.position = PixelPoint(
            x: Double(display.frameInDesktop.x) + drag.position.x,
            y: Double(display.frameInDesktop.y) + drag.position.y
        )
        return shared.cursorState
    }

    func beginViewerDrag(names: [String], at position: PixelPoint, on display: DisplayID) throws(FileDragError) -> UInt64 {
        let (id, cursorUpdate): (UInt64, CursorState?) = try shared.withLock { shared throws(FileDragError) in
            guard !shared.state.isDisconnected else { throw .sessionEnded }
            guard shared.viewerDrag == nil else { throw .busy }
            shared.viewerDragCount += 1
            shared.fileDragEvents.append(.began(names: names, display: display, position: position))
            let drag = ViewerDrag(id: shared.viewerDragCount, names: names, display: display, position: position)
            return (drag.id, place(drag, &shared))
        }
        if let cursorUpdate { cursor.send(cursorUpdate) }
        return id
    }

    func moveViewerDrag(_ id: UInt64, to position: PixelPoint, on display: DisplayID) {
        let cursorUpdate: CursorState? = shared.withLock { shared in
            guard var drag = shared.viewerDrag, drag.id == id, !drag.isRefused else { return nil }
            drag.display = display
            drag.position = position
            shared.fileDragEvents.append(.moved(display: display, position: position))
            return place(drag, &shared)
        }
        if let cursorUpdate { cursor.send(cursorUpdate) }
    }

    func dropViewerDrag(_ id: UInt64) async throws -> String {
        let outcome: (folder: String?, refusal: Task<Void, Never>?)? = shared.withLock { shared in
            guard !shared.state.isDisconnected, let drag = shared.viewerDrag, drag.id == id, !drag.isRefused else { return nil }
            let folder = folder(under: drag, shared)
            shared.fileDragEvents.append(.dropped(folder: folder))
            if let folder {
                shared.viewerDrag = nil
                shared.filesEcho = "\(drag.names.count) dropped into \(folder)"
                return (folder, nil)
            }
            shared.viewerDrag?.isRefused = true
            shared.filesEcho = "\(drag.names.count) dropped where nothing takes files"
            // Ended with the session, so that the wait is cut short when it ends.
            let delay = scenario.fileDrags?.refusalDelay ?? .zero
            let refusal = Task { _ = try? await Task.sleep(for: delay) }
            shared.tasks.append(refusal)
            return (nil, refusal)
        }
        guard let outcome else { throw FileDragError.sessionEnded }
        if let folder = outcome.folder { return folder }
        await outcome.refusal?.value
        let ended = shared.withLock { shared in
            if shared.viewerDrag?.id == id { shared.viewerDrag = nil }
            return shared.state.isDisconnected
        }
        throw ended ? FileDragError.sessionEnded : FileDragError.notAccepted
    }

    func cancelViewerDrag(_ id: UInt64) {
        shared.withLock { shared in
            // Once let go, the drop is the machine's to answer.
            guard let drag = shared.viewerDrag, drag.id == id, !drag.isRefused else { return }
            shared.viewerDrag = nil
            shared.fileDragEvents.append(.cancelled)
            shared.filesEcho = "drag left"
        }
    }

    func finish(_ reason: DisconnectReason) {
        let teardown: (hubs: [FrameHub], tasks: [Task<Void, Never>])? = shared.withLock { shared in
            guard !shared.state.isDisconnected else { return nil }
            shared.state = .disconnected(reason)
            shared.ownDrag = nil
            // Capability objects reference this core; dropping them breaks the cycle.
            shared.capabilities = SessionCapabilities()
            defer {
                shared.hubs.removeAll()
                shared.tasks.removeAll()
            }
            return (Array(shared.hubs.values), shared.tasks)
        }
        guard let teardown else { return }
        for task in teardown.tasks { task.cancel() }
        for hub in teardown.hubs { hub.finish() }
        events.send(.stateChanged(.disconnected(reason)))
        events.finish()
        cursor.finish()
        clipboardOffers.finish()
        remoteDrags.send(nil)
        remoteDrags.finish()
    }
}

/// Owns the canvases and turns input into pixels. One per session.
actor SimulatedEngine {
    private struct Screen {
        var display: RemoteDisplay
        var canvas: SimulatedCanvas
        var hub: FrameHub
        var content: SimulatedDesktopContent
    }

    private weak var core: SimulatedSessionCore?
    private var screens: [Screen] = []
    private var generation: UInt64 = 0
    private var frameCounter: UInt64 = 0
    private var typedText = ""
    private var scrollTotal = (x: 0.0, y: 0.0)
    private var buttonsDown: PointerButtons = []
    private var clicks: [DisplayID: [PixelPoint]] = [:]
    private var echo = SimulatedDesktopContent()
    private var configurationToken: UInt64 = 0

    func configure(core: SimulatedSessionCore, displays: [SimulationScenario.Display], kind: RemoteDisplay.Kind) {
        self.core = core
        apply(displays: displays, kind: kind)
    }

    /// Replaces the display set after a simulated delay. Later requests supersede earlier ones.
    func reconfigure(displays: [SimulationScenario.Display], kind: RemoteDisplay.Kind, delay: Duration) async throws {
        configurationToken += 1
        let token = configurationToken
        if let core {
            var pending = core.shared.withLock { $0.layout }
            for index in pending.displays.indices { pending.displays[index].state = .reconfiguring }
            core.shared.withLock { $0.layout = pending }
            core.events.send(.layoutChanged(pending))
        }
        try await Task.sleep(for: delay)
        guard token == configurationToken else { return }
        apply(displays: displays, kind: kind)
    }

    private func apply(displays: [SimulationScenario.Display], kind: RemoteDisplay.Kind) {
        guard let core else { return }
        generation += 1
        var x = 0
        var hubs: [DisplayID: FrameHub] = [:]
        var newScreens: [Screen] = []
        for (index, display) in displays.enumerated() {
            guard let canvas = SimulatedCanvas(pixelSize: display.pixelSize, scale: display.scale, isHDR: display.isHDR) else { continue }
            // Identity is positional and stable across resizes, so consumers keep their subscription.
            let id = DisplayID(UInt32(index + 1))
            let remote = RemoteDisplay(
                id: id,
                name: display.name,
                kind: kind,
                frameInDesktop: PixelRect(x: x, y: 0, width: display.pixelSize.width, height: display.pixelSize.height),
                scale: display.scale,
                isHDR: display.isHDR
            )
            x += display.pixelSize.width
            let hub = screens.first { $0.display.id == id }?.hub ?? FrameHub()
            hubs[id] = hub
            newScreens.append(Screen(display: remote, canvas: canvas, hub: hub, content: SimulatedDesktopContent()))
        }
        screens = newScreens
        clicks = clicks.filter { hubs[$0.key] != nil }
        let layout = DesktopLayout(generation: generation, displays: newScreens.map(\.display))
        core.publishLayout(layout, hubs: hubs, cursorScale: newScreens.first?.display.scale ?? 1)
        render(advanceCounter: false)
    }

    func run() async {
        guard let frameRate = core?.scenario.frameRate, frameRate > 0 else { return }
        let interval = Duration.nanoseconds(1_000_000_000 / Int64(frameRate))
        let clock = ContinuousClock()
        var next = clock.now
        while !Task.isCancelled {
            next += interval
            do { try await clock.sleep(until: next) } catch { return }
            guard let core else { return }
            let (suspended, finished) = core.shared.withLock { ($0.isSuspended, $0.state.isDisconnected) }
            if finished { return }
            if suspended { continue }
            render(advanceCounter: true)
        }
    }

    /// Applies pending input and publishes a frame immediately.
    func renderNow() {
        render(advanceCounter: false)
    }

    private func render(advanceCounter: Bool) {
        guard let core else { return }
        for event in core.drainInput() { absorb(event) }
        if advanceCounter { frameCounter += 1 }
        let (clipboardText, files, viewerDrag, isFileLifted) = core.shared.withLock {
            ($0.remoteClipboard.first?.text, $0.filesEcho, $0.viewerDrag, $0.ownDrag != nil)
        }
        let desktopItems = core.scenario.fileDrags.map {
            SimulatedDesktopContent.DesktopItems(folder: Self.name(of: $0.folder), file: Self.name(of: $0.file))
        }
        for index in screens.indices {
            var content = echo
            content.displayName = screens[index].display.name
            content.modeLabel = core.info.mode == .highPerformance ? "High Performance" : "Standard"
            content.typedText = typedText
            content.clipboard = clipboardText.map { String($0.prefix(40)) } ?? "—"
            content.files = files
            content.desktopItems = desktopItems
            content.isFileLifted = isFileLifted
            if let viewerDrag, !viewerDrag.isRefused, viewerDrag.display == screens[index].display.id {
                let layout = SimulatedDesktopLayout(pixelSize: screens[index].display.pixelSize, scale: screens[index].display.scale)
                content.isFolderHighlighted = layout.folderRect.contains(CGPoint(x: viewerDrag.position.x, y: viewerDrag.position.y))
            }
            content.clicks = clicks[screens[index].display.id] ?? []
            content.frameCounter = frameCounter
            let damage = screens[index].canvas.update(to: content)
            screens[index].content = content
            guard !damage.isEmpty, let surface = screens[index].canvas.snapshot() else { continue }
            screens[index].hub.publish(
                DisplayFrame(
                    display: screens[index].display.id,
                    surface: surface,
                    pixelSize: screens[index].display.pixelSize,
                    damage: damage,
                    layoutGeneration: generation
                )
            )
        }
    }

    private func absorb(_ event: InputEvent) {
        switch event {
        case .key(let key):
            echo.modifiers = Self.describe(key.modifiers)
            guard key.phase == .down else { return }
            echo.lastKey = Self.describe(key)
            if key.modifiers.hasCommand || key.modifiers.hasControl { return }
            switch key.key {
            case .deleteBackward?:
                if !typedText.isEmpty { typedText.removeLast() }
            case .returnOrEnter?, .keypadEnter?:
                typedText += "⏎"
            case .tab?:
                typedText += "⇥"
            default:
                if let characters = key.characters, key.key?.modifier == nil { typedText += characters }
            }
        case .text(let text):
            typedText += text
            echo.lastKey = "text “\(text.prefix(16))”"
        case .pointer(let pointer):
            guard pointer.layoutGeneration == generation else { return }
            echo.pointer = "\(pointer.display) (\(Int(pointer.position.x)), \(Int(pointer.position.y)))"
            let pressed = pointer.buttons.subtracting(buttonsDown)
            if pressed.contains(.primary) || pressed.contains(.secondary) {
                var list = clicks[pointer.display] ?? []
                list.append(pointer.position)
                clicks[pointer.display] = Array(list.suffix(9))
            }
            buttonsDown = pointer.buttons
            echo.buttons = Self.describe(pointer.buttons)
        case .scroll(let scroll):
            scrollTotal.x += scroll.deltaX
            scrollTotal.y += scroll.deltaY
            echo.scroll = "Δ(\(Int(scroll.deltaX)), \(Int(scroll.deltaY))) total (\(Int(scrollTotal.x)), \(Int(scrollTotal.y)))"
        case .gesture(let gesture):
            echo.scroll = "gesture \(gesture.kind)"
        case .touch(let touch):
            guard touch.layoutGeneration == generation else { return }
            let touching = touch.contacts.filter { $0.phase == .touching }
            echo.pointer = touching.isEmpty
                ? "\(touch.display) no fingers"
                : "\(touch.display) " + touching.map { "(\(Int($0.position.x)), \(Int($0.position.y)))" }.joined(separator: " ")
            // A finger that lifts marks the place, as a click does.
            for contact in touch.contacts where contact.phase == .lifted {
                clicks[touch.display] = Array(((clicks[touch.display] ?? []) + [contact.position]).suffix(9))
            }
        case .releaseAll:
            buttonsDown = []
            echo.buttons = "—"
            echo.modifiers = "—"
        }
    }

    private static func name(of path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    private static func describe(_ modifiers: KeyModifiers) -> String {
        var symbols = ""
        if modifiers.contains(.function) { symbols += "fn" }
        if modifiers.hasControl { symbols += "⌃" }
        if modifiers.hasOption { symbols += "⌥" }
        if modifiers.hasShift { symbols += "⇧" }
        if modifiers.hasCommand { symbols += "⌘" }
        if modifiers.contains(.capsLock) { symbols += "⇪" }
        return symbols.isEmpty ? "—" : symbols
    }

    private static func describe(_ key: KeyEvent) -> String {
        let prefix = describe(key.modifiers)
        let name: String
        if let characters = key.charactersIgnoringModifiers ?? key.characters, !characters.isEmpty, characters != " " {
            name = characters.uppercased()
        } else if let code = key.key {
            name = switch code {
            case .space: "Space"
            case .returnOrEnter: "Return"
            case .escape: "Esc"
            case .tab: "Tab"
            case .deleteBackward: "Delete"
            case .deleteForward: "Fwd Delete"
            case .leftArrow: "←"
            case .rightArrow: "→"
            case .upArrow: "↑"
            case .downArrow: "↓"
            case .home: "Home"
            case .end: "End"
            case .pageUp: "Page Up"
            case .pageDown: "Page Down"
            default:
                (KeyCode.f1.rawValue...KeyCode.f12.rawValue).contains(code.rawValue)
                    ? "F\(code.rawValue - KeyCode.f1.rawValue + 1)"
                    : String(format: "key 0x%02X", code.rawValue)
            }
        } else {
            name = "?"
        }
        return prefix == "—" ? name : prefix + name
    }

    private static func describe(_ buttons: PointerButtons) -> String {
        var names: [String] = []
        if buttons.contains(.primary) { names.append("primary") }
        if buttons.contains(.secondary) { names.append("secondary") }
        if buttons.contains(.middle) { names.append("middle") }
        return names.isEmpty ? "—" : names.joined(separator: " + ")
    }
}
