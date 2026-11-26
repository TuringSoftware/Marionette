// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import AppleScreenSharing
import ARDProtocol
import CoreVideo
import Foundation
import RemoteDesktopCore
import RemoteDesktopDecode
import RemoteDesktopTransport
import Synchronization

/// What the media stream delivered, gathered from its callback.
final class StreamRecorder: Sendable {
    struct State {
        var video = Data()
        var pictures = 0
        var keyframes = 0
        var losses = 0
        var audioFrames = 0
        var audioBytes = 0
        var firstPicture: ContinuousClock.Instant?
        var pictureBytes = 0
        var failure: TransportError?
        var firstAudioPayload: Data?
    }

    let state = Mutex(State())

    /// Decoded results, filled by the decoders' callbacks.
    struct Decoded {
        var pictures = 0
        var failures = 0
        var last: DecodedPicture?
        var audioSamples = 0
        var audioPeak: Float = 0
        var audioFailures = 0
    }

    let decoded = Mutex(Decoded())
    // Each decoder is used from one media leg's receive queue only.
    nonisolated(unsafe) var videoDecoder: VideoDecoder?
    nonisolated(unsafe) var audioDecoder: AACELDDecoder?

    func enableDecoding() throws {
        videoDecoder = VideoDecoder { [unowned self] result in
            self.decoded.withLock { state in
                switch result {
                case .success(let picture):
                    state.pictures += 1
                    state.last = picture
                case .failure:
                    state.failures += 1
                }
            }
        }
        audioDecoder = try AACELDDecoder()
    }

    func decode(_ event: MediaStreamEvent) {
        switch event {
        case .picture(_, let unit, _):
            do {
                try videoDecoder?.decode(EncodedPicture(codec: .hevc, nalUnits: unit.nalUnits, isKeyframe: unit.isKeyframe, timestamp: unit.timestamp))
            } catch VideoDecoderError.needsKeyframe {
                // Pictures before the first keyframe are not decodable; nothing to count.
            } catch {
                decoded.withLock { $0.failures += 1 }
            }
        case .audio(let payload, _, _):
            guard let audioDecoder else { return }
            do {
                let samples = try audioDecoder.decode(payload)
                let peak = samples.withUnsafeBytes { $0.bindMemory(to: Float32.self).reduce(Float(0)) { max($0, abs($1)) } }
                decoded.withLock { state in
                    state.audioSamples += samples.count / 8
                    state.audioPeak = max(state.audioPeak, peak)
                }
            } catch {
                decoded.withLock { $0.audioFailures += 1 }
            }
        default:
            break
        }
    }

    nonisolated(unsafe) var traces = false
    private let started = ContinuousClock.now

    private func trace(_ text: String) {
        guard traces else { return }
        let elapsed = ContinuousClock.now - started
        print(String(format: "%6.2fs  %@", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, text))
    }

    func handle(_ event: MediaStreamEvent) {
        decode(event)
        switch event {
        case .picture(_, let unit, _):
            trace("picture: \(unit.annexB.count) bytes\(unit.isKeyframe ? ", keyframe" : "")\(unit.isRefresh ? ", refresh" : "")")
        case .pictureLoss: trace("packets lost; asked the Mac to restart")
        default: break
        }
        state.withLock { state in
            switch event {
            case .picture(_, let unit, let arrival):
                // A decoder can only start at a keyframe, so the file starts at one.
                guard state.keyframes > 0 || unit.isKeyframe else { return }
                if state.firstPicture == nil { state.firstPicture = arrival }
                let bytes = unit.annexB
                state.video.append(bytes)
                state.pictureBytes += bytes.count
                state.pictures += 1
                if unit.isKeyframe { state.keyframes += 1 }
            case .audio(let payload, _, _):
                state.audioFrames += 1
                state.audioBytes += payload.count
                if state.firstAudioPayload == nil { state.firstAudioPayload = payload }
            case .pictureLoss:
                state.losses += 1
            case .failed(let error):
                state.failure = error
            }
        }
    }
}

func highPerformance(_ arguments: Arguments) async throws {
    guard let output = arguments.option("output") else { throw Failure("--output is required") }
    let sizeParts = (arguments.option("size") ?? "1440x900").split(separator: "x").compactMap { Int($0) }
    guard sizeParts.count == 2 else { throw Failure("--size must look like 1440x900") }
    let scale = Int(arguments.option("scale") ?? "2") ?? 2
    let seconds = Double(arguments.option("seconds") ?? "5") ?? 5
    let tiles = Int(arguments.option("tiles") ?? "1") ?? 1
    // --no-clamp asks for exactly the size given, past the limits measured on a VM, to find a
    // physical Mac's own.
    let wanted = arguments.flags.contains("no-clamp")
        ? VirtualDisplayMode(
            pixelWidth: UInt32(sizeParts[0] * scale), pixelHeight: UInt32(sizeParts[1] * scale),
            pointWidth: UInt32(sizeParts[0]), pointHeight: UInt32(sizeParts[1])
        )
        : VirtualDisplayMode.fitting(pointWidth: sizeParts[0], pointHeight: sizeParts[1], scale: scale)
    // --hdr on asks for an HDR display, and offers HDR pictures for it once the Mac marks its port HDR;
    // --offer-hdr offers them whatever the Mac says.
    var wantedDisplay = wanted
    wantedDisplay.isHDR = arguments.option("hdr") == "on"
    let offersHDRAlways = arguments.flags.contains("offer-hdr")

    var provider: any TransportProvider = DirectTransportProvider(peer: Endpoint(host: arguments.host, port: arguments.port))
    let loss = (Double(arguments.option("loss") ?? "0") ?? 0) / 100
    if loss > 0 {
        provider = ImpairedTransportProvider(provider, impairment: NetworkImpairment(
            inboundLoss: loss, outboundLoss: loss, seed: UInt64(arguments.option("seed") ?? "1") ?? 1
        ))
    }
    guard let user = arguments.option("user", environment: "MARIONETTE_TEST_USER"),
          let password = arguments.option("password", environment: "MARIONETTE_TEST_PASSWORD")
    else { throw Failure("a user name and password are required") }
    let connection = ARDConnection(stream: try await provider.openStream(port: arguments.port))
    let established = try await connection.handshake(username: user, password: password)
    guard established.serverInit.supportsHighPerformance else {
        throw Failure("\(established.serverInit.name) does not offer High Performance mode")
    }
    let started = ContinuousClock.now
    func log(_ message: String) {
        let elapsed = ContinuousClock.now - started
        let text = String(format: "%6.2fs  %@", Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, message)
        print(text)
    }

    func randomKey() -> MediaKey {
        var generator = SystemRandomNumberGenerator()
        return MediaKey(bytes: Data((0..<MediaKey.length).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }
    var offer = MediaOffer(
        sessionID: UUID(),
        flags: arguments.flags.contains("with-cursor") ? [.sixtyFramesPerSecond] : [.sixtyFramesPerSecond, .omitCursor],
        audioSSRC: .random(in: 1 ... .max),
        audioKeys: MediaLegKeys(viewerToServer: randomKey(), serverToViewer: randomKey()),
        videos: [
            MediaOffer.Video(
                ssrc: .random(in: 1 ... .max),
                keys: MediaLegKeys(viewerToServer: randomKey(), serverToViewer: randomKey()),
                width: 0, height: 0, codec: .hevc, tilesPerFrame: tiles
            ),
        ]
    )

    // Every virtual display is first created at one canonical mode without dynamic resolution; the
    // session's own size follows once the media stream has been agreed for it.
    connection.send(ClientMessage.setDisplayConfiguration([.opening], dynamic: false))
    connection.send(ClientMessage.setEncodings(Encoding.highPerformance))
    log("asked for a virtual display")

    let recorder = StreamRecorder()
    recorder.traces = arguments.flags.contains("trace")
    if arguments.flags.contains("decode") { try recorder.enableDecoding() }
    var receiver: MediaStreamReceiver?
    var layout: DisplayLayout?
    var portsAnnounced = false
    var offerOutstanding = false
    var sessionSizeSent = false
    var layoutIsCurrent = false
    var streamingSince: ContinuousClock.Instant?
    var ports: MediaStreamReceiver.Ports?

    func offerIfReady() async throws {
        guard portsAnnounced, layoutIsCurrent, !offerOutstanding, let layout, let ports else { return }
        guard layout.flags.contains(.onVirtualDisplay) else { return }
        offer.videos[0].width = UInt16(layout.framebufferWidth)
        offer.videos[0].height = UInt16(layout.framebufferHeight)
        if receiver == nil {
            // This tool decodes, if at all, apart from the stream: pictures are acknowledged whole.
            let created = try await MediaStreamReceiver(transport: provider, ports: ports, offer: offer, acknowledgesOnAssembly: true) { recorder.handle($0) }
            created.start()
            receiver = created
        }
        receiver?.setPictureSize(leg: 0, width: offer.videos[0].width, height: offer.videos[0].height)
        connection.send(offer.message())
        portsAnnounced = false
        offerOutstanding = true
        log("offered the stream for \(layout.framebufferWidth) × \(layout.framebufferHeight)\(offer.videos[0].offersHDR ? " with HDR modes" : "")")
    }

    events: while true {
        if let streamingSince, ContinuousClock.now - streamingSince >= .seconds(seconds) { break }
        if let failure = recorder.state.withLock({ $0.failure }) { throw Failure("media socket failed: \(failure)") }
        // The control connection is nearly silent while the stream runs, so do not wait on it forever.
        let event: ServerEvent? = try await withThrowingTaskGroup(of: ServerEvent??.self) { group in
            group.addTask { try await connection.nextEvent() }
            group.addTask {
                try await Task.sleep(for: .milliseconds(250))
                return .some(nil)
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        } ?? nil

        if streamingSince == nil, sessionSizeSent, recorder.state.withLock({ $0.pictures }) > 0 {
            streamingSince = .now
            log("first picture")
        }
        guard let event else { continue }
        guard case .rectangle(let rectangle) = event else {
            if case .status(let status) = event, status != .heartbeat { log("status \(status.rawValue)") }
            continue
        }
        switch rectangle.body {
        case .displayLayout(let newLayout):
            layout = newLayout
            layoutIsCurrent = true
            let screen = newLayout.screens[0]
            log("layout: \(newLayout.framebufferWidth) × \(newLayout.framebufferHeight) px, \(screen.pointWidth) × \(screen.pointHeight) pt at \(screen.density)x, flags 0x\(String(newLayout.flags.rawValue, radix: 16))")
            // A layout drops the Mac's arming. One pixel a second keeps cursor shapes and layouts
            // coming without the Mac ever sending the picture this way.
            await connection.setPixelFormat(.bgrx)
            connection.send(ClientMessage.autoFramebufferUpdate(interval: .seconds(1), width: 1, height: 1))
            connection.send(ClientMessage.autoPasteboard(true))
            try await offerIfReady()
        case .mediaStream(let body):
            switch try MediaReply.parse(body) {
            case .ports(let audio, let video, let second, let hdr):
                log("the Mac will send from ports \(audio) (sound) and \(video) (picture)\(second.map { ", \($0)" } ?? ""); HDR: \(hdr)")
                ports = MediaStreamReceiver.Ports(audio: audio, video: [video])
                offer.videos[0].offersHDR = offersHDRAlways || hdr.first == true
                portsAnnounced = true
                try await offerIfReady()
            case .answer(let legs):
                offerOutstanding = false
                log("the Mac answered the offer (\(legs) picture leg)")
                connection.send(ClientMessage.setEncodings(Encoding.highPerformance))
                if !sessionSizeSent {
                    // Now the session's own size, with dynamic resolution. The change stops the
                    // stream; it is offered again for the new display.
                    sessionSizeSent = true
                    layoutIsCurrent = false
                    connection.send(ClientMessage.setDisplayConfiguration([wantedDisplay], dynamic: true))
                    log("asked for \(wanted.pointWidth) × \(wanted.pointHeight) pt at \(wanted.pixelWidth / wanted.pointWidth)x\(wantedDisplay.isHDR ? ", HDR" : "")")
                }
            case .failure(let failure):
                throw Failure("the Mac refused the media stream: \(failure)")
            case .unknown(let type):
                log("unknown media-stream message \(type)")
            }
        case .cursorImage(let id, let deflated):
            log("cursor shape \(id): \(deflated.isEmpty ? "select" : "\(rectangle.header.width) × \(rectangle.header.height), \(deflated.count) bytes")")
        default:
            break
        }
    }

    let video = receiver?.videoStatistics(leg: 0) ?? MediaLegStatistics()
    let audio = receiver?.audioStatistics ?? MediaLegStatistics()
    receiver?.stop()
    await connection.close()

    let result = recorder.state.withLock { $0 }
    try result.video.write(to: URL(fileURLWithPath: output))
    print("")
    print("picture leg:  \(video.packets) packets, \(video.bytes) bytes, \(result.pictures) pictures (\(result.keyframes) keyframes), \(video.losses) losses, \(video.rejected) rejected, \(video.reportsFromServer) reports from the Mac")
    print(String(format: "              %.1f pictures/s, %.2f Mbit/s, one-way delay %.1f ms", Double(result.pictures) / seconds, Double(result.pictureBytes) * 8 / seconds / 1e6, video.oneWayDelay * 1000))
    print("sound leg:    \(audio.packets) packets, \(result.audioFrames) frames, \(result.audioBytes) bytes, \(audio.rejected) rejected, \(audio.reportsFromServer) reports from the Mac")
    if let first = result.firstAudioPayload {
        print("              first frame: \(first.count) bytes, starts \(first.prefix(8).map { String(format: "%02x", $0) }.joined())")
    }
    print("wrote \(output) (\(result.video.count) bytes)")
    if let decoder = recorder.videoDecoder {
        decoder.finishPending()
        let decoded = recorder.decoded.withLock { $0 }
        print("decoded:      \(decoded.pictures) pictures, \(decoded.failures) failures, \(decoder.isHardwareAccelerated == true ? "hardware" : "software") decoder")
        print(String(format: "              %d audio samples (%.2f s), peak %.4f, %d failures", decoded.audioSamples, Double(decoded.audioSamples) / 48_000, decoded.audioPeak, decoded.audioFailures))
        if let last = decoded.last {
            let (format, transfer) = last.surface.withUnsafeBuffer { buffer in
                (CVPixelBufferGetPixelFormatType(buffer), CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String)
            }
            let fourCC = String(bytes: withUnsafeBytes(of: format.bigEndian) { Array($0) }, encoding: .ascii) ?? "\(format)"
            print("              last picture: \(fourCC), transfer \(transfer ?? "untagged")")
            let size = PixelSize(width: last.width, height: last.height)
            let frame = DisplayFrame(display: DisplayID(1), surface: last.surface, pixelSize: size, damage: .full(size), layoutGeneration: 0)
            let png = output + ".png"
            try writePNG(frame: frame, to: URL(fileURLWithPath: png))
            print("wrote \(png) (last decoded picture, \(last.width) × \(last.height))")
        }
        guard decoded.pictures > 0, decoded.failures == 0 else { throw Failure("decoding failed") }
    }
    guard result.pictures > 0 else { throw Failure("no picture arrived") }
}
