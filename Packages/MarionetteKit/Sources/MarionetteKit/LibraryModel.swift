// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
import Observation
import RemoteDesktopCore

/// The home screen's state: saved computers and what discovery has found.
@MainActor
@Observable
public final class LibraryModel {
    public enum DiscoveryState: Sendable, Hashable {
        /// Not looking (yet).
        case idle
        case searching
        /// The app is not allowed to use the local network.
        case denied
    }

    /// A saved computer as the grid shows it.
    public struct Item: Identifiable, Sendable, Hashable {
        public var record: ComputerRecord
        /// Seen on the network by the current discovery pass.
        public var isOnline: Bool
        /// A session with this computer is open.
        public var isActive: Bool

        public var id: UUID { record.id }
        public var configuration: ComputerConfiguration { record.configuration }
    }

    public private(set) var records: [ComputerRecord] = []
    public private(set) var discoveryState: DiscoveryState = .idle
    private var found: [DiscoveredComputer] = []

    private let repository: ComputerRepository
    private let secrets: any SecretStore
    private let discovery: any DiscoveryProvider
    private let clock: any AppClock
    private let owner: OwnerAuthentication
    private var discoveryTask: Task<Void, Never>?
    /// Identifiers of computers with an open session; supplied by the session store.
    public var activeComputerIDs: Set<UUID> = []

    public init(
        repository: ComputerRepository, secrets: any SecretStore, discovery: any DiscoveryProvider, clock: any AppClock,
        owner: OwnerAuthentication = .simulated
    ) {
        self.repository = repository
        self.secrets = secrets
        self.discovery = discovery
        self.clock = clock
        self.owner = owner
        reload()
    }

    // MARK: Saved computers

    public var items: [Item] {
        let onlineHosts = Set(found.map { $0.host.lowercased() })
        return records.map {
            Item(record: $0, isOnline: onlineHosts.contains($0.configuration.host.lowercased()), isActive: activeComputerIDs.contains($0.id))
        }
    }

    public var isEmpty: Bool { records.isEmpty }

    public var now: Date { clock.now }

    public func reload() {
        records = repository.records()
    }

    public func delete(_ id: UUID) {
        if let configuration = repository.record(id: id)?.configuration {
            secrets.removeAllSecrets(for: configuration)
        }
        repository.delete(id: id)
        reload()
    }

    /// A copy with a new identity, placed after the original.
    public func duplicate(_ id: UUID) {
        guard var copy = repository.record(id: id)?.configuration else { return }
        copy.id = UUID()
        copy.name = String(localized: "\(copy.displayName) Copy", bundle: #bundle)
        repository.save(copy, now: clock.now)
        reload()
    }

    public func editor(for id: UUID) -> ComputerEditorModel? {
        guard let record = repository.record(id: id) else { return nil }
        return makeEditor(record.configuration, isNew: false)
    }

    public func editorForNewComputer() -> ComputerEditorModel {
        makeEditor(ComputerConfiguration(), isNew: true)
    }

    /// An editor pre-filled from a machine found on the network.
    public func editor(for discovered: DiscoveredComputer) -> ComputerEditorModel {
        makeEditor(Self.configuration(for: discovered), isNew: true)
    }

    /// Saves a discovered machine as it is and returns its configuration, for "connect now".
    @discardableResult
    public func save(_ discovered: DiscoveredComputer) -> ComputerConfiguration {
        let configuration = Self.configuration(for: discovered)
        repository.save(configuration, now: clock.now)
        reload()
        return configuration
    }

    /// A configuration for connecting to a found machine without saving it first. The sign-in sheet
    /// offers to save it; until then it stays out of the library.
    public func unsavedConfiguration(for discovered: DiscoveredComputer) -> ComputerConfiguration {
        Self.configuration(for: discovered)
    }

    private static func configuration(for discovered: DiscoveredComputer) -> ComputerConfiguration {
        ComputerConfiguration(
            name: discovered.name,
            host: discovered.host,
            port: discovered.port == 5900 ? nil : discovered.port,
            backendID: discovered.backendID
        )
    }

    private func makeEditor(_ configuration: ComputerConfiguration, isNew: Bool) -> ComputerEditorModel {
        ComputerEditorModel(configuration: configuration, isNew: isNew, repository: repository, secrets: secrets, clock: clock, owner: owner) { [weak self] in
            self?.reload()
        }
    }

    // MARK: Discovery

    /// Machines on the network that are not saved yet.
    public var discovered: [DiscoveredComputer] {
        let savedHosts = Set(records.map { $0.configuration.host.lowercased() })
        return found.filter { !savedHosts.contains($0.host.lowercased()) }
    }

    /// Starts looking for machines, if not looking already. The first call makes the system ask for
    /// Local Network access.
    public func startDiscovery() {
        guard discoveryTask == nil else { return }
        discoveryState = .searching
        discoveryTask = Task { [weak self, discovery, clock] in
            for await event in discovery.browse() {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .results(let computers):
                    self.found = computers
                case .permissionDenied:
                    self.found = []
                    self.discoveryState = .denied
                    self.discoveryTask = nil
                    return
                }
            }
            // Browsing stopped by itself (the network went away, or the system dropped it while the
            // app was in the background). Look again in a moment; until then this task still counts
            // as the search, so nothing starts a second one.
            try? await clock.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.discoveryTask = nil
            self.startDiscovery()
        }
    }

    /// Makes sure a search is running, as when the app comes back to the foreground. One that is
    /// running is left alone; one that stopped is started again.
    public func resumeDiscovery() {
        guard discoveryState != .denied else { return }
        startDiscovery()
    }

    /// Looks again from scratch (pull to refresh). Returns once the first answers have had a moment
    /// to arrive, so the refresh indicator means something.
    public func refreshDiscovery() async {
        stopDiscovery()
        startDiscovery()
        try? await clock.sleep(for: .seconds(1.5))
    }

    public func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        found = []
        discoveryState = .idle
    }
}
