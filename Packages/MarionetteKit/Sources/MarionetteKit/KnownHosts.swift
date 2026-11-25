// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
public import RemoteDesktopCore
public import RemoteDesktopTransport

/// An SSH server whose host key the user accepted and asked to remember.
public struct KnownHost: Sendable, Hashable, Codable, Identifiable {
    public var host: String
    public var port: UInt16
    public var key: KnownHostKey
    /// When the key was accepted.
    public var added: Date

    public init(host: String, port: UInt16, key: KnownHostKey, added: Date) {
        self.host = host
        self.port = port
        self.key = key
        self.added = added
    }

    public var id: String { "\(host.lowercased())|\(port)" }
    public var endpoint: Endpoint { Endpoint(host: host, port: port) }
}

/// A ``HostKeyStore`` that can also be looked through and pruned, for a "Known Hosts" screen.
/// Host names are compared without regard to case.
public protocol KnownHostsStore: HostKeyStore {
    /// Every remembered host, sorted by name and port.
    func all() async -> [KnownHost]
    func remove(host: String, port: UInt16) async
    func removeAll() async
}

private struct KnownHostsTable {
    var hosts: [String: KnownHost] = [:]

    static func id(_ host: String, _ port: UInt16) -> String { "\(host.lowercased())|\(port)" }

    var sorted: [KnownHost] {
        hosts.values.sorted {
            let order = $0.host.localizedStandardCompare($1.host)
            return order == .orderedSame ? $0.port < $1.port : order == .orderedAscending
        }
    }

    func key(for server: Endpoint) -> KnownHostKey? {
        hosts[Self.id(server.host, server.port)]?.key
    }

    mutating func remember(_ key: KnownHostKey, for server: Endpoint, at date: Date) {
        hosts[Self.id(server.host, server.port)] = KnownHost(host: server.host, port: server.port, key: key, added: date)
    }

    /// Whether anything was there to remove.
    mutating func remove(host: String, port: UInt16) -> Bool {
        hosts.removeValue(forKey: Self.id(host, port)) != nil
    }
}

/// Known hosts that last as long as the process: the simulated environment and tests.
public actor InMemoryKnownHostsStore: KnownHostsStore {
    private var table = KnownHostsTable()

    public init() {}

    public func knownKey(for server: Endpoint) -> KnownHostKey? { table.key(for: server) }
    public func remember(_ key: KnownHostKey, for server: Endpoint) { table.remember(key, for: server, at: Date()) }
    public func all() -> [KnownHost] { table.sorted }
    public func remove(host: String, port: UInt16) { _ = table.remove(host: host, port: port) }
    public func removeAll() { table = KnownHostsTable() }
}

/// Known hosts in a JSON file, read on first use and rewritten atomically after every change.
///
/// A file that cannot be read counts as empty: the worst outcome is being asked about a host key
/// again, never trusting one silently.
public actor FileHostKeyStore: KnownHostsStore {
    public nonisolated let fileURL: URL
    private var table: KnownHostsTable?
    /// The last failure to write the file, if the most recent write failed. For diagnostics.
    public private(set) var lastWriteError: String?

    private struct File: Codable {
        var version = 1
        var hosts: [KnownHost]
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `Application Support/Marionette/known_hosts.json` in the app's container.
    public static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "Marionette", directoryHint: .isDirectory).appending(path: "known_hosts.json")
    }

    private func loaded() -> KnownHostsTable {
        if let table { return table }
        var fresh = KnownHostsTable()
        if let data = try? Data(contentsOf: fileURL), let file = try? JSONDecoder().decode(File.self, from: data) {
            for host in file.hosts { fresh.hosts[host.id] = host }
        }
        table = fresh
        return fresh
    }

    private func save(_ changed: KnownHostsTable) {
        table = changed
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(File(hosts: changed.sorted)).write(to: fileURL, options: .atomic)
            lastWriteError = nil
        } catch {
            // The key stays remembered for this run; the user is asked again after a relaunch.
            lastWriteError = String(describing: error)
        }
    }

    public func knownKey(for server: Endpoint) -> KnownHostKey? {
        loaded().key(for: server)
    }

    public func remember(_ key: KnownHostKey, for server: Endpoint) {
        var table = loaded()
        table.remember(key, for: server, at: Date())
        save(table)
    }

    public func all() -> [KnownHost] {
        loaded().sorted
    }

    public func remove(host: String, port: UInt16) {
        var table = loaded()
        if table.remove(host: host, port: port) { save(table) }
    }

    public func removeAll() {
        guard !loaded().hosts.isEmpty else { return }
        save(KnownHostsTable())
    }
}
