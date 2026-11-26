// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

@_spi(Diagnostics) import AppleScreenSharing
import ARDProtocol
import VNCBackend
import CoreVideo
import Foundation
import RemoteDesktopCore
import RemoteDesktopTransport
import Synchronization

/// Runs a session through the same interface the app uses, and reports what came out of it.
func runSession(_ arguments: Arguments) async throws {
    guard let user = arguments.option("user", environment: "MARIONETTE_TEST_USER"),
          let password = arguments.option("password", environment: "MARIONETTE_TEST_PASSWORD")
    else { throw Failure("a user name and password are required") }
    let seconds = Double(arguments.option("seconds") ?? "5") ?? 5

    var options = SessionOptions()
    switch arguments.option("mode") ?? "auto" {
    case "hp": options.mode = .require(.highPerformance)
    case "standard": options.mode = .require(.standard)
    default: options.mode = .automatic
    }
    switch arguments.option("quality") ?? "adaptive" {
    case "adaptive": options.quality = .adaptive
    case "full": options.quality = .full
    case let other: throw Failure("unknown quality \(other); use adaptive or full")
    }
    let sizeParts = (arguments.option("size") ?? "1440x900").split(separator: "x").compactMap { Int($0) }
    guard sizeParts.count == 2 else { throw Failure("--size must look like 1440x900") }
    let scale = Int(arguments.option("scale") ?? "2") ?? 2
    let displayCount = Int(arguments.option("displays") ?? "1") ?? 1
    options.displays = .virtual(Array(repeating: VirtualDisplayRequest(pointSize: PixelSize(width: sizeParts[0], height: sizeParts[1]), scale: scale), count: displayCount))
    if let physical = arguments.option("physical") {
        if physical == "all" {
            options.displays = .physical(.all)
        } else if let id = UInt32(physical) {
            options.displays = .physical(.single(DisplayID(id)))
        } else {
            throw Failure("--physical is all or a display id, not \(physical)")
        }
    }

    let started = ContinuousClock.now
    @Sendable func log(_ message: String) {
        let elapsed = ContinuousClock.now - started
        print(String(format: "%6.2fs  %@", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, message))
    }

    let sessionChoice: SessionChoice
    switch arguments.option("session-choice") ?? "ask" {
    case "ask": sessionChoice = .askToShareConsole
    case "self": sessionChoice = .logInAsSelf
    case let other: throw Failure("--session-choice is ask or self, not \(other)")
    }
    let prompts = StaticPromptHandler(username: user, password: password, trustsUnknownHosts: true, sessionChoice: sessionChoice)
    var transport: any TransportProvider = DirectTransportProvider(peer: Endpoint(host: arguments.host, port: arguments.port))
    var tunnel: SSHConnection?
    if arguments.flags.contains("ssh") {
        // Through the machine's own SSH server, which then reaches Screen Sharing on localhost.
        let connection = try await SSHConnection.establish(
            SSHLogin(server: Endpoint(host: arguments.host, port: 22), username: user), prompts: prompts, hostKeys: InMemoryHostKeyStore()
        )
        log("SSH tunnel up: \(connection.hostKey.algorithm) \(connection.hostKey.fingerprint)")
        transport = SSHTunnelTransportProvider(connection: connection, peer: Endpoint(host: arguments.host, port: arguments.port), hostFromServer: "localhost")
        tunnel = connection
        if arguments.flags.contains("files") {
            let files = SFTPFileTransfer(connection: connection)
            let directory = try await files.defaultUploadDirectory()
            let entries = try await files.list(directory: (directory as NSString).deletingLastPathComponent)
            log("SFTP: uploads go to \(directory); home has \(entries.map(\.name).joined(separator: ", "))")
        }
    }
    // A bad network on request: the same losses every run for the same seed.
    let ledger = ImpairmentLedger()
    var conditionChanges: (control: ImpairmentControl, steps: [ImpairmentControl.Step])?
    if let conditions = try networkConditions(arguments) {
        let control = ImpairmentControl(conditions.start)
        transport = conditions.changes.isEmpty
            ? ImpairedTransportProvider(transport, impairment: conditions.start, ledger: ledger)
            : ImpairedTransportProvider(transport, control: control, ledger: ledger)
        log("impairing the network: \(describe(conditions.start))")
        for step in conditions.changes {
            log("  \(step.after) after connecting: \(describe(step.impairment))")
        }
        if !conditions.changes.isEmpty { conditionChanges = (control, conditions.changes) }
    }
    let request = ConnectionRequest(
        options: options,
        transport: transport,
        prompts: prompts,
        progress: { log("phase: \($0)") }
    )
    let backend: any RemoteDesktopBackend = switch arguments.option("backend") ?? "apple" {
    case "apple": {
        var backend = AppleScreenSharingBackend()
        if arguments.flags.contains("trace") { backend.diagnostics = { log("  · " + $0) } }
        switch arguments.option("codec") ?? "auto" {
        case "hevc": backend.videoCodec = .hevc
        case "h264": backend.videoCodec = .h264
        default: backend.videoCodec = .automatic
        }
        // For measuring how much input a Mac loses around a display change.
        if arguments.flags.contains("no-input-hold") { backend.holdsInputAroundDisplayChanges = false }
        // For comparing what a Mac does with plain key and pointer events.
        if arguments.flags.contains("plain-input") { backend.encryptsInput = false }
        // Leave out the SetDisplay that says every display is shown (experiments).
        if arguments.flags.contains("no-set-display") { backend.saysEveryDisplay = false }
        if arguments.option("profile") == "constrained" { backend.startsConstrained = true }
        if arguments.option("login") == "vnc" { backend.loginTypes = [.vncPassword] }
        // --viewer-version 7.0.0/27.0.0: what ViewerInfo says (application/system).
        if let versions = arguments.option("viewer-version")?.split(separator: "/"), versions.count == 2 {
            let parse = { (text: Substring) in text.split(separator: ".").compactMap { UInt32($0) } }
            backend.viewerVersions = (parse(versions[0]), parse(versions[1]))
        }
        // Debug builds: the session's keys, so a capture of it can be decrypted.
        if let path = arguments.option("keylog") {
            FileManager.default.createFile(atPath: path, contents: nil)
            let file = FileHandle(forWritingAtPath: path)
            backend.keyLog = { line in file?.write(Data((line + "\n").utf8)) }
        }
        return backend
    }()
    case "vnc": VNCBackend()
    case let other: throw Failure("unknown back end \(other); use apple or vnc")
    }
    let session = try await backend.connect(request)
    log("connected: \(session.info.remoteName), \(session.info.mode), \(session.info.securityDescription)")
    // Changes count from here, so that a slow login does not use them up.
    if let conditionChanges { conditionChanges.control.play(conditionChanges.steps) }
    for display in session.layout.displays {
        log("display \(display.id): \(display.name), \(display.pixelSize.width) × \(display.pixelSize.height) at \(display.scale)x, \(display.kind), \(display.state)")
    }
    let capabilities = session.capabilities
    log("capabilities: clipboard \(capabilities.clipboard.isAvailable), audio \(capabilities.audio.isAvailable), quality \(capabilities.quality.isAvailable), statistics \(capabilities.statistics.isAvailable), curtain \(describe(capabilities.curtain)), touch \(describe(capabilities.touch))")

    struct Counts {
        var frames: [DisplayID: Int] = [:]
        var last: [DisplayID: DisplayFrame] = [:]
        var audioChunks = 0
        var audibleChunks = 0
        var audioPeak: Float = 0
        var cursorUpdates = 0
        var cursorShape: PixelSize?
        var cursorID: UInt64?
        var remoteMoves: UInt64 = 0
    }
    let counts = Mutex(Counts())
    var tasks: [Task<Void, Never>] = []

    func watch(_ display: DisplayID) {
        let mailbox = session.frames(for: display)
        tasks.append(Task {
            for await frame in mailbox {
                counts.withLock { state in
                    state.frames[display, default: 0] += 1
                    state.last[display] = frame
                }
            }
        })
    }
    for display in session.layout.displays { watch(display.id) }

    tasks.append(Task {
        for await event in session.events() {
            switch event {
            case .stateChanged(let state): log("state: \(state)")
            case .layoutChanged(let layout):
                log("layout \(layout.generation): " + layout.displays.map { "\($0.id) \($0.pixelSize.width)×\($0.pixelSize.height) \($0.state)" }.joined(separator: ", "))
            case .notice(let notice): log("notice: \(notice)")
            case .capabilitiesChanged(let capabilities): log("curtain mode: \(describe(capabilities.curtain))")
            }
        }
    })
    tasks.append(Task {
        for await cursor in session.cursor() {
            let changed: Bool = counts.withLock { state in
                state.cursorUpdates += 1
                defer {
                    state.cursorShape = cursor.image?.pixelSize ?? state.cursorShape
                    state.cursorID = cursor.image?.id ?? state.cursorID
                }
                return cursor.image != nil && cursor.image?.id != state.cursorID
            }
            if changed, arguments.flags.contains("trace"), let image = cursor.image {
                log("cursor shape \(image.id): \(image.pixelSize.width) × \(image.pixelSize.height)")
            }
            let moved: Bool = counts.withLock { state in
                defer { state.remoteMoves = cursor.remoteMoves }
                return cursor.remoteMoves != state.remoteMoves
            }
            if moved, arguments.flags.contains("trace"), let position = cursor.position {
                log("pointer moved on the Mac to \(Int(position.x)), \(Int(position.y))")
            }
        }
    })
    if let audio = capabilities.audio.value {
        tasks.append(Task {
            let recording = arguments.option("audio").map { URL(fileURLWithPath: $0) }
            var pcm = Data()
            var format: (rate: Double, channels: Int)?
            for await chunk in audio.chunks() {
                let peak = chunk.samples.withUnsafeBytes { raw in
                    raw.bindMemory(to: Float.self).reduce(Float(0)) { max($0, abs($1)) }
                }
                counts.withLock { state in
                    state.audioChunks += 1
                    state.audioPeak = max(state.audioPeak, peak)
                    if peak > 0.01 { state.audibleChunks += 1 }
                }
                if recording != nil {
                    format = (chunk.sampleRate, chunk.channelCount)
                    pcm.append(chunk.samples)
                    if let recording, let format { try? wav(pcm, rate: format.rate, channels: format.channels).write(to: recording) }
                }
            }
        })
    }
    if arguments.flags.contains("stats"), let source = capabilities.statistics.value {
        tasks.append(Task {
            var shownBefore = 0
            for await sample in source.statistics() {
                let impaired = ledger.snapshot
                // Pictures assembled (the statistics) against pictures decoded and shown (the
                // frames that came out), and how long each path has been quiet.
                let shown = counts.withLock { $0.frames.values.reduce(0, +) }
                defer { shownBefore = shown }
                if let ard = session as? ARDSession {
                    let silence = ard.silence
                    log(String(format: "liveness: control quiet %.1f s, picture legs quiet %@; shown %d/s", Double(silence.control.components.seconds) + Double(silence.control.components.attoseconds) / 1e18,
                               silence.pictureLegs.map { $0.map { String(format: "%.1f s", Double($0.components.seconds) + Double($0.components.attoseconds) / 1e18) } ?? "–" }.joined(separator: ", "), shown - shownBefore))
                }
                log(String(
                    format: "stats: %2.0f pictures/s, %6.2f Mbit/s, loss %@, dropped by test %d of %d (%d by the queue)",
                    sample.framesPerSecond ?? 0, (sample.bitrate ?? 0) / 1e6,
                    sample.packetLoss.map { String(format: "%.1f %%", $0 * 100) } ?? "–",
                    impaired.droppedInbound + impaired.overflowedInbound, impaired.received, impaired.overflowedInbound
                ))
            }
        })
    }
    if let drags = capabilities.fileDrag.value {
        tasks.append(Task {
            for await drag in drags.remoteDrags() {
                scriptRemoteDrag.withLock { $0 = drag }
                if let drag {
                    log("the Mac is dragging \(drag.paths), picture of \(drag.previewPNG?.count ?? 0) bytes")
                } else {
                    log("no drag on the Mac")
                }
            }
        })
    }
    if let clipboard = capabilities.clipboard.value {
        tasks.append(Task {
            for await offer in clipboard.remoteOffers() {
                let items = (try? await offer.load()) ?? []
                log("remote clipboard changed: \(items.first?.text.map { "“\($0.prefix(60))”" } ?? "\(items.count) item(s), no text")")
                if arguments.flags.contains("clipboard-dump") {
                    for (index, item) in items.enumerated() {
                        for (type, data) in item.representations.sorted(by: { $0.key < $1.key }) {
                            let preview = String(decoding: data.prefix(120), as: UTF8.self).replacingOccurrences(of: "\n", with: "⏎")
                            log("  item \(index) \(type): \(data.count) bytes \(data.prefix(24).map { String(format: "%02x", $0) }.joined()) “\(preview)”")
                        }
                    }
                }
            }
        })
    }

    if let display = session.layout.displays.first {
        let generation = session.layout.generation
        let centre = PixelPoint(x: Double(display.pixelSize.width) / 2, y: Double(display.pixelSize.height) / 2)
        try await Task.sleep(for: .milliseconds(500))
        for step in 0..<(Int(arguments.option("moves") ?? "20") ?? 20) {
            let point = PixelPoint(x: centre.x + Double(step) * 10, y: centre.y + Double(step) * 6)
            session.input.send(.pointer(PointerEvent(display: display.id, position: point, layoutGeneration: generation)))
            try await Task.sleep(for: .milliseconds(20))
        }
        if let text = arguments.option("copy"), let clipboard = capabilities.clipboard.value {
            try await clipboard.sendToRemote([ClipboardItem(text: text)])
            log("put “\(text)” on the Mac's clipboard")
        }
        if let text = arguments.option("type") {
            session.input.send(.text(text))
            log("typed “\(text)”")
        }
        if let script = arguments.option("script") {
            try await runInputScript(script, on: session, log: log) { name in
                // `snap:NAME`: the picture as it is now, beside --output.
                let output = arguments.option("output") ?? "snap"
                for display in session.layout.displays {
                    // The display's hub hands a new subscriber its latest picture, also for a
                    // display a layout brought since the start (curtain mode, a new user session).
                    let mailbox = session.frames(for: display.id)
                    let timer = Task { try? await Task.sleep(for: .seconds(2)); mailbox.finish() }
                    let frame = await mailbox.next()
                    timer.cancel()
                    guard let frame else { continue }
                    let path = "\(output)-\(name)-\(display.id.rawValue).png"
                    try? writePNG(pixels: packedPixels(frame), size: frame.pixelSize, to: URL(fileURLWithPath: path))
                    let surface = frame.surface.withUnsafeBuffer { (CVPixelBufferGetWidth($0), CVPixelBufferGetHeight($0)) }
                    log("snapshot \(path): declared \(frame.pixelSize.width) × \(frame.pixelSize.height), surface \(surface.0) × \(surface.1)")
                }
            }
        }
    }
    if let resize = arguments.option("resize"), let configuration = capabilities.displayConfiguration.value {
        let parts = resize.split(separator: "x").compactMap { Int($0) }
        if parts.count == 2 {
            try await Task.sleep(for: .seconds(1))
            log("resizing to \(parts[0]) × \(parts[1]) pt")
            let before = ContinuousClock.now
            try await configuration.setVirtualDisplays(Array(repeating: VirtualDisplayRequest(pointSize: PixelSize(width: parts[0], height: parts[1]), scale: scale), count: displayCount))
            log("resize agreed after \(ContinuousClock.now - before)")
            for display in session.layout.displays where counts.withLock({ $0.frames[display.id] == nil }) { watch(display.id) }
        }
    }

    try await Task.sleep(for: .seconds(seconds))
    let result = counts.withLock { $0 }
    let layout = session.layout
    await session.disconnect()
    await tunnel?.close()
    for task in tasks { task.cancel() }

    print("")
    for display in layout.displays {
        let frames = result.frames[display.id] ?? 0
        print("\(display.id): \(frames) frames (\(String(format: "%.1f", Double(frames) / seconds))/s), \(display.pixelSize.width) × \(display.pixelSize.height), \(display.state)")
        if let output = arguments.option("output"), let frame = result.last[display.id] {
            let pixels = packedPixels(frame)
            let path = "\(output)-\(display.id.rawValue).png"
            try writePNG(pixels: pixels, size: frame.pixelSize, to: URL(fileURLWithPath: path))
            print("  wrote \(path)")
        }
    }
    print("cursor: \(result.cursorUpdates) updates, shape \(result.cursorShape.map { "\($0.width) × \($0.height)" } ?? "none")")
    print("audio: \(result.audioChunks) chunks (\(String(format: "%.2f", Double(result.audioChunks) / 100)) s), \(result.audibleChunks) audible, peak \(String(format: "%.3f", result.audioPeak))")
    print("final state: \(session.state)")
    guard layout.displays.allSatisfy({ (result.frames[$0.id] ?? 0) > 0 }) else { throw Failure("a display produced no frames") }
}

/// A frame's pixels, rows packed without padding.
func packedPixels(_ frame: DisplayFrame) -> Data {
    frame.surface.withUnsafeBuffer { buffer in
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var packed = Data(capacity: frame.pixelSize.width * frame.pixelSize.height * 4)
        for row in 0..<frame.pixelSize.height {
            packed.append(Data(bytes: CVPixelBufferGetBaseAddress(buffer)! + row * stride, count: frame.pixelSize.width * 4))
        }
        return packed
    }
}

/// Plays a small input script: steps separated by `;`.
///
///     key:cmd+space        press a key with modifiers, as a hardware keyboard would report it
///     text:hello world     committed text, as a software keyboard would send it
///     wait:1500            pause, in milliseconds
///     show:all  show:ID    Standard mode: show all of the Mac's displays, or the one with that id
///     snap:NAME            save the picture as it is now (session --output decides where)
///     click:400,300        primary click at a position in the first display's pixels
///     touch:400,300+500,300   the fingers now on the first display's touch screen, in its pixels, each
///                          in the place of the one listed there before; touch: lifts them all
///     resize:1280x800@2    start resizing the virtual displays (points, scale) and go on meanwhile
///     move:400,300         move the pointer there
///     magnify:0.8          pinch, as the app sends it (also rotate:90, smartzoom:, lookup:, swipe:left,
///                          scroll:0/-600 for a two-finger scroll with phases and momentum)
///     raw-magnify:0.8/12/4/8   protocol experiment: total/steps/mask/series type (0 = no begin/end)
///     raw-rotate:90/12/4/5     the same for rotation
///     raw-smartzoom: raw-lookup:   the one-shot gestures
///     raw-scroll:dx/dy/steps/flags/momentum/mayBegin  scroll-wheel messages with phases
///     raw-gscroll:dx/dy/steps/mask           HID gesture scroll messages with phases
///     raw-swipe:finalMotion/mask/progress/flags/flavor/steps/velocity  page swipe experiment
///     down:400,300 up:400,300   press or release the primary button there; glide:x,y/steps/ms moves in between
///     raw-dragin:a.txt|b.txt/TOKEN   announce a drag of files entering the picture (raw-dragend: ends it,
///                          raw-dragask:TOKEN asks what the Mac's drag carries, raw-pbfiles: puts the files
///                          on the pasteboard instead, raw-bytes:HEX sends any message)
///     filedrag:a.txt|b.txt  a drag of files enters at the pointer (filedrag-move:x,y/steps/ms moves it,
///                          filedrag-drop:LOCALFILE lets go and sends that file where the Mac says,
///                          filedrag-cancel: abandons it); take-drag:LOCALFOLDER takes the Mac's own drag
///     fetch:/remote>local  put:local>remote/folder   a file transfer through the session
///     curtain:on/NOTE      curtain mode on with a note, through the session's capability (curtain:off lowers it)
///     raw-curtain:on/NOTE  the same message whether or not the Mac offers curtain mode (protocol experiment)
func runInputScript(_ script: String, on session: any RemoteSession, log: @escaping @Sendable (String) -> Void, snapshot: (String) async -> Void = { _ in }) async throws {
    let keys: [String: KeyCode] = [
        "space": .space, "return": .returnOrEnter, "escape": .escape, "tab": .tab, "delete": .deleteBackward,
        "left": .leftArrow, "right": .rightArrow, "up": .upArrow, "down": .downArrow,
        "a": .a, "c": .c, "k": .k, "n": .n, "q": .q, "t": .t, "v": .v, "w": .w, "z": .z, "0": .digit0, "[": .openBracket, "]": .closeBracket,
    ]
    let modifierKeys: [(name: String, key: KeyCode, flag: KeyModifiers)] = [
        ("cmd", .leftCommand, .leftCommand), ("ctrl", .leftControl, .leftControl),
        ("opt", .leftOption, .leftOption), ("shift", .leftShift, .leftShift),
    ]
    var fingers: [PixelPoint] = []
    for step in script.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !step.isEmpty {
        guard let colon = step.firstIndex(of: ":") else { throw Failure("script step “\(step)” has no colon") }
        let verb = step[..<colon]
        let argument = String(step[step.index(after: colon)...])
        switch verb {
        case "suspend":
            // As when the app goes to the background and returns: pictures start over from a keyframe.
            await session.suspend()
            try await Task.sleep(for: .milliseconds(Int(argument) ?? 500))
            await session.resume()
        case "wait":
            try await Task.sleep(for: .milliseconds(Int(argument) ?? 500))
        case "show":
            guard let configuration = session.capabilities.displayConfiguration.value else { throw Failure("no display configuration in this session") }
            let selection: PhysicalDisplaySelection
            if argument == "all" {
                selection = .all
            } else if let id = UInt32(argument) {
                selection = .single(DisplayID(id))
            } else {
                throw Failure("show: takes all or a display id, not “\(argument)”")
            }
            let started = ContinuousClock.now
            try await configuration.selectPhysicalDisplays(selection)
            log("showing \(argument) after \(ContinuousClock.now - started): " + session.layout.displays.map { "\($0.id) \($0.pixelSize.width)×\($0.pixelSize.height) at \($0.frameInDesktop)" }.joined(separator: ", "))
        case "snap":
            await snapshot(argument)
        case "text":
            session.input.send(.text(argument))
        case "key":
            let parts = argument.lowercased().split(separator: "+").map(String.init)
            guard let name = parts.last, let key = keys[name] else { throw Failure("unknown key in “\(step)”") }
            let held = modifierKeys.filter { parts.dropLast().contains($0.name) }
            var modifiers: KeyModifiers = []
            for modifier in held {
                session.input.send(.key(KeyEvent(key: modifier.key, modifiers: modifiers, phase: .down)))
                modifiers.insert(modifier.flag)
            }
            let character = name.count == 1 ? name : nil
            session.input.send(.key(KeyEvent(key: key, characters: character, charactersIgnoringModifiers: character, modifiers: modifiers, phase: .down)))
            try await Task.sleep(for: .milliseconds(40))
            session.input.send(.key(KeyEvent(key: key, characters: character, charactersIgnoringModifiers: character, modifiers: modifiers, phase: .up)))
            for modifier in held.reversed() {
                modifiers.remove(modifier.flag)
                session.input.send(.key(KeyEvent(key: modifier.key, modifiers: modifiers, phase: .up)))
            }
        case "resize":
            // resize:WxH[@S][*N]: N displays of that size (default: as many as there are now).
            let halves = argument.split(separator: "*", maxSplits: 1)
            let parts = halves[0].split(whereSeparator: { "x@".contains($0) }).compactMap { Int($0) }
            guard parts.count >= 2, let configuration = session.capabilities.displayConfiguration.value else { throw Failure("bad resize in “\(step)”") }
            let request = VirtualDisplayRequest(pointSize: PixelSize(width: parts[0], height: parts[1]), scale: parts.count > 2 ? parts[2] : 2)
            let count = halves.count > 1 ? (Int(halves[1]) ?? 1) : session.layout.displays.count
            Task {
                do {
                    try await configuration.setVirtualDisplays(Array(repeating: request, count: count))
                    log("script: resize to \(argument) agreed")
                } catch {
                    log("script: resize to \(argument) failed: \(error)")
                }
            }
        case "move":
            let parts = argument.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2, let display = session.layout.displays.first else { throw Failure("bad move in “\(step)”") }
            session.input.send(.pointer(PointerEvent(display: display.id, position: PixelPoint(x: parts[0], y: parts[1]), layoutGeneration: session.layout.generation)))
            scriptPointer.withLock { $0 = PixelPoint(x: parts[0], y: parts[1]) }
        case "magnify", "rotate", "smartzoom", "lookup", "swipe", "scroll":
            try await sendGestureStep(String(verb), argument, on: session)
        case "curtain":
            // Through the capability, as the app does: on/NOTE or off.
            let parts = argument.split(separator: "/", maxSplits: 1).map(String.init)
            switch session.capabilities.curtain {
            case .available(let curtain):
                try await curtain.setCurtained(parts.first == "on", note: parts.count > 1 ? parts[1] : "")
            case .unavailable(let reason):
                log("script: curtain mode is unavailable: \(reason)")
            }
        case "down", "up":
            let parts = argument.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2, let display = session.layout.displays.first else { throw Failure("bad position in “\(step)”") }
            let point = PixelPoint(x: parts[0], y: parts[1])
            session.input.send(.pointer(PointerEvent(display: display.id, position: point, buttons: verb == "down" ? .primary : [], layoutGeneration: session.layout.generation)))
            scriptPointer.withLock { $0 = point }
            scriptButtons.withLock { $0 = verb == "down" ? .primary : [] }
        case "glide":
            // Move to x,y in steps (default 20) over a time (default 600 ms), buttons as they are.
            let fields = argument.split(separator: "/").map(String.init)
            let parts = (fields.first ?? "").split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2, let display = session.layout.displays.first else { throw Failure("bad position in “\(step)”") }
            let steps = fields.count > 1 ? Int(fields[1]) ?? 20 : 20
            let total = fields.count > 2 ? Int(fields[2]) ?? 600 : 600
            let from = scriptPointer.withLock { $0 } ?? PixelPoint(x: parts[0], y: parts[1])
            let buttons = scriptButtons.withLock { $0 }
            for index in 1...max(1, steps) {
                let t = Double(index) / Double(max(1, steps))
                let point = PixelPoint(x: from.x + (parts[0] - from.x) * t, y: from.y + (parts[1] - from.y) * t)
                session.input.send(.pointer(PointerEvent(display: display.id, position: point, buttons: buttons, layoutGeneration: session.layout.generation)))
                try await Task.sleep(for: .milliseconds(total / max(1, steps)))
            }
            scriptPointer.withLock { $0 = PixelPoint(x: parts[0], y: parts[1]) }
        case "filedrag":
            guard let drags = session.capabilities.fileDrag.value, let display = session.layout.displays.first else {
                throw Failure("no file drags in this session: \(session.capabilities.fileDrag.unavailableReason.map { "\($0)" } ?? "no display")")
            }
            let position = scriptPointer.withLock { $0 } ?? PixelPoint(x: 100, y: 100)
            let drag = try drags.beginDrag(names: argument.split(separator: "|").map(String.init), at: position, on: display.id)
            scriptDrag.withLock { $0 = drag }
        case "filedrag-move":
            let fields = argument.split(separator: "/").map(String.init)
            let parts = (fields.first ?? "").split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2, let display = session.layout.displays.first, let drag = scriptDrag.withLock({ $0 }) else { throw Failure("bad move in “\(step)”") }
            let steps = fields.count > 1 ? Int(fields[1]) ?? 20 : 20
            let total = fields.count > 2 ? Int(fields[2]) ?? 600 : 600
            let from = scriptPointer.withLock { $0 } ?? PixelPoint(x: parts[0], y: parts[1])
            for index in 1...max(1, steps) {
                let t = Double(index) / Double(max(1, steps))
                drag.move(to: PixelPoint(x: from.x + (parts[0] - from.x) * t, y: from.y + (parts[1] - from.y) * t), on: display.id)
                try await Task.sleep(for: .milliseconds(total / max(1, steps)))
            }
            scriptPointer.withLock { $0 = PixelPoint(x: parts[0], y: parts[1]) }
        case "filedrag-drop":
            // Lets go; with a local file named, sends it to the folder the Mac names.
            guard let drag = scriptDrag.withLock({ $0 }) else { throw Failure("no drag to drop") }
            scriptDrag.withLock { $0 = nil }
            do {
                let folder = try await drag.drop()
                log("script: dropped into \(folder)")
                if !argument.isEmpty, let transfer = session.capabilities.fileTransfer.value {
                    for try await _ in transfer.upload(from: URL(fileURLWithPath: argument), toDirectory: folder) {}
                    log("script: sent \(argument) to \(folder)")
                }
            } catch {
                log("script: drop failed: \(error)")
            }
        case "filedrag-cancel":
            scriptDrag.withLock { $0 }?.cancel()
            scriptDrag.withLock { $0 = nil }
        case "take-drag":
            guard let drags = session.capabilities.fileDrag.value else { throw Failure("no file drags in this session") }
            let paths = scriptRemoteDrag.withLock { $0 }?.paths ?? []
            drags.takeRemoteDrag()
            log("script: took the Mac's drag of \(paths)")
            if !argument.isEmpty, let transfer = session.capabilities.fileTransfer.value {
                for path in paths {
                    let local = URL(fileURLWithPath: argument).appendingPathComponent((path as NSString).lastPathComponent)
                    do {
                        for try await _ in transfer.download(path, to: local) {}
                        log("script: fetched \(path) to \(local.path)")
                    } catch {
                        log("script: fetching \(path) failed: \(error)")
                    }
                }
            }
        case "raw-dragin", "raw-pbfiles":
            // A drag of files named NAME|NAME entering the picture (or the same archive as the
            // Mac's pasteboard), under a token: NAME|NAME/TOKEN.
            guard let session = session as? ARDSession else { throw Failure("\(verb) needs an Apple Screen Sharing session") }
            let fields = argument.split(separator: "/").map(String.init)
            let urls = (fields.first ?? "").split(separator: "|").map { URL(fileURLWithPath: $0.hasPrefix("/") ? String($0) : "/private/tmp/marionette-drag/\($0)") }
            let token = fields.count > 1 ? UInt32(fields[1]) ?? 0x4d41_5249 : 0x4d41_5249
            var message = DragPasteboard.files(urls, token: token).encoded()
            if verb == "raw-pbfiles" { message[message.startIndex] = ClientMessageType.pasteboardData }
            session.sendRawInput { _, _ in [message] }
        case "raw-dragend":
            guard let session = session as? ARDSession else { throw Failure("raw-dragend needs an Apple Screen Sharing session") }
            session.sendRawInput { _, _ in [DragPasteboard.end.encoded()] }
        case "raw-dragask":
            // Message 0x0e: what does the drag held on the Mac carry?
            guard let session = session as? ARDSession else { throw Failure("raw-dragask needs an Apple Screen Sharing session") }
            let token = UInt32(argument) ?? 0x4d41_5250
            var message = Data([ClientMessageType.dragRequest, 0, 0, 0])
            withUnsafeBytes(of: token.bigEndian) { message.append(contentsOf: $0) }
            session.sendRawInput { _, _ in [message] }
        case "raw-bytes":
            guard let session = session as? ARDSession else { throw Failure("raw-bytes needs an Apple Screen Sharing session") }
            let digits = argument.filter(\.isHexDigit)
            var message = Data()
            var index = digits.startIndex
            while index < digits.endIndex {
                let next = digits.index(index, offsetBy: 2, limitedBy: digits.endIndex) ?? digits.endIndex
                message.append(UInt8(digits[index..<next], radix: 16) ?? 0)
                index = next
            }
            session.sendRawInput { _, _ in [message] }
        case "fetch", "put":
            guard let transfer = session.capabilities.fileTransfer.value else { throw Failure("no file transfer in this session") }
            let sides = argument.split(separator: ">", maxSplits: 1).map(String.init)
            guard sides.count == 2 else { throw Failure("bad transfer in “\(step)”") }
            let stream = verb == "fetch"
                ? transfer.download(sides[0], to: URL(fileURLWithPath: sides[1]))
                : transfer.upload(from: URL(fileURLWithPath: sides[0]), toDirectory: sides[1])
            do {
                var last: TransferProgress?
                for try await progress in stream { last = progress }
                log("script: \(verb) finished, \(last?.bytesTransferred ?? 0) bytes")
            } catch {
                log("script: \(verb) failed: \(error)")
            }
        case "raw-curtain":
            // Message 12 as it is, whatever the session's capability says: on/NOTE or off.
            guard let session = session as? ARDSession else { throw Failure("raw-curtain needs an Apple Screen Sharing session") }
            let parts = argument.split(separator: "/", maxSplits: 1).map(String.init)
            let message = Curtain.message(curtained: parts.first == "on", note: parts.count > 1 ? parts[1] : "")
            session.sendRawInput { _, _ in [message] }
        case let raw where raw.hasPrefix("raw-"):
            try await sendRawGestureStep(String(verb.dropFirst(4)), argument, on: session, log: log)
        case "click":
            let parts = argument.split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2, let display = session.layout.displays.first else { throw Failure("bad click in “\(step)”") }
            let point = PixelPoint(x: parts[0], y: parts[1])
            let generation = session.layout.generation
            session.input.send(.pointer(PointerEvent(display: display.id, position: point, layoutGeneration: generation)))
            try await Task.sleep(for: .milliseconds(60))
            session.input.send(.pointer(PointerEvent(display: display.id, position: point, buttons: .primary, layoutGeneration: generation)))
            try await Task.sleep(for: .milliseconds(60))
            session.input.send(.pointer(PointerEvent(display: display.id, position: point, layoutGeneration: generation)))
        case "touch":
            guard session.capabilities.touch.isAvailable else {
                throw Failure("touch: needs a session that takes touches: \(String(describing: session.capabilities.touch.unavailableReason))")
            }
            let points = try argument.split(separator: "+").map { finger in
                let parts = finger.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { throw Failure("bad finger in “\(step)”") }
                return PixelPoint(x: parts[0], y: parts[1])
            }
            guard let display = session.layout.displays.first else { throw Failure("no display to touch") }
            let contacts = (0..<max(points.count, fingers.count)).map { id in
                id < points.count
                    ? TouchEvent.Contact(id: id, position: points[id])
                    : TouchEvent.Contact(id: id, position: fingers[id], phase: .lifted)
            }
            fingers = points
            session.input.send(.touch(TouchEvent(display: display.id, contacts: contacts, layoutGeneration: session.layout.generation)))
        default:
            throw Failure("unknown script verb in “\(step)”")
        }
        log("script: \(step)")
        try await Task.sleep(for: .milliseconds(120))
    }
}

/// Curtain mode as the session offers it.
func describe(_ curtain: Capability<any CurtainControl>) -> String {
    switch curtain {
    case .available(let control): control.isCurtained ? "up" : "available"
    case .unavailable(let reason): "unavailable (\(reason))"
    }
}

func describe(_ touch: Capability<TouchInput>) -> String {
    switch touch {
    case .available(let input): "up to \(input.maximumContacts) fingers"
    case .unavailable(let reason): "unavailable (\(reason))"
    }
}

/// Where the script last put the pointer.
let scriptPointer = Mutex<PixelPoint?>(nil)
/// The buttons the script holds down.
let scriptButtons = Mutex<PointerButtons>([])
/// The script's drag of files over the Mac, and the Mac's own drag as last announced.
let scriptDrag = Mutex<(any OutgoingFileDrag)?>(nil)
let scriptRemoteDrag = Mutex<RemoteFileDrag?>(nil)

/// A gesture through the session's input sink, as the app sends it.
func sendGestureStep(_ verb: String, _ argument: String, on session: any RemoteSession) async throws {
    guard let display = session.layout.displays.first else { throw Failure("no display") }
    let generation = session.layout.generation
    // The gesture happens where the pointer is; scripts move it first.
    let position = scriptPointer.withLock { $0 } ?? PixelPoint(x: Double(display.pixelSize.width) / 2, y: Double(display.pixelSize.height) / 2)
    func gesture(_ kind: GestureEvent.Kind, _ phase: ScrollEvent.Phase = .none) {
        session.input.send(.gesture(GestureEvent(kind: kind, phase: phase, display: display.id, position: position, layoutGeneration: generation)))
    }
    let steps = 12
    switch verb {
    case "magnify", "rotate":
        let total = Double(argument) ?? 0.5
        for step in 0...steps + 1 {
            let phase: ScrollEvent.Phase = step == 0 ? .began : step == steps + 1 ? .ended : .changed
            let amount = phase == .changed ? total / Double(steps) : 0
            gesture(verb == "magnify" ? .magnify(amount) : .rotate(amount), phase)
            try await Task.sleep(for: .milliseconds(16))
        }
    case "smartzoom":
        gesture(.smartMagnify)
    case "lookup":
        gesture(.quickLook)
    case "swipe":
        let directions: [String: (Double, Double)] = ["left": (-1, 0), "right": (1, 0), "up": (0, -1), "down": (0, 1)]
        guard let (dx, dy) = directions[argument] else { throw Failure("swipe:left|right|up|down") }
        gesture(.swipe(dx: dx, dy: dy))
    case "scroll":
        let parts = argument.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2 else { throw Failure("scroll:dx/dy") }
        func scroll(_ dx: Double, _ dy: Double, _ phase: ScrollEvent.Phase, momentum: ScrollEvent.Phase = .none) {
            session.input.send(.scroll(ScrollEvent(
                display: display.id, position: position, deltaX: dx, deltaY: dy, isPrecise: true,
                phase: phase, momentumPhase: momentum, layoutGeneration: generation
            )))
        }
        scroll(0, 0, .began)
        for _ in 0..<steps {
            scroll(parts[0] / Double(steps), parts[1] / Double(steps), .changed)
            try await Task.sleep(for: .milliseconds(16))
        }
        scroll(0, 0, .ended)
        var velocity = (parts[0] / Double(steps), parts[1] / Double(steps))
        scroll(velocity.0, velocity.1, .none, momentum: .began)
        for _ in 0..<20 {
            velocity = (velocity.0 * 0.85, velocity.1 * 0.85)
            scroll(velocity.0, velocity.1, .none, momentum: .changed)
            try await Task.sleep(for: .milliseconds(16))
        }
        scroll(0, 0, .none, momentum: .ended)
    default:
        throw Failure("unknown gesture \(verb)")
    }
}

/// Raw gesture messages, for finding out what the Mac does with each field.
func sendRawGestureStep(_ verb: String, _ argument: String, on session: any RemoteSession, log: @Sendable (String) -> Void) async throws {
    guard let session = session as? ARDSession else { throw Failure("raw gestures need an Apple Screen Sharing session") }
    let values = argument.split(separator: "/").map { Double($0) ?? 0 }
    func value(_ index: Int, _ fallback: Double) -> Double { index < values.count ? values[index] : fallback }
    func send(_ build: @escaping (UInt16, UInt16) -> [Data]) { session.sendRawInput(build) }
    switch verb {
    case "magnify", "rotate":
        let total = value(0, verb == "magnify" ? 0.8 : 90)
        let steps = max(1, Int(value(1, 12)))
        let mask = UInt64(value(2, 4))
        let series = UInt32(value(3, 0))
        if series != 0 { send { [ClientMessage.gestureBegin(seriesType: series, x: $0, y: $1)] } }
        for step in 0...steps + 1 {
            let phase: GesturePhase = step == 0 ? .began : step == steps + 1 ? .ended : .changed
            let amount = phase == .changed ? total / Double(steps) : 0
            send { x, y in
                [verb == "magnify"
                    ? ClientMessage.gestureMagnify(amount, phase: phase.rawValue, mask: mask, x: x, y: y)
                    : ClientMessage.gestureRotate(degrees: amount, phase: phase.rawValue, mask: mask, x: x, y: y)]
            }
            try await Task.sleep(for: .milliseconds(16))
        }
        if series != 0 { send { [ClientMessage.gestureEnd(seriesType: series, x: $0, y: $1)] } }
    case "smartzoom":
        send { [ClientMessage.gestureSmartMagnify(x: $0, y: $1)] }
    case "lookup":
        send { [ClientMessage.gestureLookUp(x: $0, y: $1)] }
    case "scroll":
        let (dx, dy) = (value(0, 0), value(1, -600))
        let steps = max(1, Int(value(2, 12)))
        let flags = ScrollFlags(rawValue: UInt32(value(3, 2)))
        let momentum = value(4, 1) != 0
        let mayBegin = value(5, 1) != 0
        func wheel(_ x: Double, _ y: Double, _ phase: ScrollPhase, _ momentumPhase: MomentumPhase = .none) {
            send { px, py in [ClientMessage.scroll(deltaX: Int32(x), deltaY: Int32(y), x: px, y: py, phase: phase.rawValue, momentumPhase: momentumPhase.rawValue, flags: flags)] }
        }
        if mayBegin { wheel(0, 0, .mayBegin) }
        wheel(dx / Double(steps), dy / Double(steps), .began)
        for _ in 1..<steps {
            wheel(dx / Double(steps), dy / Double(steps), .changed)
            try await Task.sleep(for: .milliseconds(16))
        }
        wheel(0, 0, .ended)
        if momentum {
            var velocity = (dx / Double(steps), dy / Double(steps))
            wheel(velocity.0, velocity.1, .none, .begin)
            for _ in 0..<20 {
                velocity = (velocity.0 * 0.85, velocity.1 * 0.85)
                wheel(velocity.0, velocity.1, .none, .continue)
                try await Task.sleep(for: .milliseconds(16))
            }
            wheel(0, 0, .none, .end)
        }
    case "gscroll":
        let (dx, dy) = (Float(value(0, 0)), Float(value(1, -600)))
        let steps = max(1, Int(value(2, 12)))
        let mask = UInt32(value(3, 0))
        for step in 0...steps + 1 {
            let phase: GesturePhase = step == 0 ? .began : step == steps + 1 ? .ended : .changed
            let (x, y) = phase == .changed ? (dx / Float(steps), dy / Float(steps)) : (0, 0)
            send { px, py in [ClientMessage.gestureScroll(deltaX: x, deltaY: y, naturalScrolling: true, phase: UInt32(phase.rawValue), mask: mask, x: px, y: py)] }
            try await Task.sleep(for: .milliseconds(16))
        }
    case "swipe":
        // The Mac derives the phase from motion: 2 is under way (began at progress 0, changed
        // after), anything else is over (ended with progress, cancelled without).
        let finalMotion = UInt32(value(0, 1))
        let mask = UInt32(value(1, 8))
        let progress = Float(value(2, 1))
        let flags = UInt32(value(3, 0))
        let flavor = UInt32(value(4, 0))
        let steps = max(1, Int(value(5, 8)))
        let velocity = Float(value(6, 0))
        func swipe(_ motion: UInt32, _ fraction: Float) {
            send { [ClientMessage.gesturePageSwipe(PageSwipe(motion: motion, swipeMask: mask, progress: fraction, velocityX: velocity, flags: flags, flavor: flavor), x: $0, y: $1)] }
        }
        swipe(2, 0)
        for step in 1...steps {
            swipe(2, progress * Float(step) / Float(steps))
            try await Task.sleep(for: .milliseconds(16))
        }
        swipe(finalMotion, progress)
    default:
        throw Failure("unknown raw gesture \(verb)")
    }
    log("raw \(verb) \(argument)")
}

/// 32-bit float PCM as a WAV file.
func wav(_ samples: Data, rate: Double, channels: Int) -> Data {
    var header = Data()
    func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
    func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) } }
    header.append(Data("RIFF".utf8)); u32(UInt32(36 + samples.count)); header.append(Data("WAVEfmt ".utf8))
    u32(16); u16(3); u16(UInt16(channels)); u32(UInt32(rate)); u32(UInt32(rate) * UInt32(channels) * 4); u16(UInt16(channels * 4)); u16(32)
    header.append(Data("data".utf8)); u32(UInt32(samples.count))
    return header + samples
}
