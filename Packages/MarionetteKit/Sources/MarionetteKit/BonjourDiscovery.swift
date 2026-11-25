// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import dnssd
import Foundation
import Network
import Synchronization

// MARK: - Seam

/// One advertised service, as a browser reports it: not yet somewhere a connection can go.
struct BonjourService: Sendable, Hashable {
    /// The instance name: for a Mac, its computer name ("Jamie’s MacBook Air").
    var name: String
    /// For example "_rfb._tcp".
    var type: String
    /// For example "local.".
    var domain: String
}

/// Where a service is: the advertising machine's host name and the service's port.
struct BonjourAddress: Sendable, Hashable {
    var host: String
    var port: UInt16
}

enum BonjourBrowseEvent: Sendable, Hashable {
    /// Every service currently advertised; replaces the previous set.
    case services(Set<BonjourService>)
    /// The app may not use the local network. Terminal.
    case permissionDenied
    /// Browsing stopped for another reason. Terminal.
    case failed(String)
}

/// What discovery needs from the network. The live one is Network.framework and DNS-SD; tests script one.
protocol BonjourBrowsing: Sendable {
    /// Browses for one service type until the stream is dropped.
    func browse(type: String) -> AsyncStream<BonjourBrowseEvent>
    /// Asks the advertising machine for its host name and the service's port. `nil` if it does not answer.
    func resolve(_ service: BonjourService) async -> BonjourAddress?
}

// MARK: - Mapping

/// The pure steps between what the network reports and what the library shows.
enum BonjourMapping {
    /// The service behind a browse result's endpoint; `nil` for endpoints that are not services.
    static func service(for endpoint: NWEndpoint) -> BonjourService? {
        guard case .service(let name, let type, let domain, _) = endpoint else { return nil }
        return BonjourService(name: name, type: type.hasSuffix(".") ? String(type.dropLast()) : type, domain: domain)
    }

    /// Whether an error is the system refusing local network access to this app.
    static func isPolicyDenied(_ error: NWError) -> Bool {
        if case .dns(let code) = error { return code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) }
        return false
    }

    /// What a browser's state means for discovery, if anything. A denied local-network permission
    /// shows up as "waiting" with the policy error, not as a failure.
    static func event(for state: NWBrowser.State) -> BonjourBrowseEvent? {
        switch state {
        case .waiting(let error):
            isPolicyDenied(error) ? .permissionDenied : nil
        case .failed(let error):
            isPolicyDenied(error) ? .permissionDenied : .failed(String(describing: error))
        default:
            nil
        }
    }

    /// A host name as connections take it: DNS-SD reports it fully qualified, with a trailing dot.
    static func host(fromTarget target: String) -> String {
        target.hasSuffix(".") ? String(target.dropLast()) : target
    }

    /// The machines to show: one per address, sorted by name.
    static func computers(_ resolved: [BonjourService: BonjourAddress], backendID: String) -> [DiscoveredComputer] {
        var seen = Set<String>()
        return resolved
            .map { DiscoveredComputer(name: $0.key.name, host: $0.value.host, port: $0.value.port, backendID: backendID) }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            .filter { seen.insert($0.id).inserted }
    }
}

// MARK: - Provider

/// Finds machines that advertise Screen Sharing or VNC (`_rfb._tcp`) with Bonjour.
///
/// Each machine is reported with its `.local` host name and port, which is what a connection needs
/// and stays valid when its address changes. Nothing touches the network until the stream returned
/// by ``browse()`` is first iterated, so the Local Network prompt appears when the user looks for
/// computers and not before. The app's Info.plist must list the service type under
/// `NSBonjourServices` and explain itself in `NSLocalNetworkUsageDescription`.
public struct BonjourDiscoveryProvider: DiscoveryProvider {
    public var serviceType: String
    /// The back end discovered machines are saved with. Screen Sharing by default: its connection
    /// ladder ends in plain VNC, so a machine that is not a Mac still connects.
    public var backendID: String
    let browser: any BonjourBrowsing
    /// How long to wait before asking an advertised machine for its address again, by attempt
    /// (1 for the first retry). A machine that does not answer at once (one waking from sleep, or
    /// asked while this app was suspended) is asked again for as long as it is advertised.
    let resolveRetryDelay: @Sendable (Int) -> Duration

    public init(serviceType: String = "_rfb._tcp", backendID: String = BackendID.appleScreenSharing) {
        self.init(browser: NetworkBonjourBrowser(), serviceType: serviceType, backendID: backendID)
    }

    init(
        browser: any BonjourBrowsing, serviceType: String = "_rfb._tcp", backendID: String = BackendID.appleScreenSharing,
        resolveRetryDelay: @escaping @Sendable (Int) -> Duration = { .seconds(min(1 << min($0, 5), 30)) }
    ) {
        self.browser = browser
        self.serviceType = serviceType
        self.backendID = backendID
        self.resolveRetryDelay = resolveRetryDelay
    }

    public func browse() -> AsyncStream<DiscoveryEvent> {
        let run = Run(browser: browser, serviceType: serviceType, backendID: backendID, resolveRetryDelay: resolveRetryDelay)
        // The run is owned by the stream: dropping the stream, or cancelling its consumer, stops it.
        return AsyncStream(unfolding: { await run.next() }, onCancel: { run.stop() })
    }

    /// One pass of browsing, started by the first request for an event.
    private final class Run: Sendable {
        private struct State {
            var channel: (events: AsyncStream<DiscoveryEvent>, task: Task<Void, Never>)?
            var isStopped = false
        }

        private let browser: any BonjourBrowsing
        private let serviceType: String
        private let backendID: String
        private let resolveRetryDelay: @Sendable (Int) -> Duration
        private let state = Mutex(State())

        init(browser: any BonjourBrowsing, serviceType: String, backendID: String, resolveRetryDelay: @escaping @Sendable (Int) -> Duration) {
            self.browser = browser
            self.serviceType = serviceType
            self.backendID = backendID
            self.resolveRetryDelay = resolveRetryDelay
        }

        deinit {
            stop()
        }

        func next() async -> DiscoveryEvent? {
            let events: AsyncStream<DiscoveryEvent>? = state.withLock { state in
                if state.isStopped { return nil }
                if state.channel == nil { state.channel = start() }
                return state.channel?.events
            }
            guard let events else { return nil }
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }

        func stop() {
            state.withLock { state in
                state.isStopped = true
                state.channel?.task.cancel()
                state.channel = nil
            }
        }

        private enum Input: Sendable {
            case browse(BonjourBrowseEvent)
            case resolved(BonjourService, BonjourAddress?)
        }

        private func start() -> (events: AsyncStream<DiscoveryEvent>, task: Task<Void, Never>) {
            let (events, output) = AsyncStream<DiscoveryEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
            let (browser, serviceType, backendID, retryDelay) = (browser, serviceType, backendID, resolveRetryDelay)
            let task = Task {
                defer { output.finish() }
                await withTaskGroup(of: Void.self) { group in
                    let (inputs, input) = AsyncStream<Input>.makeStream()
                    group.addTask {
                        for await event in browser.browse(type: serviceType) { input.yield(.browse(event)) }
                        input.finish()
                    }
                    var advertised = Set<BonjourService>()
                    var resolving = Set<BonjourService>()
                    var resolved: [BonjourService: BonjourAddress] = [:]
                    var failedResolves: [BonjourService: Int] = [:]
                    var reported: [DiscoveredComputer]?
                    func report() {
                        let computers = BonjourMapping.computers(resolved, backendID: backendID)
                        guard computers != reported else { return }
                        reported = computers
                        output.yield(.results(computers))
                    }
                    loop: for await item in inputs {
                        switch item {
                        case .browse(.services(let services)):
                            advertised = services
                            resolved = resolved.filter { services.contains($0.key) }
                            failedResolves = failedResolves.filter { services.contains($0.key) }
                            for service in services where resolved[service] == nil && !resolving.contains(service) {
                                resolving.insert(service)
                                group.addTask { input.yield(.resolved(service, await browser.resolve(service))) }
                            }
                            report()
                        case .browse(.permissionDenied):
                            output.yield(.permissionDenied)
                            break loop
                        case .browse(.failed):
                            // Nothing can be found any more; say so rather than show stale machines.
                            resolved = [:]
                            report()
                            break loop
                        case .resolved(let service, let address):
                            guard advertised.contains(service) else {
                                resolving.remove(service)
                                continue
                            }
                            if let address {
                                resolving.remove(service)
                                failedResolves[service] = nil
                                resolved[service] = address
                                report()
                            } else {
                                // No answer: ask again later rather than leave the machine out until
                                // the person refreshes. It stays "resolving" meanwhile.
                                let attempt = (failedResolves[service] ?? 0) + 1
                                failedResolves[service] = attempt
                                let delay = retryDelay(attempt)
                                group.addTask {
                                    try? await Task.sleep(for: delay)
                                    guard !Task.isCancelled else { return }
                                    input.yield(.resolved(service, await browser.resolve(service)))
                                }
                            }
                        }
                    }
                    group.cancelAll()
                }
            }
            return (events, task)
        }
    }
}

// MARK: - Live

/// Browsing with `NWBrowser`; resolving with DNS-SD, which reports a service's host name and port
/// without connecting to it.
struct NetworkBonjourBrowser: BonjourBrowsing {
    var resolveTimeout: Duration = .seconds(5)

    func browse(type: String) -> AsyncStream<BonjourBrowseEvent> {
        AsyncStream { continuation in
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: NWParameters())
            browser.stateUpdateHandler = { state in
                guard let event = BonjourMapping.event(for: state) else { return }
                continuation.yield(event)
                continuation.finish()
            }
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(.services(Set(results.compactMap { BonjourMapping.service(for: $0.endpoint) })))
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: DispatchQueue(label: "llc.turing.Marionette.bonjour"))
        }
    }

    func resolve(_ service: BonjourService) async -> BonjourAddress? {
        let resolution = Resolution()
        let timeout = resolveTimeout
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resolution.queue.async { resolution.start(service, timeout: timeout, continuation: continuation) }
            }
        } onCancel: {
            resolution.queue.async { resolution.finish(nil) }
        }
    }

    // @unchecked Sendable: every property is only touched on `queue`, where DNS-SD also calls back.
    private final class Resolution: @unchecked Sendable {
        let queue = DispatchQueue(label: "llc.turing.Marionette.bonjour.resolve")
        private var operation: DNSServiceRef?
        private var continuation: CheckedContinuation<BonjourAddress?, Never>?
        private var isFinished = false

        func start(_ service: BonjourService, timeout: Duration, continuation: CheckedContinuation<BonjourAddress?, Never>) {
            guard !isFinished else {
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation
            // Unretained: the caller keeps this object alive until the continuation resumes, and
            // `finish` ends the operation before that, after which DNS-SD calls back no more.
            let context = Unmanaged.passUnretained(self).toOpaque()
            var operation: DNSServiceRef?
            let status = DNSServiceResolve(
                &operation, 0, 0, service.name, service.type, service.domain,
                { _, _, _, status, _, target, port, _, _, context in
                    guard let context else { return }
                    let resolution = Unmanaged<Resolution>.fromOpaque(context).takeUnretainedValue()
                    guard status == kDNSServiceErr_NoError, let target else {
                        resolution.finish(nil)
                        return
                    }
                    resolution.finish(BonjourAddress(host: BonjourMapping.host(fromTarget: String(cString: target)), port: UInt16(bigEndian: port)))
                },
                context
            )
            guard status == kDNSServiceErr_NoError, let operation else {
                finish(nil)
                return
            }
            self.operation = operation
            DNSServiceSetDispatchQueue(operation, queue)
            queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000))) { self.finish(nil) }
        }

        func finish(_ address: BonjourAddress?) {
            guard !isFinished else { return }
            isFinished = true
            if let operation {
                DNSServiceRefDeallocate(operation)
                self.operation = nil
            }
            continuation?.resume(returning: address)
            continuation = nil
        }
    }
}
