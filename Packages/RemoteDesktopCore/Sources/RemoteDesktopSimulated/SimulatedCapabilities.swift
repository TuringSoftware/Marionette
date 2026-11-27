// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore

/// Errors the simulated machine reports, mirroring what real servers refuse.
public enum SimulationError: Error, Sendable, Hashable {
    case tooManyDisplays(maximum: Int)
    case displayTooSmall(minimum: PixelSize)
    case unknownDisplay
    case noSuchFile(String)
    case sessionEnded
}

extension SimulatedSessionCore {
    func makeCapabilities() -> SessionCapabilities {
        var capabilities = SessionCapabilities()
        let isHighPerformance = info.mode == .highPerformance

        if options.wantsClipboard {
            capabilities.clipboard = .available(SimulatedClipboard(core: self))
        } else {
            capabilities.clipboard = .unavailable(.notConfigured(detail: String(localized: "Clipboard sharing is switched off for this computer.", bundle: #bundle)))
        }

        capabilities.fileTransfer = .available(SimulatedFiles(core: self))
        if scenario.fileDrags == nil {
            capabilities.fileDrag = .unavailable(.notSupportedByServer)
        } else if options.controlMode == .observe {
            // A drag holds the pointer's button down, which a viewer that only watches may not.
            capabilities.fileDrag = .unavailable(.notPermitted)
        } else {
            capabilities.fileDrag = .available(SimulatedFileDrags(core: self))
        }

        if isHighPerformance, scenario.playsTone, options.wantsAudio {
            capabilities.audio = .available(SimulatedAudio(core: self))
        } else if info.isTunnelled {
            capabilities.audio = .unavailable(.tunnelled)
        } else if !isHighPerformance {
            capabilities.audio = .unavailable(.requiresMode(.highPerformance))
        } else {
            capabilities.audio = .unavailable(.notSupportedByServer)
        }

        capabilities.displayConfiguration = .available(SimulatedDisplayConfiguration(core: self))
        capabilities.quality = isHighPerformance
            ? .unavailable(.requiresMode(.standard))
            : .available(SimulatedQuality())
        capabilities.control = .available(SimulatedControl(core: self))
        capabilities.remoteActions = .available(SimulatedActions(core: self))
        capabilities.curtain = isHighPerformance
            ? .unavailable(.requiresMode(.standard))
            : .available(SimulatedCurtain(core: self, isCurtained: false))
        capabilities.statistics = .available(SimulatedStatistics(core: self))
        if scenario.touchContacts == 0 {
            capabilities.touch = .unavailable(.notSupportedByServer)
        } else if options.controlMode == .observe {
            capabilities.touch = .unavailable(.notPermitted)
        } else {
            capabilities.touch = .available(TouchInput(maximumContacts: scenario.touchContacts))
        }
        if !isHighPerformance {
            capabilities.highDynamicRange = .unavailable(.requiresMode(.highPerformance))
        } else {
            capabilities.highDynamicRange = scenario.makesHDRDisplays ? .available(()) : .unavailable(.notSupportedByServer)
        }
        return capabilities
    }
}

struct SimulatedClipboard: ClipboardSync {
    let core: SimulatedSessionCore

    func remoteOffers() -> AsyncStream<RemoteClipboardOffer> {
        core.clipboardOffers.subscribe()
    }

    func sendToRemote(_ items: [ClipboardItem]) async throws {
        guard !core.shared.withLock({ $0.state.isDisconnected }) else { throw SimulationError.sessionEnded }
        // Our own write must not come back as a remote change.
        core.setRemoteClipboard(items, announce: false)
        await core.engine.renderNow()
    }
}

struct SimulatedDisplayConfiguration: DisplayConfiguration {
    let core: SimulatedSessionCore

    var limits: DisplayConfigurationLimits {
        DisplayConfigurationLimits(
            maximumVirtualDisplays: core.info.mode == .highPerformance ? core.scenario.maximumVirtualDisplays : 0,
            minimumPointSize: core.scenario.minimumVirtualPointSize,
            maximumPixelSize: PixelSize(width: 3840, height: 2160),
            canSelectPhysicalDisplays: core.scenario.displays.count > 1
        )
    }

    func setVirtualDisplays(_ requests: [VirtualDisplayRequest]) async throws {
        core.shared.withLock { $0.requestedDisplays.append(requests) }
        let limits = limits
        guard requests.count <= limits.maximumVirtualDisplays, !requests.isEmpty else {
            throw SimulationError.tooManyDisplays(maximum: limits.maximumVirtualDisplays)
        }
        for request in requests {
            guard request.pointSize.width >= limits.minimumPointSize.width,
                  request.pointSize.height >= limits.minimumPointSize.height
            else { throw SimulationError.displayTooSmall(minimum: limits.minimumPointSize) }
        }
        let displays = requests.enumerated().map { index, request in
            SimulationScenario.Display(
                name: index == 0 ? String(localized: "Virtual Display", bundle: #bundle) : String(localized: "Virtual Display #\(index + 1)", bundle: #bundle),
                pixelSize: PixelSize(
                    width: min(request.pointSize.width * request.scale, limits.maximumPixelSize.width),
                    height: min(request.pointSize.height * request.scale, limits.maximumPixelSize.height)
                ),
                scale: Double(request.scale),
                isHDR: request.wantsHDR && core.scenario.makesHDRDisplays
            )
        }
        try await core.engine.reconfigure(displays: displays, kind: .virtual, delay: core.scenario.reconfigurationDelay)
    }

    func selectPhysicalDisplays(_ selection: PhysicalDisplaySelection) async throws {
        let all = core.scenario.displays
        let chosen: [SimulationScenario.Display]
        switch selection {
        case .all:
            chosen = all
        case .single(let id):
            let index = Int(id.rawValue) - 1
            guard all.indices.contains(index) else { throw SimulationError.unknownDisplay }
            chosen = [all[index]]
        }
        try await core.engine.reconfigure(displays: chosen, kind: .physical, delay: core.scenario.reconfigurationDelay)
    }
}

struct SimulatedQuality: QualityControl {
    var supportedPresets: [QualityPreset] { QualityPreset.allCases }
    func setPreset(_ preset: QualityPreset) async throws {}
}

struct SimulatedControl: SessionControl {
    let core: SimulatedSessionCore

    var supportedModes: [ControlMode] { ControlMode.allCases }

    func setControlMode(_ mode: ControlMode) async throws {
        core.shared.withLock { $0.controlMode = mode }
    }
}

struct SimulatedActions: RemoteActions {
    let core: SimulatedSessionCore

    var supportedActions: Set<RemoteAction> { Set(RemoteAction.allCases) }

    func perform(_ action: RemoteAction) async throws {
        core.shared.withLock { $0.performedActions.append(action) }
        core.events.send(.notice(.message("Simulated: \(action)")))
    }
}

/// Raises and lowers at once, and reports the change as a machine would: with new capabilities.
struct SimulatedCurtain: CurtainControl {
    let core: SimulatedSessionCore
    let isCurtained: Bool

    func setCurtained(_ curtained: Bool, note: String) async throws {
        let capabilities: SessionCapabilities = try core.shared.withLock { shared in
            guard !shared.state.isDisconnected else { throw SimulationError.sessionEnded }
            shared.capabilities.curtain = .available(SimulatedCurtain(core: core, isCurtained: curtained))
            return shared.capabilities
        }
        core.events.send(.capabilitiesChanged(capabilities))
    }
}

struct SimulatedStatistics: SessionStatisticsSource {
    let core: SimulatedSessionCore

    func statistics() -> AsyncStream<SessionStatistics> {
        let isHighPerformance = core.info.mode == .highPerformance
        let frameRate = Double(core.scenario.frameRate)
        return AsyncStream { continuation in
            let task = Task {
                var tick = 0.0
                while !Task.isCancelled {
                    // A slow, bounded wobble so the numbers look alive but stay deterministic.
                    let wobble = sin(tick / 3)
                    continuation.yield(
                        SessionStatistics(
                            framesPerSecond: frameRate,
                            bitrate: isHighPerformance ? 24_000_000 + wobble * 4_000_000 : 1_500_000 + wobble * 500_000,
                            packetLoss: isHighPerformance ? 0.001 : nil,
                            roundTripTime: .milliseconds(Int(4 + wobble * 2)),
                            decodeLatency: .milliseconds(isHighPerformance ? 6 : 2),
                            videoCodec: isHighPerformance ? "HEVC 4:4:4" : nil
                        )
                    )
                    tick += 1
                    do { try await Task.sleep(for: .seconds(1)) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

struct SimulatedAudio: AudioOutput {
    let core: SimulatedSessionCore

    /// A quiet 440 Hz tone in 10 ms chunks, paced in real time.
    func chunks() -> AsyncStream<AudioChunk> {
        let sampleRate = 48_000.0
        let framesPerChunk = 480
        return AsyncStream(bufferingPolicy: .bufferingNewest(50)) { continuation in
            let task = Task { [weak core] in
                let clock = ContinuousClock()
                var next = clock.now
                var phase = 0.0
                let step = 2 * Double.pi * 440 / sampleRate
                while !Task.isCancelled {
                    guard let core, !core.shared.withLock({ $0.state.isDisconnected }) else { break }
                    if !core.shared.withLock({ $0.isSuspended }) {
                        var samples = [Float32](repeating: 0, count: framesPerChunk * 2)
                        for frame in 0..<framesPerChunk {
                            let value = Float32(sin(phase) * 0.05)
                            samples[frame * 2] = value
                            samples[frame * 2 + 1] = value
                            phase += step
                        }
                        phase = phase.truncatingRemainder(dividingBy: 2 * Double.pi)
                        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
                        continuation.yield(AudioChunk(sampleRate: sampleRate, channelCount: 2, samples: data, presentationTime: next))
                    }
                    next += .milliseconds(10)
                    do { try await clock.sleep(until: next) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Drags of files, played the way a Mac plays them with its own viewer: a viewer's drag follows the
/// pointer and lands in the folder it is let go over, or nowhere; a drag of the machine's own files
/// is announced when it starts and when its button comes up.
struct SimulatedFileDrags: FileDragAndDrop {
    let core: SimulatedSessionCore

    func remoteDrags() -> AsyncStream<RemoteFileDrag?> {
        core.remoteDrags.subscribe()
    }

    func takeRemoteDrag() {
        core.takeOwnDrag()
    }

    func beginDrag(names: [String], at position: PixelPoint, on display: DisplayID) throws(FileDragError) -> any OutgoingFileDrag {
        Drag(core: core, id: try core.beginViewerDrag(names: names, at: position, on: display))
    }

    private struct Drag: OutgoingFileDrag {
        let core: SimulatedSessionCore
        let id: UInt64

        func move(to position: PixelPoint, on display: DisplayID) { core.moveViewerDrag(id, to: position, on: display) }
        func drop() async throws -> String { try await core.dropViewerDrag(id) }
        func cancel() { core.cancelViewerDrag(id) }
    }
}

/// An in-memory remote file system with throttled transfers.
final class SimulatedFiles: FileTransfer {
    let core: SimulatedSessionCore
    private let store: FileStore

    private actor FileStore {
        var files: [String: [UInt8]]

        init(_ files: [SimulationScenario.RemoteFile]) {
            self.files = Dictionary(files.map { ($0.path, $0.contents) }, uniquingKeysWith: { _, last in last })
        }

        func contents(_ path: String) -> [UInt8]? { files[path] }
        func write(_ path: String, _ contents: [UInt8]) { files[path] = contents }

        func entries(in directory: String) -> [RemoteFileEntry] {
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"
            var seen = Set<String>()
            var result: [RemoteFileEntry] = []
            for (path, contents) in files where path.hasPrefix(prefix) {
                let remainder = path.dropFirst(prefix.count)
                guard let first = remainder.split(separator: "/", maxSplits: 1).first else { continue }
                let name = String(first)
                guard seen.insert(name).inserted else { continue }
                let isDirectory = remainder.contains("/")
                result.append(
                    RemoteFileEntry(
                        path: prefix + name,
                        name: name,
                        isDirectory: isDirectory,
                        size: isDirectory ? nil : UInt64(contents.count)
                    )
                )
            }
            return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    init(core: SimulatedSessionCore) {
        self.core = core
        store = FileStore(core.scenario.files)
    }

    var canBrowse: Bool { core.scenario.fileTransferCanBrowse }

    func defaultUploadDirectory() async throws -> String { "/Users/demo/Downloads" }

    func list(directory: String) async throws -> [RemoteFileEntry] {
        await store.entries(in: directory)
    }

    func upload(from localFile: URL, toDirectory remoteDirectory: String) -> AsyncThrowingStream<TransferProgress, any Error> {
        let rate = core.scenario.transferRate
        let store = store
        return Self.stream { progress in
            let files = try Self.files(at: localFile)
            try await Self.pace(total: files.reduce(0) { $0 + $1.contents.count }, rate: rate, progress: progress)
            let directory = remoteDirectory.hasSuffix("/") ? String(remoteDirectory.dropLast()) : remoteDirectory
            for file in files {
                await store.write(directory + "/" + file.path, file.contents)
            }
        }
    }

    /// What an upload sends: the file, or every file under the folder, each by its path from where
    /// the item itself is.
    private static func files(at local: URL) throws -> [(path: String, contents: [UInt8])] {
        let root = local.standardizedFileURL
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            return [(root.lastPathComponent, try Array(Data(contentsOf: root)))]
        }
        let prefix = root.deletingLastPathComponent().path
        var files: [(path: String, contents: [UInt8])] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix + "/") else { continue }
            files.append((String(path.dropFirst(prefix.count + 1)), try Array(Data(contentsOf: url))))
        }
        return files.sorted { $0.path < $1.path }
    }

    func download(_ remotePath: String, to localFile: URL) -> AsyncThrowingStream<TransferProgress, any Error> {
        let rate = core.scenario.transferRate
        let store = store
        return Self.stream { progress in
            guard let bytes = await store.contents(remotePath) else { throw SimulationError.noSuchFile(remotePath) }
            try await Self.pace(total: bytes.count, rate: rate, progress: progress)
            try Data(bytes).write(to: localFile, options: .atomic)
        }
    }

    private static func stream(
        _ body: @escaping @Sendable (@escaping @Sendable (TransferProgress) -> Void) async throws -> Void
    ) -> AsyncThrowingStream<TransferProgress, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Reports progress in tenths of a second of simulated transfer time.
    private static func pace(total: Int, rate: Int, progress: @Sendable (TransferProgress) -> Void) async throws {
        let step = max(1, rate / 10)
        var sent = 0
        progress(TransferProgress(bytesTransferred: 0, totalBytes: UInt64(total)))
        while sent < total {
            try await Task.sleep(for: .milliseconds(100))
            sent = min(total, sent + step)
            progress(TransferProgress(bytesTransferred: UInt64(sent), totalBytes: UInt64(total)))
        }
    }
}
