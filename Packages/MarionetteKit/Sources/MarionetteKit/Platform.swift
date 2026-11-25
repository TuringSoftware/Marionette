// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation
public import RemoteDesktopCore
import Synchronization

// The seams between MarionetteKit and the platform. The app supplies UIKit-backed implementations; tests and
// the simulated environment use the in-memory ones below.

// MARK: - Clock

/// Wall-clock time and sleeping. Named `AppClock` so it does not shadow the standard library's `Clock`.
public protocol AppClock: Sendable {
    var now: Date { get }
    /// Seconds on a monotonic time base, comparable with touch timestamps.
    var uptime: Double { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemClock: AppClock {
    public init() {}
    public var now: Date { Date() }
    public var uptime: Double { ProcessInfo.processInfo.systemUptime }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// Reports a fixed date so relative dates in screenshots never change. Sleeping is real.
public struct FixedClock: AppClock {
    public var now: Date

    public init(now: Date = FixedClock.referenceDate) {
        self.now = now
    }

    /// 21 November 2026, 09:41 UTC.
    public static let referenceDate = Date(timeIntervalSince1970: 1_795_254_060)

    public var uptime: Double { ProcessInfo.processInfo.systemUptime }
    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

// MARK: - Secrets

/// What a stored secret is for.
public struct SecretKey: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case remoteDesktopPassword = "rd"
        case tunnelPassword = "ssh"
        /// The passphrase of an SSH key. Filed per key (``SecretKey/init(appWide:name:)``), not per computer.
        case keyPassphrase = "key"
        /// An SSH private key. App-wide, named by the user.
        case sshPrivateKey = "pk"
        /// The list of SSH keys (names and public halves). App-wide.
        case sshKeyIndex = "pki"
        /// Not a secret: the mark that the computer at an address proved its identity with Apple's
        /// SRP login. Filed by address like the password it protects, and removed with it.
        case provenIdentity = "srp"
        /// Not a secret: the mark that the computer at an address encrypted its sessions. From then
        /// on its sessions there must be encrypted. Filed and removed like ``provenIdentity``.
        case encryptedBefore = "enc"
    }

    public var computerID: UUID
    public var kind: Kind
    /// Set for secrets that belong to the app rather than to one computer (SSH keys and their
    /// passphrases): the item's name. `computerID` is then ``appWideID``.
    public var name: String?
    /// Where the secret may be sent: the address, port and route it was saved for (see
    /// ``remoteDesktopPassword(for:)``). A password saved for one address is never offered to
    /// another, so editing a computer's address does not send its password to the new one.
    /// `nil` only for secrets saved before passwords were filed this way.
    public var route: String?

    /// A computer's secret saved before passwords were filed by address; see
    /// ``SecretStore/migrateLegacySecrets(of:)``.
    public init(computerID: UUID, kind: Kind) {
        self.computerID = computerID
        self.kind = kind
    }

    private init(computerID: UUID, kind: Kind, route: String) {
        self.computerID = computerID
        self.kind = kind
        self.route = route
    }

    /// A secret that is not tied to one computer, such as an SSH key several computers use.
    public init(appWide kind: Kind, name: String) {
        computerID = Self.appWideID
        self.kind = kind
        self.name = name
    }

    /// The remote-desktop password of a computer at its current address: host, port, and the SSH
    /// server it travels through, if any (a name can mean another machine from there).
    public static func remoteDesktopPassword(for computer: ComputerConfiguration) -> SecretKey {
        SecretKey(computerID: computer.id, kind: .remoteDesktopPassword, route: computer.remoteDesktopRoute)
    }

    /// The password of an SSH account on `server`, for a tunnel or for file access.
    public static func sshPassword(for computer: ComputerConfiguration, server: Endpoint) -> SecretKey {
        SecretKey(computerID: computer.id, kind: .tunnelPassword, route: ComputerConfiguration.route(to: server))
    }

    /// The mark that the computer at its current address proved its identity.
    public static func provenIdentity(for computer: ComputerConfiguration) -> SecretKey {
        SecretKey(computerID: computer.id, kind: .provenIdentity, route: computer.remoteDesktopRoute)
    }

    /// The mark that the computer's sessions at its current address were encrypted.
    public static func encryptedBefore(for computer: ComputerConfiguration) -> SecretKey {
        SecretKey(computerID: computer.id, kind: .encryptedBefore, route: computer.remoteDesktopRoute)
    }

    /// The `computerID` of app-wide secrets.
    public static let appWideID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// The account name under which the secret is filed.
    public var account: String {
        // "@" cannot begin a UUID, and a UUID contains no space, so the kinds of account never collide.
        if let name { return "\(kind.rawValue):@\(name)" }
        if let route { return "\(kind.rawValue):\(computerID.uuidString) \(route)" }
        return "\(kind.rawValue):\(computerID.uuidString)"
    }
}

extension ComputerConfiguration {
    /// Where the remote-desktop password goes, as filed with it.
    var remoteDesktopRoute: String {
        let direct = Self.route(to: endpoint)
        return tunnel.isEnabled ? "\(direct) via \(Self.route(to: tunnelServer))" : direct
    }

    static func route(to endpoint: Endpoint) -> String {
        "\(endpoint.host.lowercased()):\(endpoint.port)"
    }

    /// The SSH servers this computer's SSH passwords are for: the tunnel's, and the computer's own
    /// for file access (the same server when the tunnel ends at the computer).
    var sshServers: [Endpoint] {
        let servers = [tunnelServer, fileAccessTarget.server]
        return servers[0] == servers[1] ? [servers[0]] : servers
    }
}

public enum SecretStoreError: Error, Sendable, Hashable {
    /// The underlying store reported a failure (for the Keychain, an `OSStatus`).
    case storeFailure(code: Int32)
}

/// Passwords and passphrases. Never stored with the saved computers.
public protocol SecretStore: Sendable {
    func secret(for key: SecretKey) throws -> String?
    func setSecret(_ secret: String, for key: SecretKey) throws
    func removeSecret(for key: SecretKey) throws
}

extension SecretStore {
    /// Removes everything stored for one computer, at its current address and from before
    /// passwords were filed by address.
    public func removeAllSecrets(for computer: ComputerConfiguration) {
        for kind in [SecretKey.Kind.remoteDesktopPassword, .tunnelPassword, .keyPassphrase] {
            try? removeSecret(for: SecretKey(computerID: computer.id, kind: kind))
        }
        removeAddressedSecrets(of: computer)
    }

    /// Removes the remote-desktop and SSH passwords filed for the computer's current address, and
    /// the marks that it proved its identity and encrypted its sessions there.
    func removeAddressedSecrets(of computer: ComputerConfiguration) {
        try? removeSecret(for: .remoteDesktopPassword(for: computer))
        try? removeSecret(for: .provenIdentity(for: computer))
        try? removeSecret(for: .encryptedBefore(for: computer))
        for server in computer.sshServers {
            try? removeSecret(for: .sshPassword(for: computer, server: server))
        }
    }

    /// Files a computer's passwords saved before passwords were filed by address under its current
    /// address and route: where they were being sent until now. The SSH password went to both the
    /// tunnel and file access, so it is filed for both.
    public func migrateLegacySecrets(of computer: ComputerConfiguration) {
        func move(_ legacy: SecretKey, to keys: [SecretKey]) {
            guard let value = (try? secret(for: legacy)) ?? nil else { return }
            do {
                for key in keys where try secret(for: key) == nil {
                    try setSecret(value, for: key)
                }
                try removeSecret(for: legacy)
            } catch {
                // The old entry stays until it can be moved whole.
            }
        }
        move(SecretKey(computerID: computer.id, kind: .remoteDesktopPassword), to: [.remoteDesktopPassword(for: computer)])
        move(
            SecretKey(computerID: computer.id, kind: .tunnelPassword),
            to: computer.sshServers.map { .sshPassword(for: computer, server: $0) }
        )
    }
}

public final class InMemorySecretStore: SecretStore {
    private let storage = Mutex<[SecretKey: String]>([:])

    public init() {}

    public func secret(for key: SecretKey) throws -> String? {
        storage.withLock { $0[key] }
    }

    public func setSecret(_ secret: String, for key: SecretKey) throws {
        storage.withLock { $0[key] = secret }
    }

    public func removeSecret(for key: SecretKey) throws {
        storage.withLock { $0[key] = nil }
    }
}

// MARK: - Pasteboard

/// The device's general pasteboard.
public protocol LocalPasteboard: Sendable {
    /// Increases whenever the pasteboard's contents change.
    var changeCount: Int { get async }
    /// Whether the contents are marked as concealed (``PasteboardType/concealed``), as password
    /// managers do. Must not show the system paste confirmation.
    var isConcealed: Bool { get async }
    /// Reads the contents. On iOS this may show the system paste confirmation.
    func read() async -> [ClipboardItem]
    /// Replaces the contents. `localOnly` keeps them off Universal Clipboard.
    func write(_ items: [ClipboardItem], localOnly: Bool) async
}

public actor InMemoryPasteboard: LocalPasteboard {
    public private(set) var items: [ClipboardItem] = []
    public private(set) var changeCount = 0
    /// Whether the last write asked to stay off Universal Clipboard.
    public private(set) var lastWriteWasLocalOnly = false
    /// How many times the contents were read (each would be a paste prompt on iOS).
    public private(set) var readCount = 0

    public init() {}

    public var isConcealed: Bool {
        items.contains { $0.representations[PasteboardType.concealed] != nil }
    }

    public func read() async -> [ClipboardItem] {
        readCount += 1
        return items
    }

    public func write(_ items: [ClipboardItem], localOnly: Bool) async {
        self.items = items
        lastWriteWasLocalOnly = localOnly
        changeCount += 1
    }
}

// MARK: - Discovery

/// A machine advertising a remote-desktop service on the local network.
public struct DiscoveredComputer: Sendable, Hashable, Identifiable {
    public var name: String
    public var host: String
    public var port: UInt16
    /// The back end that understands the advertised service.
    public var backendID: String

    public init(name: String, host: String, port: UInt16, backendID: String) {
        self.name = name
        self.host = host
        self.port = port
        self.backendID = backendID
    }

    public var id: String { "\(backendID)|\(host)|\(port)" }
}

public enum DiscoveryEvent: Sendable, Hashable {
    /// The complete current set of results; replaces the previous one.
    case results([DiscoveredComputer])
    /// The app may not use the local network. Terminal.
    case permissionDenied
}

/// Finds machines on the local network. Browsing starts when the stream is first iterated and stops
/// when it is cancelled, so nothing touches the network (or triggers the Local Network prompt) until
/// the user asks.
public protocol DiscoveryProvider: Sendable {
    func browse() -> AsyncStream<DiscoveryEvent>
}

/// Reports a scripted set of machines after a short delay.
public struct SimulatedDiscoveryProvider: DiscoveryProvider {
    public var computers: [DiscoveredComputer]
    public var delay: Duration
    public var deniesPermission: Bool

    public init(
        computers: [DiscoveredComputer] = SimulatedDiscoveryProvider.sampleComputers,
        delay: Duration = .milliseconds(600),
        deniesPermission: Bool = false
    ) {
        self.computers = computers
        self.delay = delay
        self.deniesPermission = deniesPermission
    }

    public static let sampleComputers = [
        DiscoveredComputer(name: "Studio Mac", host: "studio-mac.local", port: 5900, backendID: BackendID.appleScreenSharing),
        DiscoveredComputer(name: "Jamie’s MacBook Air", host: "jamies-macbook-air.local", port: 5900, backendID: BackendID.appleScreenSharing),
        DiscoveredComputer(name: "Kitchen iMac", host: "kitchen-imac.local", port: 5900, backendID: BackendID.appleScreenSharing),
        DiscoveredComputer(name: "Mac Studio", host: "mac-studio.local", port: 5900, backendID: BackendID.appleScreenSharing),
    ]

    public func browse() -> AsyncStream<DiscoveryEvent> {
        let (computers, delay, denies) = (computers, delay, deniesPermission)
        return AsyncStream { continuation in
            let task = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                if denies {
                    continuation.yield(.permissionDenied)
                    continuation.finish()
                    return
                }
                // Results trickle in, as they do with Bonjour.
                for count in 1...max(1, computers.count) {
                    continuation.yield(.results(Array(computers.prefix(count))))
                    try? await Task.sleep(for: delay / 3)
                    if Task.isCancelled { return }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Identifiers of the back ends Marionette knows about, as persisted with saved computers.
public enum BackendID {
    public static let appleScreenSharing = "apple-screen-sharing"
    public static let vnc = "vnc"
    public static let simulated = "simulated"
}
