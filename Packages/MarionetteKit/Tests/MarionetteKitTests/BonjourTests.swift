// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import dnssd
import Foundation
import Network
import Synchronization
import Testing
@testable import MarionetteKit

private final class ScriptedBrowser: BonjourBrowsing {
    private struct State {
        var continuation: AsyncStream<BonjourBrowseEvent>.Continuation?
        var browsedTypes: [String] = []
        var isStopped = false
        var addresses: [String: BonjourAddress] = [:]
        var resolveRequests: [String] = []
    }

    private let state = Mutex(State())

    init(addresses: [String: BonjourAddress] = [:]) {
        state.withLock { $0.addresses = addresses }
    }

    var browsedTypes: [String] { state.withLock { $0.browsedTypes } }
    var isStopped: Bool { state.withLock { $0.isStopped } }
    var resolveRequests: [String] { state.withLock { $0.resolveRequests } }

    func answer(_ name: String, with address: BonjourAddress) {
        state.withLock { $0.addresses[name] = address }
    }

    func send(_ event: BonjourBrowseEvent) {
        _ = state.withLock { $0.continuation?.yield(event) }
    }

    func advertise(_ names: String...) {
        send(.services(Set(names.map { BonjourService(name: $0, type: "_rfb._tcp", domain: "local.") })))
    }

    func browse(type: String) -> AsyncStream<BonjourBrowseEvent> {
        AsyncStream { continuation in
            state.withLock {
                $0.browsedTypes.append(type)
                $0.continuation = continuation
            }
            continuation.onTermination = { [weak self] _ in self?.state.withLock { $0.isStopped = true } }
        }
    }

    func resolve(_ service: BonjourService) async -> BonjourAddress? {
        state.withLock {
            $0.resolveRequests.append(service.name)
            return $0.addresses[service.name]
        }
    }
}

@Suite struct BonjourMappingTests {
    @Test func aBrowseResultsEndpointBecomesAService() {
        let endpoint = NWEndpoint.service(name: "Jamie’s MacBook Air", type: "_rfb._tcp", domain: "local.", interface: nil)
        #expect(BonjourMapping.service(for: endpoint) == BonjourService(name: "Jamie’s MacBook Air", type: "_rfb._tcp", domain: "local."))
        let dotted = NWEndpoint.service(name: "Studio", type: "_rfb._tcp.", domain: "local.", interface: nil)
        #expect(BonjourMapping.service(for: dotted)?.type == "_rfb._tcp")
        #expect(BonjourMapping.service(for: .hostPort(host: "studio-mac.local", port: 5900)) == nil)
    }

    @Test func aDeniedLocalNetworkPermissionIsRecognisedHoweverTheBrowserReportsIt() {
        let denied = NWError.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied))
        let other = NWError.dns(DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning))
        #expect(BonjourMapping.isPolicyDenied(denied))
        #expect(!BonjourMapping.isPolicyDenied(other))
        #expect(!BonjourMapping.isPolicyDenied(.posix(.ENETDOWN)))
        #expect(BonjourMapping.event(for: .waiting(denied)) == .permissionDenied)
        #expect(BonjourMapping.event(for: .failed(denied)) == .permissionDenied)
        // Waiting for a network to come back is not a failure.
        #expect(BonjourMapping.event(for: .waiting(.posix(.ENETDOWN))) == nil)
        if case .failed = BonjourMapping.event(for: .failed(other)) {} else { Issue.record("a browser failure should be reported") }
        #expect(BonjourMapping.event(for: .ready) == nil)
        #expect(BonjourMapping.event(for: .setup) == nil)
        #expect(BonjourMapping.event(for: .cancelled) == nil)
    }

    @Test func resolvedServicesBecomeConnectableComputersSortedByName() {
        func service(_ name: String) -> BonjourService { BonjourService(name: name, type: "_rfb._tcp", domain: "local.") }
        #expect(BonjourMapping.host(fromTarget: "Studio-Mac.local.") == "Studio-Mac.local")
        #expect(BonjourMapping.host(fromTarget: "10.0.0.2") == "10.0.0.2")
        let computers = BonjourMapping.computers(
            [
                service("studio Mac"): BonjourAddress(host: "Studio-Mac.local", port: 5900),
                service("Build Server"): BonjourAddress(host: "build.local", port: 5901),
                service("Mac 10"): BonjourAddress(host: "mac-10.local", port: 5900),
                service("Mac 2"): BonjourAddress(host: "mac-2.local", port: 5900),
                // The same machine advertised under a second name is listed once.
                service("Mac 2 (2)"): BonjourAddress(host: "mac-2.local", port: 5900),
            ],
            backendID: BackendID.appleScreenSharing
        )
        #expect(computers.map(\.name) == ["Build Server", "Mac 2", "Mac 10", "studio Mac"])
        #expect(computers[0] == DiscoveredComputer(name: "Build Server", host: "build.local", port: 5901, backendID: BackendID.appleScreenSharing))
        #expect(BonjourMapping.computers([:], backendID: BackendID.vnc).isEmpty)
    }
}

@Suite struct BonjourDiscoveryProviderTests {
    private let addresses = [
        "Studio Mac": BonjourAddress(host: "Studio-Mac.local", port: 5900),
        "Build Server": BonjourAddress(host: "build.local", port: 5901),
    ]

    private func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    @Test func nothingIsBrowsedUntilTheStreamIsIterated() async throws {
        let browser = ScriptedBrowser()
        let provider = BonjourDiscoveryProvider(browser: browser)
        do {
            let stream = provider.browse()
            _ = stream
            try await Task.sleep(for: .milliseconds(30))
            #expect(browser.browsedTypes.isEmpty)
        }
        try await Task.sleep(for: .milliseconds(30))
        #expect(browser.browsedTypes.isEmpty)
    }

    @Test func servicesAreReportedOnceResolvedAndGoAwayWhenWithdrawn() async throws {
        let browser = ScriptedBrowser(addresses: addresses)
        let provider = BonjourDiscoveryProvider(browser: browser, serviceType: "_rfb._tcp", backendID: BackendID.vnc)
        var events = provider.browse().makeAsyncIterator()

        async let first = events.next()
        await eventually { browser.browsedTypes == ["_rfb._tcp"] }
        // "Ghost" is advertised but never answers: it cannot be connected to, so it is not listed.
        browser.advertise("Studio Mac", "Ghost")
        var snapshots: [[DiscoveredComputer]] = []
        if case .results(let computers) = await first { snapshots.append(computers) }
        while snapshots.last?.count != 1, case .results(let computers) = await events.next() { snapshots.append(computers) }
        #expect(snapshots.last == [DiscoveredComputer(name: "Studio Mac", host: "Studio-Mac.local", port: 5900, backendID: BackendID.vnc)])

        browser.advertise("Studio Mac", "Ghost", "Build Server")
        #expect(await events.next() == .results([
            DiscoveredComputer(name: "Build Server", host: "build.local", port: 5901, backendID: BackendID.vnc),
            DiscoveredComputer(name: "Studio Mac", host: "Studio-Mac.local", port: 5900, backendID: BackendID.vnc),
        ]))
        // A service that answered is not asked again, however often the browser repeats it; one that
        // did not is asked again when the browser next reports.
        #expect(browser.resolveRequests.filter { $0 != "Ghost" }.sorted() == ["Build Server", "Studio Mac"])
        // Resolutions run side by side, so the one that never answers may be asked a moment later.
        await eventually { browser.resolveRequests.contains("Ghost") }

        browser.advertise("Build Server")
        #expect(await events.next() == .results([DiscoveredComputer(name: "Build Server", host: "build.local", port: 5901, backendID: BackendID.vnc)]))
        browser.advertise()
        #expect(await events.next() == .results([]))
    }

    /// Regression: a Mac that did not answer the first time (asleep, or asked while the app
    /// was suspended) stayed off the list until a refresh, though it was still advertised.
    @Test func aMachineThatDidNotAnswerAtFirstIsAskedAgainUntilItDoes() async throws {
        let browser = ScriptedBrowser()
        let provider = BonjourDiscoveryProvider(browser: browser, resolveRetryDelay: { _ in .milliseconds(20) })
        var events = provider.browse().makeAsyncIterator()
        async let first = events.next()
        await eventually { !browser.browsedTypes.isEmpty }
        browser.advertise("Studio Mac")
        #expect(await first == .results([]))
        await eventually { browser.resolveRequests.count >= 3 }
        browser.answer("Studio Mac", with: BonjourAddress(host: "Studio-Mac.local", port: 5900))
        #expect(await events.next() == .results([DiscoveredComputer(name: "Studio Mac", host: "Studio-Mac.local", port: 5900, backendID: BackendID.appleScreenSharing)]))
        let asked = browser.resolveRequests.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(browser.resolveRequests.count == asked)
    }

    @Test func aDeniedPermissionIsReportedAndEndsTheStream() async throws {
        let browser = ScriptedBrowser()
        var events = BonjourDiscoveryProvider(browser: browser).browse().makeAsyncIterator()
        async let first = events.next()
        await eventually { !browser.browsedTypes.isEmpty }
        browser.send(.permissionDenied)
        #expect(await first == .permissionDenied)
        #expect(await events.next() == nil)
        await eventually { browser.isStopped }
    }

    @Test func aBrowserThatFailsLeavesNothingListed() async throws {
        let browser = ScriptedBrowser(addresses: addresses)
        var events = BonjourDiscoveryProvider(browser: browser).browse().makeAsyncIterator()
        async let first = events.next()
        await eventually { !browser.browsedTypes.isEmpty }
        browser.advertise("Studio Mac")
        var last = await first
        while last != .results([DiscoveredComputer(name: "Studio Mac", host: "Studio-Mac.local", port: 5900, backendID: BackendID.appleScreenSharing)]) {
            last = await events.next()
        }
        browser.send(.failed("mDNSResponder is not running"))
        #expect(await events.next() == .results([]))
        #expect(await events.next() == nil)
    }

    @Test func cancellingTheConsumerStopsBrowsing() async throws {
        let browser = ScriptedBrowser(addresses: addresses)
        let provider = BonjourDiscoveryProvider(browser: browser)
        let consumer = Task {
            var seen = 0
            for await _ in provider.browse() { seen += 1 }
            return seen
        }
        await eventually { !browser.browsedTypes.isEmpty }
        browser.advertise("Studio Mac")
        #expect(!browser.isStopped)
        consumer.cancel()
        _ = await consumer.value
        await eventually { browser.isStopped }
        #expect(browser.browsedTypes.count == 1)
    }

    /// Sleeps a hundredth as long, so waits measured in seconds pass quickly.
    private struct QuickClock: AppClock {
        var now: Date { Date() }
        var uptime: Double { ProcessInfo.processInfo.systemUptime }
        func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration / 100) }
    }

    /// Regression: browsing the system stopped (in the background, say) left the library
    /// with nothing until a refresh, since a search that had ended still counted as running.
    @Test func theLibraryLooksAgainWhenBrowsingStopsByItself() async throws {
        let browser = ScriptedBrowser(addresses: addresses)
        let library = await LibraryModel(
            repository: ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true)),
            secrets: InMemorySecretStore(), discovery: BonjourDiscoveryProvider(browser: browser), clock: QuickClock()
        )
        await library.startDiscovery()
        await eventually { browser.browsedTypes.count == 1 }
        browser.send(.failed("the network went away"))
        await eventually { browser.browsedTypes.count == 2 }
        browser.advertise("Studio Mac")
        try await waitUntil { library.discovered.map(\.host) == ["Studio-Mac.local"] }
        // Coming back to the foreground leaves a running search alone.
        await library.resumeDiscovery()
        try await Task.sleep(for: .milliseconds(50))
        #expect(browser.browsedTypes.count == 2)
        await library.stopDiscovery()
    }

    @Test func theLibrarySearchesThroughTheProvider() async throws {
        let browser = ScriptedBrowser(addresses: addresses)
        let library = await LibraryModel(
            repository: ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true)),
            secrets: InMemorySecretStore(), discovery: BonjourDiscoveryProvider(browser: browser), clock: SystemClock()
        )
        #expect(browser.browsedTypes.isEmpty)
        await library.startDiscovery()
        await eventually { !browser.browsedTypes.isEmpty }
        browser.advertise("Studio Mac")
        try await waitUntil { library.discovered.map(\.host) == ["Studio-Mac.local"] }
        await library.stopDiscovery()
        await eventually { browser.isStopped }
    }
}
