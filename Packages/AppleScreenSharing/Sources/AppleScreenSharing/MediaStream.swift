// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import ARDProtocol
public import Foundation
public import RemoteDesktopCore
import SwiftSRTP
import Synchronization

/// What the receiving side of a media stream reports.
public enum MediaStreamEvent: Sendable {
    /// A whole coded picture of one display.
    case picture(leg: Int, AccessUnit, arrival: ContinuousClock.Instant)
    /// One coded audio frame: AAC-ELD, 48 kHz stereo, 480 samples.
    case audio(payload: Data, timestamp: UInt32, arrival: ContinuousClock.Instant)
    /// Pictures of a display were lost; a restart has been requested and pictures resume at it.
    case pictureLoss(leg: Int)
    /// A socket failed. The stream is over.
    case failed(TransportError)
}

/// Counters for one leg, for diagnostics and liveness.
public struct MediaLegStatistics: Sendable, Equatable {
    public var packets = 0
    /// Packets the Mac sent, going by their numbering; more than `packets` when some were lost.
    public var expectedPackets = 0
    public var bytes = 0
    public var pictures = 0
    public var keyframes = 0
    public var losses = 0
    /// Packets that failed authentication or were replays.
    public var rejected = 0
    /// Packets dropped unread because they belong to a stream this leg has moved on from.
    public var stalePackets = 0
    /// Datagrams dropped because processing had fallen too far behind the socket.
    public var overflowed = 0
    public var reportsFromServer = 0
    /// The codec the Mac is sending this leg in, once a picture packet has said.
    public var codec: MediaVideoCodec?
    /// Whole pictures that could not be started from, and broken ones, on the current stream.
    public var withheldPictures = 0
    public var spoiledPictures = 0
    public var lastWithheld = ""
    /// The Mac's latest report was a sender report: it has sent media since the one before.
    public var serverIsSending = false
    public var lastAuthenticPacket: ContinuousClock.Instant?
    /// When the current stream's first packet arrived. A new offer starts a new stream.
    public var streamStartedAt: ContinuousClock.Instant?
    /// Since when pictures have been withheld for want of one to restart from; `nil` while they flow.
    public var waitingForRestartSince: ContinuousClock.Instant?

    /// What a watchdog should make of a picture leg.
    public enum Health: Sendable, Equatable {
        case healthy
        /// Nothing authentic has arrived for too long. A Mac reports on every leg once a second
        /// even behind a still screen, so silence means the path is gone.
        case silent
        /// Pictures have been broken for too long and no restart got through.
        case unrepaired
    }

    /// Judges the leg at `now`. Time before `epoch` does not count against it: the moment the
    /// session started, or came back from the background, where sockets do not run.
    public func health(at now: ContinuousClock.Instant, since epoch: ContinuousClock.Instant, silenceLimit: Duration, repairLimit: Duration) -> Health {
        let lastHeard = [lastAuthenticPacket, epoch].compactMap { $0 }.max() ?? epoch
        if now - lastHeard >= silenceLimit { return .silent }
        if let waiting = waitingForRestartSince, now - max(waiting, epoch) >= repairLimit { return .unrepaired }
        return .healthy
    }
    public var oneWayDelay = 0.0
    /// What the receiver estimates the path carries, in kbit/s, as its rate reports tell the Mac; 0
    /// before the first measurement.
    public var bandwidthEstimate = 0

    public init() {}
}

/// Receives one negotiated media stream: the sound leg and a picture leg per display.
///
/// Every datagram is authenticated before anything reads it. The socket's own queue only hands
/// datagrams over; authentication, reordering, reassembly and the handler (which decodes) run on a
/// queue per leg, so a slow decoder never stops the socket being drained. Pictures are reassembled
/// here; decoding is the caller's, and so is saying which pictures decoded (``acknowledge(leg:ssrc:timestamp:)``):
/// a Mac predicts a refresh picture from an acknowledged one, which must be one the decoder holds.
/// Thread-safe.
public final class MediaStreamReceiver: Sendable {
    public struct Ports: Sendable, Equatable {
        public var audio: UInt16
        public var video: [UInt16]

        public init(audio: UInt16, video: [UInt16]) {
            self.audio = audio
            self.video = video
        }
    }

    private enum LegID: Sendable, Hashable {
        case audio
        case video(Int)
    }

    private struct Leg {
        let channel: any DatagramChannel
        var inbound: SRTPSession
        var outbound: SRTPSession
        var keys: MediaLegKeys
        /// The viewer's SSRC on this leg, which every report must lead with.
        var ssrc: UInt32
        /// Undoes reorderings before pictures are assembled, or sound is played.
        var reorder: RTPReorderBuffer
        /// When a release of what `reorder` holds is already scheduled for.
        var releaseScheduledFor: ContinuousClock.Instant?
        /// Replaced when packets of the other codec arrive: the payload type, not the offer, says
        /// which one the Mac chose.
        var depacketizer = VideoDepacketizer(codec: .hevc)
        var rate: RateFeedback
        var mediaSSRC: UInt32?
        /// The Mac's SSRCs of streams this leg has moved on from, newest last. A Mac sends each
        /// offer's stream under new SSRCs; a straggler from an old one would otherwise authenticate
        /// (under the same keys) and be taken for a new stream again.
        var retired: [UInt32] = []
        var pictureSize: (width: UInt16, height: UInt16)
        var statistics = MediaLegStatistics()
        /// The Mac's latest sender report: its time as a receiver report echoes it, and when it came.
        var lastSenderReport: (time: UInt32, arrival: ContinuousClock.Instant)?
        var reportedExpected = 0
        var reportedReceived = 0
        var sequence = SequenceTracker()
        /// Packets expected on earlier streams of this leg; a new offer restarts the numbering.
        var expectedBefore = 0
        /// The last packet put in order: a gap after it is a run of lost packets.
        var lastOrdered: UInt16?
        var restartRequestedAt: ContinuousClock.Instant?
        /// When the current stream's first packet came, and its latest keyframe or refresh picture:
        /// the Mac counts its second from whichever is later.
        var streamStartedAt: ContinuousClock.Instant?
        var lastRestartPointAt: ContinuousClock.Instant?
        /// Since when pictures have been withheld: from a stream's start until its first picture,
        /// and from a loss until the picture that mends it.
        var waitingSince: ContinuousClock.Instant?
        /// For following a sender that jumped ahead (see `SRTPSession.unprotectAfterJump`): the
        /// latest authentic media packet, rejections of the current stream since, and the latest try.
        var lastAuthenticMedia: ContinuousClock.Instant?
        var rejectedSinceAuthentic = 0
        var lastJumpRecovery: ContinuousClock.Instant?
        /// Bumped when the leg takes new keys or starts a new stream, so a packet authenticated
        /// under the old ones is not taken for the new.
        var epoch: UInt64 = 0
        var notedExtension = false

        init(channel: any DatagramChannel, keys: MediaLegKeys, ssrc: UInt32, size: (UInt16, UInt16), epoch: ContinuousClock.Instant, timing: Timing) throws(SRTPError) {
            self.channel = channel
            inbound = try SRTPSession(direction: .inbound, masterKey: keys.serverToViewer.bytes)
            outbound = try SRTPSession(direction: .outbound, masterKey: keys.viewerToServer.bytes)
            self.keys = keys
            self.ssrc = ssrc
            reorder = RTPReorderBuffer(hold: timing.reorderHold, startupHold: timing.startupHold)
            rate = RateFeedback(epoch: epoch)
            pictureSize = size
        }

        /// Whether a restart request made now would be read, rather than discarded as too soon.
        func acceptsRestartRequest(at now: ContinuousClock.Instant, gap: Duration) -> Bool {
            guard let since = [streamStartedAt, lastRestartPointAt].compactMap({ $0 }).max() else { return true }
            return now - since >= gap
        }

        /// Whether the timer should make (or repeat) the request now.
        func owesRestartRequest(at now: ContinuousClock.Instant, timing: Timing) -> Bool {
            guard depacketizer.isWaitingForRestart, mediaSSRC != nil, acceptsRestartRequest(at: now, gap: timing.serverGap) else { return false }
            guard let requested = restartRequestedAt else { return true }
            return now - requested >= timing.repeatInterval
        }

        /// Moves the leg on from the Mac's current stream: what follows is a new stream, and
        /// stragglers of the old one are turned away before they cost an authentication.
        mutating func retireStream() {
            if let old = mediaSSRC {
                if !retired.contains(old) { retired.append(old) }
                if retired.count > 8 { retired.removeFirst(retired.count - 8) }
                inbound.removeStream(ssrc: old)
            }
            mediaSSRC = nil
            reorder.reset()
            releaseScheduledFor = nil
            depacketizer = VideoDepacketizer(codec: depacketizer.codec)
            expectedBefore += sequence.expected
            sequence = SequenceTracker()
            lastOrdered = nil
            restartRequestedAt = nil
            streamStartedAt = nil
            lastRestartPointAt = nil
            waitingSince = nil
            rejectedSinceAuthentic = 0
            notedExtension = false
            epoch &+= 1
        }
    }

    private struct State {
        var audio: Leg
        var video: [Leg]
        var isStopped = false
        var timer: TimerBox?

        subscript(id: LegID) -> Leg {
            get {
                switch id {
                case .audio: audio
                case .video(let index): video[index]
                }
            }
            set {
                switch id {
                case .audio: audio = newValue
                case .video(let index): video[index] = newValue
                }
            }
        }
    }

    private let state: Mutex<State>
    private let handler: @Sendable (MediaStreamEvent) -> Void
    private let diagnostics: (@Sendable (String) -> Void)?
    private let acknowledgesOnAssembly: Bool
    private let epoch: ContinuousClock.Instant
    private let audioInbox: Inbox
    private let videoInboxes: [Inbox]

    /// When restart requests are made, and how long packets wait for stragglers.
    public struct Timing: Sendable {
        /// A Mac discards a restart request that comes within a second of the last keyframe or
        /// refresh picture it made (it logs "Request key frame too soon, discard"), and nothing
        /// later makes up for a discarded one. Requests are held until this long after the last
        /// such picture arrived, or after the stream began.
        public var serverGap: Duration = .milliseconds(1050)
        /// How long to wait for an answer before asking again.
        public var repeatInterval: Duration = .milliseconds(500)
        /// How long packets behind a gap wait for the missing ones before it counts as a loss.
        public var reorderHold: Duration = .milliseconds(15)
        /// How long a new stream's first packets wait, so that it starts from the lowest number.
        public var startupHold: Duration = .milliseconds(8)

        public init() {}
    }

    private let timing: Timing

    /// Size of the socket receive buffer asked for on picture legs. A Mac sends each picture as one
    /// burst at the speed of the link, which overruns a default-sized buffer however fast it is read.
    /// 8 MB holds a whole 730 KB keyframe ten times over; macOS 27 grants all of it, and where a
    /// system grants less the channel settles just below its limit (see `UDPDatagramChannel`).
    static let videoReceiveBuffer = 8 << 20

    /// A packet of the current stream that fails authentication this long after the last one that
    /// passed, or after this many failures in a row, may come from a sender that jumped ahead.
    static let jumpSilence: Duration = .milliseconds(500)
    static let jumpRejections = 4
    /// Each attempt costs up to 17 HMACs; forged packets must not make it a steady cost.
    static let jumpRecoveryInterval: Duration = .milliseconds(50)

    /// The sound leg's payload type; anything else on that leg is not the Mac's sound.
    static let audioPayloadType: UInt8 = 101

    /// Binds the ports and prepares the keys of `offer`. Nothing is received until ``start()``.
    ///
    /// - Parameters:
    ///   - acknowledgesOnAssembly: Acknowledge each picture as soon as it is whole, for a caller
    ///     that does not decode (a capture tool). A viewer that decodes leaves this off and calls
    ///     ``acknowledge(leg:ssrc:timestamp:)`` for each picture that decoded.
    ///   - diagnostics: Where notes about unusual packets go.
    public init(
        transport: any TransportProvider,
        ports: Ports,
        offer: MediaOffer,
        timing: Timing = Timing(),
        acknowledgesOnAssembly: Bool = false,
        diagnostics: (@Sendable (String) -> Void)? = nil,
        handler: @escaping @Sendable (MediaStreamEvent) -> Void
    ) async throws {
        self.timing = timing
        self.acknowledgesOnAssembly = acknowledgesOnAssembly
        self.diagnostics = diagnostics
        precondition(ports.video.count == offer.videos.count, "one port per offered picture leg")
        let epoch = ContinuousClock.now
        self.epoch = epoch

        func leg(port: UInt16, keys: MediaLegKeys, ssrc: UInt32, size: (UInt16, UInt16), buffer: Int?) async throws -> Leg {
            // The Mac sends from each port to the same port number here.
            let channel = try await transport.openDatagramChannel(
                DatagramOptions(localPort: port, remotePort: port, receiveBufferSize: buffer)
            )
            do {
                return try Leg(channel: channel, keys: keys, ssrc: ssrc, size: size, epoch: epoch, timing: timing)
            } catch {
                channel.close()
                throw error
            }
        }

        let audio = try await leg(port: ports.audio, keys: offer.audioKeys, ssrc: offer.audioSSRC, size: (0, 0), buffer: nil)
        var video: [Leg] = []
        do {
            for (port, description) in zip(ports.video, offer.videos) {
                video.append(try await leg(
                    port: port, keys: description.keys, ssrc: description.ssrc,
                    size: (description.width, description.height), buffer: Self.videoReceiveBuffer
                ))
            }
        } catch {
            audio.channel.close()
            for opened in video { opened.channel.close() }
            throw error
        }
        state = Mutex(State(audio: audio, video: video))
        self.handler = handler
        audioInbox = Inbox(label: "llc.turing.marionette.media.sound")
        videoInboxes = video.indices.map { Inbox(label: "llc.turing.marionette.media.picture.\($0)") }
    }

    deinit {
        stop()
    }

    public func start() {
        let (audioChannel, videoChannels) = state.withLock { ($0.audio.channel, $0.video.map(\.channel)) }
        audioInbox.start { [weak self] batch in self?.ingest(batch, leg: .audio) }
        audioChannel.start(
            onReceive: { [audioInbox] datagram in audioInbox.post(datagram) },
            onClose: { [weak self] error in if let error { self?.handler(.failed(error)) } }
        )
        for (index, channel) in videoChannels.enumerated() {
            let inbox = videoInboxes[index]
            inbox.start { [weak self] batch in self?.ingest(batch, leg: .video(index)) }
            channel.start(
                onReceive: { datagram in inbox.post(datagram) },
                onClose: { [weak self] error in if let error { self?.handler(.failed(error)) } }
            )
        }
        // A timer of its own rather than a task: the Mac's rate control and every repair depend on
        // these reports going out on time, whatever else the process's tasks are busy with.
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "llc.turing.marionette.media-reports", qos: .userInteractive))
        let tick = Mutex(0)
        timer.setEventHandler { [weak self] in
            let current = tick.withLock { value -> Int in
                value += 1
                return value
            }
            self?.sendPeriodicReports(tick: current)
        }
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(5))
        state.withLock { $0.timer = TimerBox(timer) }
        timer.resume()
        // Reports from the viewer's ports are also what opens a path through a NAT.
        sendPeriodicReports(tick: 0)
    }

    /// A dispatch timer is safe to cancel from any thread, which is all that is done with it here.
    private struct TimerBox: @unchecked Sendable {
        let source: any DispatchSourceTimer

        init(_ source: any DispatchSourceTimer) {
            self.source = source
        }
    }

    public func stop() {
        let teardown: (any DatagramChannel, [any DatagramChannel], TimerBox?)? = state.withLock { state in
            guard !state.isStopped else { return nil }
            state.isStopped = true
            defer { state.timer = nil }
            return (state.audio.channel, state.video.map(\.channel), state.timer)
        }
        guard let teardown else { return }
        teardown.2?.source.cancel()
        teardown.0.close()
        for channel in teardown.1 { channel.close() }
    }

    public var audioStatistics: MediaLegStatistics {
        var statistics = state.withLock { $0.audio.statistics }
        statistics.overflowed = audioInbox.overflowed
        return statistics
    }

    public func videoStatistics(leg: Int) -> MediaLegStatistics {
        var statistics = state.withLock { state in
            var statistics = state.video[leg].statistics
            statistics.oneWayDelay = state.video[leg].rate.delay
            statistics.bandwidthEstimate = Int(state.video[leg].rate.bandwidthEstimate)
            statistics.waitingForRestartSince = state.video[leg].waitingSince
            if state.video[leg].mediaSSRC != nil { statistics.codec = state.video[leg].depacketizer.codec }
            statistics.withheldPictures = state.video[leg].depacketizer.withheld
            statistics.spoiledPictures = state.video[leg].depacketizer.spoiled
            if let last = state.video[leg].depacketizer.lastWithheld {
                statistics.lastWithheld = "NAL types \(last.types)\(last.isRefresh ? ", marked refresh" : "")"
            }
            return statistics
        }
        statistics.overflowed = videoInboxes[leg].overflowed
        return statistics
    }

    /// Tells the receiver the size of a display's pictures after a new offer, which restart requests carry.
    public func setPictureSize(leg: Int, width: UInt16, height: UInt16) {
        state.withLock { $0.video[leg].pictureSize = (width, height) }
    }

    /// Readies every leg for the stream of a new offer. Call it before sending each offer.
    ///
    /// Whatever is under way on the current streams is dropped, and their SSRCs are retired, so
    /// their stragglers are turned away unread: a Mac sends every offer's streams under new SSRCs,
    /// even with the same keys.
    public func beginStream(_ offer: MediaOffer) throws(SRTPError) {
        precondition(offer.videos.count == videoInboxes.count, "one description per picture leg")
        var fresh: [LegID: (SRTPSession, SRTPSession)] = [:]
        let current = state.withLock { state in
            ([LegID.audio: state.audio.keys] as [LegID: MediaLegKeys]).merging(
                state.video.indices.map { (LegID.video($0), state.video[$0].keys) }, uniquingKeysWith: { $1 }
            )
        }
        let wanted: [LegID: MediaLegKeys] = [LegID.audio: offer.audioKeys].merging(
            offer.videos.indices.map { (LegID.video($0), offer.videos[$0].keys) }, uniquingKeysWith: { $1 }
        )
        for (id, keys) in wanted where current[id] != keys {
            fresh[id] = (
                try SRTPSession(direction: .inbound, masterKey: keys.serverToViewer.bytes),
                try SRTPSession(direction: .outbound, masterKey: keys.viewerToServer.bytes)
            )
        }
        state.withLock { state in
            for (id, keys) in wanted {
                state[id].retireStream()
                if let (inbound, outbound) = fresh[id] {
                    state[id].inbound = inbound
                    state[id].outbound = outbound
                    state[id].keys = keys
                }
            }
            state.audio.ssrc = offer.audioSSRC
            for (index, video) in offer.videos.enumerated() {
                state.video[index].ssrc = video.ssrc
                state.video[index].pictureSize = (video.width, video.height)
            }
        }
    }

    /// Starts one display's pictures over from a keyframe, for a decoder that cannot go on.
    /// Pictures are withheld until the keyframe arrives, and the request is repeated until it does.
    public func requestKeyframe(leg: Int) {
        requestRestart(leg: leg) { $0.requireKeyframe() }
    }

    /// Asks for a picture to go on from, for a decoder that dropped a picture but still holds the
    /// pictures it decoded before: a refresh picture predicted from the newest acknowledged one,
    /// where there is one, and otherwise a keyframe. Pictures are withheld until it arrives.
    public func requestRefresh(leg: Int) {
        requestRestart(leg: leg) { $0.requireRestart() }
    }

    private func requestRestart(leg: Int, _ prepare: (inout VideoDepacketizer) -> Void) {
        let packet: (any DatagramChannel, Data)? = state.withLock { state in
            guard !state.isStopped, state.video.indices.contains(leg) else { return nil }
            prepare(&state.video[leg].depacketizer)
            state.video[leg].restartRequestedAt = nil
            if state.video[leg].waitingSince == nil { state.video[leg].waitingSince = .now }
            guard state.video[leg].acceptsRestartRequest(at: .now, gap: timing.serverGap) else { return nil }
            return Self.restartRequest(&state.video[leg]).map { (state.video[leg].channel, $0) }
        }
        if let packet { packet.0.send(packet.1) }
    }

    /// Tells the Mac a picture decoded, so that it may predict a refresh picture from it. Ignored
    /// for a picture of a stream the leg has moved on from.
    public func acknowledge(leg: Int, ssrc: UInt32, timestamp: UInt32) {
        let packet: (any DatagramChannel, Data)? = state.withLock { state in
            guard !state.isStopped, state.video.indices.contains(leg), state.video[leg].mediaSSRC == ssrc else { return nil }
            return Self.acknowledgement(&state.video[leg], timestamp: timestamp).map { (state.video[leg].channel, $0) }
        }
        if let packet { packet.0.send(packet.1) }
    }

    private static func acknowledgement(_ leg: inout Leg, timestamp: UInt32) -> Data? {
        // Acknowledged pictures are what the Mac can restart from without a keyframe. Its H.264
        // encoder never makes such a picture (its acknowledgements go astray inside the Mac), so
        // a lost H.264 picture always costs a keyframe.
        leg.depacketizer.acceptsRefresh = leg.depacketizer.codec == .hevc
        return try? leg.outbound.protectRTCP(RTCPMessage.acknowledgement(ssrc: leg.ssrc, picture: timestamp))
    }

    // MARK: Receiving (on each leg's queue)

    /// What one datagram needs before it can be authenticated outside the lock.
    private struct Admission {
        let session: SRTPSession
        let epoch: UInt64
        let mayHaveJumped: Bool
    }

    private func ingest(_ batch: [Datagram], leg id: LegID) {
        var batch = batch
        var events: [MediaStreamEvent] = []
        var replies: [Data] = []
        var channel: (any DatagramChannel)?
        for index in batch.indices {
            // Taken out of the batch, the bytes have one owner and are decrypted where they lie.
            var payload = Data()
            swap(&payload, &batch[index].payload)
            let arrival = batch[index].receivedAt
            let kind = MediaPacketKind.classify(payload)
            let claimed = MediaPacketKind.claimedSSRC(payload)
            let admission: Admission? = state.withLock { state in
                guard !state.isStopped else { return nil }
                channel = state[id].channel
                guard kind != .neither, let claimed else {
                    state[id].statistics.rejected += 1
                    return nil
                }
                guard !state[id].retired.contains(claimed) else {
                    state[id].statistics.stalePackets += 1
                    return nil
                }
                let leg = state[id]
                let quiet = leg.lastAuthenticMedia.map { arrival - $0 >= Self.jumpSilence } ?? false
                let mayHaveJumped = kind == .rtp && claimed == leg.mediaSSRC
                    && (quiet || leg.rejectedSinceAuthentic >= Self.jumpRejections)
                    && leg.lastJumpRecovery.map { arrival - $0 >= Self.jumpRecoveryInterval } ?? true
                if mayHaveJumped { state[id].lastJumpRecovery = arrival }
                return Admission(session: leg.inbound, epoch: leg.epoch, mayHaveJumped: mayHaveJumped)
            }
            guard let admission else { continue }
            let authentic: Bool
            do {
                switch kind {
                case .rtcp: try admission.session.unprotectRTCP(&payload)
                case .rtp where admission.mayHaveJumped: try admission.session.unprotectAfterJump(&payload)
                default: try admission.session.unprotect(&payload)
                }
                authentic = true
            } catch {
                authentic = false
            }
            state.withLock { state in
                guard !state.isStopped, state[id].epoch == admission.epoch else { return }
                guard authentic else {
                    state[id].statistics.rejected += 1
                    if kind == .rtp, claimed == state[id].mediaSSRC { state[id].rejectedSinceAuthentic += 1 }
                    return
                }
                if kind == .rtcp {
                    Self.noteReport(payload, arrival: arrival, leg: &state[id])
                    return
                }
                guard let packet = try? RTPPacket.parse(payload) else {
                    state[id].statistics.rejected += 1
                    return
                }
                switch id {
                case .audio:
                    takeAudio(packet, arrival: arrival, leg: &state.audio, events: &events)
                case .video(let index):
                    takeVideo(packet, size: payload.count, arrival: arrival, leg: &state.video[index], index: index, events: &events, replies: &replies)
                }
            }
        }
        if let channel {
            for reply in replies { channel.send(reply) }
        }
        scheduleRelease(leg: id)
        for event in events { handler(event) }
    }

    /// Takes an authentic packet of the sound leg.
    private func takeAudio(_ packet: RTPPacket, arrival: ContinuousClock.Instant, leg: inout Leg, events: inout [MediaStreamEvent]) {
        guard packet.payloadType == Self.audioPayloadType else {
            leg.statistics.rejected += 1
            return
        }
        noteAuthentic(packet, arrival: arrival, leg: &leg)
        for ordered in leg.reorder.push(packet, at: arrival) {
            noteOrdered(ordered, leg: &leg)
            events.append(.audio(payload: ordered.payload, timestamp: ordered.timestamp, arrival: arrival))
        }
    }

    /// Takes an authentic packet of a picture leg.
    private func takeVideo(
        _ packet: RTPPacket, size: Int, arrival: ContinuousClock.Instant, leg: inout Leg, index: Int,
        events: inout [MediaStreamEvent], replies: inout [Data]
    ) {
        noteAuthentic(packet, arrival: arrival, leg: &leg)
        leg.rate.received(
            ssrc: packet.ssrc, timestamp: packet.timestamp, at: arrival, size: size, marker: packet.marker,
            startsProbe: packet.payload.first.map(ReceiveBandwidthEstimator.startsProbe) ?? false
        )
        if let control = packet.mediaControl, !control.isFamiliar, !leg.notedExtension {
            leg.notedExtension = true
            diagnostics?("leg \(index): an unfamiliar picture header extension, 0x\(String(control.profile, radix: 16))")
        }
        if let codec = MediaVideoCodec(payloadType: packet.payloadType), codec != leg.depacketizer.codec {
            leg.depacketizer = VideoDepacketizer(codec: codec)
        }
        for ordered in leg.reorder.push(packet, at: arrival) {
            consume(ordered, leg: &leg, index: index, arrival: arrival, events: &events, replies: &replies)
        }
    }

    /// Bookkeeping for every authentic media packet, before reordering. A packet of a new SSRC
    /// starts a new stream; the old one is retired.
    private func noteAuthentic(_ packet: RTPPacket, arrival: ContinuousClock.Instant, leg: inout Leg) {
        if leg.mediaSSRC != packet.ssrc {
            if leg.mediaSSRC != nil { leg.retireStream() }
            leg.mediaSSRC = packet.ssrc
            leg.streamStartedAt = arrival
            leg.waitingSince = arrival
            leg.statistics.streamStartedAt = arrival
        }
        leg.statistics.packets += 1
        leg.statistics.bytes += packet.payload.count
        leg.statistics.lastAuthenticPacket = arrival
        leg.lastAuthenticMedia = arrival
        leg.rejectedSinceAuthentic = 0
        leg.sequence.note(packet.sequence)
        leg.statistics.expectedPackets = leg.expectedBefore + leg.sequence.expected
    }

    /// Counts the packets missing before one now in order, as a burst for the rate report.
    private func noteOrdered(_ packet: RTPPacket, leg: inout Leg) {
        if let last = leg.lastOrdered {
            let missing = Int(packet.sequence &- last &- 1)
            if missing > 0, missing < 0x8000 { leg.rate.lost(run: missing) }
        }
        leg.lastOrdered = packet.sequence
    }

    /// The Mac's own reports are authenticated for liveness; only their type and time are read.
    private static func noteReport(_ clear: Data, arrival: ContinuousClock.Instant, leg: inout Leg) {
        guard let leading = RTCPMessage.leading(clear) else {
            leg.statistics.rejected += 1
            return
        }
        leg.statistics.reportsFromServer += 1
        leg.statistics.lastAuthenticPacket = arrival
        if leading.type == RTCPMessage.senderReportType {
            if let time = RTCPMessage.senderReportTime(clear) { leg.lastSenderReport = (time, arrival) }
            leg.statistics.serverIsSending = true
        } else if leading.type == RTCPMessage.receiverReportType {
            leg.statistics.serverIsSending = false
        }
    }

    /// Feeds one packet, now in sending order, to the leg's picture assembly, and gathers what follows from it.
    private func consume(
        _ packet: RTPPacket, leg: inout Leg, index: Int, arrival: ContinuousClock.Instant,
        events: inout [MediaStreamEvent], replies: inout [Data]
    ) {
        noteOrdered(packet, leg: &leg)
        switch leg.depacketizer.push(packet) {
        case .none:
            break
        case .loss:
            leg.statistics.losses += 1
            events.append(.pictureLoss(leg: index))
            // Asked at once where the Mac will listen; otherwise the timer asks the moment it will.
            leg.restartRequestedAt = nil
            if leg.waitingSince == nil { leg.waitingSince = arrival }
            if leg.acceptsRestartRequest(at: arrival, gap: timing.serverGap), let request = Self.restartRequest(&leg) { replies.append(request) }
        case .picture(let unit):
            leg.statistics.pictures += 1
            if unit.isKeyframe { leg.statistics.keyframes += 1 }
            if unit.isKeyframe || unit.isRefresh { leg.lastRestartPointAt = arrival }
            leg.restartRequestedAt = nil
            leg.waitingSince = nil
            if acknowledgesOnAssembly, let acknowledgement = Self.acknowledgement(&leg, timestamp: unit.timestamp) {
                replies.append(acknowledgement)
            }
            events.append(.picture(leg: index, unit, arrival: arrival))
        }
    }

    /// The request that gets pictures flowing again.
    ///
    /// Where this side has acknowledged pictures and its decoder still holds them, a refresh
    /// request brings a small picture predicted from the newest of them. Otherwise only a keyframe
    /// will do, and a picture-loss indication asks for one. (With nothing acknowledged a Mac
    /// running macOS 27 answers a refresh request with ordinary pictures, never a keyframe.) A Mac
    /// discards either request within a second of its last keyframe or refresh picture; see ``Timing``.
    private static func restartRequest(_ leg: inout Leg) -> Data? {
        guard let media = leg.mediaSSRC else { return nil }
        leg.restartRequestedAt = .now
        let message = leg.depacketizer.acceptsRefresh
            ? RTCPMessage.refreshRequest(ssrc: leg.ssrc, mediaSSRC: media, width: leg.pictureSize.width, height: leg.pictureSize.height)
            : RTCPMessage.pictureLoss(ssrc: leg.ssrc, mediaSSRC: media)
        return try? leg.outbound.protectRTCP(message)
    }

    /// The once-a-second receiver report. Once media flows it carries a report block: a Mac reads
    /// one out of every receiver report whether it is there or not, and takes its round-trip time
    /// from the echo of its own sender report in it. On the sound leg a source description follows,
    /// as Apple's viewer sends it.
    private static func receiverReport(_ leg: inout Leg, now: ContinuousClock.Instant, withDescription: Bool) -> Data {
        let description = withDescription ? RTCPMessage.sourceDescription(ssrc: leg.ssrc) : Data()
        guard let media = leg.mediaSSRC, leg.sequence.expected > 0 else { return RTCPMessage.receiverReport(ssrc: leg.ssrc) + description }
        let expected = leg.expectedBefore + leg.sequence.expected
        let received = leg.statistics.packets
        let expectedSince = expected - leg.reportedExpected
        let lostSince = max(0, expectedSince - (received - leg.reportedReceived))
        leg.reportedExpected = expected
        leg.reportedReceived = received
        var echoed: UInt32 = 0
        var delay: UInt32 = 0
        if let last = leg.lastSenderReport {
            let elapsed = now - last.arrival
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            echoed = last.time
            delay = UInt32(clamping: Int(max(0, seconds) * 65536))
        }
        return RTCPMessage.receiverReport(ssrc: leg.ssrc, report: RTCPMessage.ReceptionReport(
            mediaSSRC: media,
            fractionLost: expectedSince > 0 ? UInt8(clamping: lostSince * 256 / expectedSince) : 0,
            cumulativeLost: UInt32(clamping: max(0, expected - received)),
            extendedHighestSequence: leg.sequence.extendedHighest,
            jitter: 0,
            lastSenderReport: echoed,
            delaySinceLastSenderReport: delay
        )) + description
    }

    /// Lets go of packets held for stragglers that never came, so the gap is seen as the loss it
    /// is: without this a loss just before a still screen would wait for the screen to change.
    /// Runs on the leg's queue, in order with what arrives.
    private func releaseOverdue(leg id: LegID) {
        var events: [MediaStreamEvent] = []
        var replies: [Data] = []
        let channel: (any DatagramChannel)? = state.withLock { state in
            guard !state.isStopped else { return nil }
            state[id].releaseScheduledFor = nil
            let now = ContinuousClock.now
            for packet in state[id].reorder.release(at: now) {
                switch id {
                case .audio:
                    noteOrdered(packet, leg: &state.audio)
                    events.append(.audio(payload: packet.payload, timestamp: packet.timestamp, arrival: now))
                case .video(let index):
                    consume(packet, leg: &state.video[index], index: index, arrival: now, events: &events, replies: &replies)
                }
            }
            return state[id].channel
        }
        if let channel {
            for reply in replies { channel.send(reply) }
        }
        scheduleRelease(leg: id)
        for event in events { handler(event) }
    }

    /// Makes sure the leg's queue looks again when what its reorder buffer holds falls due.
    private func scheduleRelease(leg id: LegID) {
        let deadline: ContinuousClock.Instant? = state.withLock { state in
            guard !state.isStopped, let deadline = state[id].reorder.deadline else { return nil }
            if let scheduled = state[id].releaseScheduledFor, scheduled <= deadline { return nil }
            state[id].releaseScheduledFor = deadline
            return deadline
        }
        guard let deadline else { return }
        let delay = max(.zero, deadline - .now)
        let nanoseconds = Int(delay.components.seconds) * 1_000_000_000 + Int(delay.components.attoseconds / 1_000_000_000)
        inbox(id).queue.asyncAfter(deadline: .now() + .nanoseconds(nanoseconds)) { [weak self] in
            self?.releaseOverdue(leg: id)
        }
    }

    private func inbox(_ id: LegID) -> Inbox {
        switch id {
        case .audio: audioInbox
        case .video(let index): videoInboxes[index]
        }
    }

    /// Waits until every leg has dealt with what has arrived so far. For tests.
    func waitUntilIdle() {
        audioInbox.queue.sync {}
        for inbox in videoInboxes { inbox.queue.sync {} }
    }

    // MARK: Reporting

    /// Called every 50 ms. Rate reports go out each time; receiver reports once a second; a restart
    /// request is repeated every half second until a picture answers it, since the Mac drops
    /// requests that come too soon after its last keyframe.
    private func sendPeriodicReports(tick: Int) {
        var outgoing: [(any DatagramChannel, Data)] = []
        state.withLock { state in
            guard !state.isStopped else { return }
            let now = ContinuousClock.now
            if tick % 20 == 0,
               let report = try? state.audio.outbound.protectRTCP(Self.receiverReport(&state.audio, now: now, withDescription: true)) {
                outgoing.append((state.audio.channel, report))
            }
            for index in state.video.indices {
                if tick % 20 == 0,
                   let report = try? state.video[index].outbound.protectRTCP(Self.receiverReport(&state.video[index], now: now, withDescription: false)) {
                    outgoing.append((state.video[index].channel, report))
                }
                if let report = state.video[index].rate.report(ssrc: state.video[index].ssrc, now: now),
                   let protected = try? state.video[index].outbound.protectRTCP(report) {
                    outgoing.append((state.video[index].channel, protected))
                }
                if state.video[index].owesRestartRequest(at: now, timing: timing) {
                    if let request = Self.restartRequest(&state.video[index]) {
                        outgoing.append((state.video[index].channel, request))
                    }
                }
            }
        }
        for (channel, packet) in outgoing { channel.send(packet) }
    }
}

/// Hands datagrams from a socket's queue to the queue that processes them, in batches.
///
/// The socket's handler only appends, so the socket is drained at once however long processing
/// takes; past `capacity` waiting datagrams the newest are dropped, as the socket would drop them.
private final class Inbox: Sendable {
    private struct Pending {
        var datagrams: [Datagram] = []
        var isScheduled = false
        var overflowed = 0
        var process: (@Sendable ([Datagram]) -> Void)?
    }

    let queue: DispatchQueue
    private let pending = Mutex(Pending())
    /// About 10 MB of picture packets: several keyframes.
    static let capacity = 8192

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    var overflowed: Int { pending.withLock { $0.overflowed } }

    func start(_ process: @escaping @Sendable ([Datagram]) -> Void) {
        pending.withLock { $0.process = process }
    }

    func post(_ datagram: Datagram) {
        let schedule: Bool = pending.withLock { pending in
            guard pending.datagrams.count < Self.capacity else {
                pending.overflowed += 1
                return false
            }
            pending.datagrams.append(datagram)
            defer { pending.isScheduled = true }
            return !pending.isScheduled
        }
        if schedule { queue.async { [self] in drain() } }
    }

    private func drain() {
        while true {
            let (batch, process): ([Datagram], (@Sendable ([Datagram]) -> Void)?) = pending.withLock { pending in
                var batch: [Datagram] = []
                swap(&batch, &pending.datagrams)
                if batch.isEmpty { pending.isScheduled = false }
                return (batch, pending.process)
            }
            guard !batch.isEmpty else { return }
            process?(batch)
        }
    }
}
