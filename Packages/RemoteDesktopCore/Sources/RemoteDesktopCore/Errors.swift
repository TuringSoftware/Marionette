// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

/// Something the user can do about a failure. Front ends turn these into buttons.
public enum RecoveryAction: Sendable, Hashable {
    case retry
    case editCredentials
    case editConnection
    /// Open the system settings page where the named permission is granted.
    case openSystemSettings
    case connectWithStandardMode
    case connectWithoutTunnel
    /// Connect once more, accepting a login that cannot prove the computer's identity (see
    /// ``ConnectionFailure/identityUnverifiable(detail:)``).
    case connectWithoutVerifying
    case showHelp(topic: HelpTopic)
}

public enum HelpTopic: String, Sendable, Hashable {
    case enableScreenSharing
    case enableRemoteLogin
    case localNetworkPermission
    case highPerformanceRequirements
    case draggingFiles
}

/// Why a connection attempt did not produce a session.
public enum ConnectionFailure: Error, Sendable, Hashable {
    /// The host name did not resolve or nothing answered.
    case unreachable(host: String, detail: String)
    case timedOut(phase: ConnectionPhase)
    /// The server refused the credentials. `detail` is the server's text, if it sent any.
    case authenticationFailed(detail: String?)
    /// The account is valid but may not share this screen.
    case permissionDenied(detail: String?)
    /// The user declined an unknown or changed host key.
    case hostKeyRejected(host: String)
    case localNetworkDenied
    case tunnelFailed(detail: String)
    /// The server speaks something this back end cannot use.
    case unsupportedServer(detail: String)
    /// The server speaks another protocol altogether (to the Screen Sharing back end: a VNC server
    /// that is not a Mac). Nothing was sent to it; another back end may connect.
    case otherProtocol(detail: String)
    /// The requested mode cannot be used; a different mode might work.
    case modeUnavailable(mode: SessionMode, reason: UnavailableReason)
    /// Another viewer already holds the resource this session needs.
    case busy(detail: String)
    case protocolViolation(detail: String)
    /// The server failed to prove it knows the account's password (SRP's server proof did not
    /// match). Something is impersonating the computer, so no other mode or back end is tried:
    /// a fallback would hand the password to the impostor.
    case serverNotAuthenticated(detail: String)
    /// The computer proved its identity on earlier connections (Apple's SRP login), but whatever
    /// answered this time offers only logins that cannot, or is not a Mac at all. Nothing was sent
    /// to it. Only the user can decide to go ahead (``RecoveryAction/connectWithoutVerifying``).
    case identityUnverifiable(detail: String)
    /// The session would not be encrypted where it must be: the server is a Mac (which always
    /// encrypts) or this address's sessions were encrypted before
    /// (``SessionOptions/requiresEncryption``). Something may be stripping the encryption, so nothing
    /// more was sent and no unencrypted fallback is tried. Deliberately not overridable: to accept
    /// the change, add the computer again.
    case notEncrypted(detail: String)
    case cancelled

    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .unreachable:
            [.retry, .editConnection, .showHelp(topic: .enableScreenSharing)]
        case .timedOut:
            [.retry, .editConnection]
        case .authenticationFailed:
            [.editCredentials, .retry]
        case .permissionDenied:
            [.editCredentials, .showHelp(topic: .enableScreenSharing)]
        case .hostKeyRejected:
            [.retry, .editConnection]
        case .localNetworkDenied:
            [.openSystemSettings, .showHelp(topic: .localNetworkPermission)]
        case .tunnelFailed:
            [.retry, .editConnection, .connectWithoutTunnel, .showHelp(topic: .enableRemoteLogin)]
        case .unsupportedServer, .otherProtocol:
            [.editConnection]
        case .modeUnavailable(let mode, _):
            mode == .highPerformance
                ? [.connectWithStandardMode, .showHelp(topic: .highPerformanceRequirements)]
                : [.editConnection]
        case .busy:
            [.retry, .connectWithStandardMode]
        case .protocolViolation:
            [.retry]
        case .serverNotAuthenticated:
            [.editConnection]
        case .identityUnverifiable:
            [.retry, .editConnection, .connectWithoutVerifying]
        case .notEncrypted:
            [.retry, .editConnection]
        case .cancelled:
            []
        }
    }
}

/// Why an established session ended.
public enum DisconnectReason: Sendable, Hashable {
    case userInitiated
    /// The remote machine closed the session (logout, shutdown, remote user ended sharing).
    case remoteClosed(detail: String?)
    /// The network dropped. Reconnecting may succeed.
    case connectionLost(detail: String)
    /// Media stopped arriving and could not be recovered.
    case mediaStalled(MediaStallCause)
    case protocolViolation(detail: String)

    /// Whether an automatic reconnect is worth attempting.
    public var isRecoverable: Bool {
        switch self {
        case .connectionLost, .mediaStalled: true
        case .userInitiated, .remoteClosed, .protocolViolation: false
        }
    }
}

/// How a media path failed, which decides what a reconnect should try.
public enum MediaStallCause: Sendable, Hashable {
    /// Nothing arrived at all: the path is gone (a network change, a firewall, a sleeping access
    /// point). The same mode may work again once the network is back.
    case silent
    /// Packets kept arriving but pictures could not be repaired: the path is too lossy for this
    /// mode, so a lighter one should be tried.
    case lossy
}

/// Why a capability or mode is not offered. Front ends show this next to the disabled control.
public enum UnavailableReason: Sendable, Hashable {
    case notSupportedByBackend
    /// The remote machine does not offer it (older system, feature switched off).
    case notSupportedByServer
    /// Not possible through an SSH tunnel.
    case tunnelled
    /// Only exists in another session mode.
    case requiresMode(SessionMode)
    /// The account lacks the privilege.
    case notPermitted
    /// This device cannot do it (for example, no suitable video decoder).
    case notSupportedByDevice
    /// Needs something the user has not configured (for example SSH for file transfer).
    case notConfigured(detail: String)
    /// The network between the two machines loses too much data for it. Media that travels as
    /// datagrams cannot start when its first picture never arrives whole.
    case unreliableNetwork
    /// The media never arrived at all: something between the two machines (a firewall, a NAT, a
    /// VPN that carries TCP only) blocks the datagrams it travels in.
    case mediaBlocked
    /// The remote machine's screen is locked or at its login window; it is possible once someone
    /// unlocks it.
    case remoteScreenLocked
}
