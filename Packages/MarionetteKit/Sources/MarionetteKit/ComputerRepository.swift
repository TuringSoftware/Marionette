// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
public import RemoteDesktopCore
public import SwiftData

/// The persisted form of a saved computer.
///
/// The settings travel as one encoded ``ComputerConfiguration`` so that adding an option never needs a
/// store migration; only what the library sorts or draws from is a column of its own.
@Model
public final class SavedComputer {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var createdAt: Date
    public var lastConnected: Date?
    public var lastModeRaw: String?
    public var configurationData: Data
    @Attribute(.externalStorage) public var thumbnail: Data?

    public init(configuration: ComputerConfiguration, createdAt: Date) {
        id = configuration.id
        name = configuration.displayName
        self.createdAt = createdAt
        configurationData = (try? JSONEncoder().encode(configuration)) ?? Data()
    }

    var configuration: ComputerConfiguration? {
        get { try? JSONDecoder().decode(ComputerConfiguration.self, from: configurationData) }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else { return }
            configurationData = data
            name = newValue.displayName
        }
    }

    var record: ComputerRecord? {
        guard let configuration else { return nil }
        return ComputerRecord(
            configuration: configuration,
            thumbnail: thumbnail,
            lastConnected: lastConnected,
            lastMode: lastModeRaw.flatMap(SessionMode.init(rawValue:))
        )
    }
}

/// Reads and writes saved computers. The only place that touches SwiftData.
@MainActor
public final class ComputerRepository {
    public let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public init(container: ModelContainer) {
        self.container = container
    }

    /// A container holding saved computers, on disk or in memory.
    public static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        try ModelContainer(
            for: SavedComputer.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: inMemory)
        )
    }

    /// Every saved computer, oldest first, so the grid never reshuffles on its own.
    public func records() -> [ComputerRecord] {
        let descriptor = FetchDescriptor<SavedComputer>(sortBy: [SortDescriptor(\.createdAt), SortDescriptor(\.name)])
        return ((try? context.fetch(descriptor)) ?? []).compactMap(\.record)
    }

    public func record(id: UUID) -> ComputerRecord? {
        model(id: id)?.record
    }

    /// Inserts or updates.
    public func save(_ configuration: ComputerConfiguration, now: Date) {
        if let existing = model(id: configuration.id) {
            existing.configuration = configuration
        } else {
            context.insert(SavedComputer(configuration: configuration, createdAt: now))
        }
        try? context.save()
    }

    public func delete(id: UUID) {
        guard let existing = model(id: id) else { return }
        context.delete(existing)
        try? context.save()
    }

    public func recordConnection(id: UUID, mode: SessionMode, at date: Date) {
        guard let existing = model(id: id) else { return }
        existing.lastConnected = date
        existing.lastModeRaw = mode.rawValue
        try? context.save()
    }

    public func setThumbnail(_ data: Data?, id: UUID) {
        guard let existing = model(id: id) else { return }
        existing.thumbnail = data
        try? context.save()
    }

    private func model(id: UUID) -> SavedComputer? {
        var descriptor = FetchDescriptor<SavedComputer>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
