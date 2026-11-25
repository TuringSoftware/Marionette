// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
public import RemoteDesktopCore

// Words for the contract's types. They live here rather than in a view so that every front end says
// the same thing.

extension SessionMode {
    public var title: String {
        switch self {
        case .highPerformance: String(localized: "High Performance", bundle: #bundle)
        case .standard: String(localized: "Standard", bundle: #bundle)
        }
    }

    /// A compact form for badges.
    public var badgeTitle: String {
        switch self {
        case .highPerformance: String(localized: "High Performance", bundle: #bundle)
        case .standard: String(localized: "Standard", bundle: #bundle)
        }
    }
}

extension ComputerConfiguration.Mode {
    public var title: String {
        switch self {
        case .automatic: String(localized: "Automatic", bundle: #bundle)
        case .highPerformance: String(localized: "High Performance", bundle: #bundle)
        case .standard: String(localized: "Standard", bundle: #bundle)
        }
    }
}

extension ConnectionPhase {
    /// Ordinal used for progress display.
    public var order: Int {
        switch self {
        case .openingTunnel: 0
        case .reachingHost: 1
        case .negotiating: 2
        case .authenticating: 3
        case .waitingForRemoteUser: 4
        case .preparingDisplays: 5
        case .startingMedia: 6
        }
    }

    public var title: String {
        switch self {
        case .openingTunnel: String(localized: "Opening SSH tunnel…", bundle: #bundle)
        case .reachingHost: String(localized: "Contacting computer…", bundle: #bundle)
        case .negotiating: String(localized: "Negotiating…", bundle: #bundle)
        case .authenticating: String(localized: "Signing in…", bundle: #bundle)
        case .waitingForRemoteUser: String(localized: "Waiting for permission…", bundle: #bundle)
        case .preparingDisplays: String(localized: "Preparing displays…", bundle: #bundle)
        case .startingMedia: String(localized: "Starting video…", bundle: #bundle)
        }
    }
}

extension UnavailableReason {
    /// A sentence fragment that completes "Not available: …" or stands alone under a disabled control.
    public var explanation: String {
        switch self {
        case .notSupportedByBackend: String(localized: "Not supported for this kind of connection.", bundle: #bundle)
        case .notSupportedByServer: String(localized: "The remote computer doesn’t offer this.", bundle: #bundle)
        case .tunnelled: String(localized: "Not available through an SSH tunnel.", bundle: #bundle)
        case .requiresMode(let mode): String(localized: "Only available in \(mode.title) mode.", bundle: #bundle)
        case .notPermitted: String(localized: "Your account on the remote computer isn’t allowed to do this.", bundle: #bundle)
        case .notSupportedByDevice: String(localized: "This device doesn’t support it.", bundle: #bundle)
        case .unreliableNetwork: String(localized: "The network is losing too much data for it.", bundle: #bundle)
        case .mediaBlocked: String(localized: "The video never arrived. A firewall, router or VPN between the two computers may be blocking it.", bundle: #bundle)
        case .notConfigured(let detail): detail
        case .remoteScreenLocked: String(localized: "The remote computer’s screen is locked.", bundle: #bundle)
        }
    }
}

extension ConnectionFailure {
    public var title: String {
        switch self {
        case .unreachable: String(localized: "Can’t Reach Computer", bundle: #bundle)
        case .timedOut: String(localized: "Connection Timed Out", bundle: #bundle)
        case .authenticationFailed: String(localized: "Sign-In Failed", bundle: #bundle)
        case .permissionDenied: String(localized: "Not Allowed", bundle: #bundle)
        case .hostKeyRejected: String(localized: "Host Key Not Trusted", bundle: #bundle)
        case .localNetworkDenied: String(localized: "Local Network Access Is Off", bundle: #bundle)
        case .tunnelFailed: String(localized: "SSH Tunnel Failed", bundle: #bundle)
        case .unsupportedServer, .otherProtocol: String(localized: "Unsupported Computer", bundle: #bundle)
        case .modeUnavailable(let mode, _): String(localized: "\(mode.title) Isn’t Available", bundle: #bundle)
        case .busy: String(localized: "Computer Is Busy", bundle: #bundle)
        case .protocolViolation: String(localized: "Unexpected Response", bundle: #bundle)
        case .serverNotAuthenticated: String(localized: "Computer’s Identity Not Verified", bundle: #bundle)
        case .identityUnverifiable: String(localized: "Computer’s Identity Can’t Be Checked", bundle: #bundle)
        case .notEncrypted: String(localized: "Connection Wouldn’t Be Encrypted", bundle: #bundle)
        case .cancelled: String(localized: "Cancelled", bundle: #bundle)
        }
    }

    public var message: String {
        switch self {
        case .unreachable(let host, let detail):
            String(localized: "“\(host)” didn’t respond. Check that it’s awake, on the network, and has Screen Sharing turned on.\(Self.suffix(detail))", bundle: #bundle)
        case .timedOut(let phase):
            phase.timedOutMessage
        case .authenticationFailed(let detail):
            detail ?? String(localized: "The user name or password is incorrect.", bundle: #bundle)
        case .permissionDenied(let detail):
            detail ?? String(localized: "This account isn’t allowed to share the computer’s screen.", bundle: #bundle)
        case .hostKeyRejected(let host):
            String(localized: "The connection was stopped because the identity of “\(host)” wasn’t trusted.", bundle: #bundle)
        case .localNetworkDenied:
            Self.localNetworkMessage
        case .tunnelFailed(let detail):
            String(localized: "The SSH tunnel couldn’t be set up. \(detail)", bundle: #bundle)
        case .unsupportedServer(let detail), .otherProtocol(let detail):
            detail
        case .modeUnavailable(_, let reason):
            reason.explanation
        case .busy(let detail):
            detail
        case .protocolViolation(let detail):
            String(localized: "The computer sent something Marionette didn’t expect. \(detail)", bundle: #bundle)
        case .serverNotAuthenticated(let detail), .identityUnverifiable(let detail):
            detail
        case .notEncrypted(let detail):
            String(localized: "This connection wouldn’t be encrypted, so Marionette stopped before anything was sent.\(Self.suffix(detail))", bundle: #bundle)
        case .cancelled:
            ""
        }
    }

    public var symbolName: String {
        switch self {
        case .unreachable, .timedOut: "wifi.exclamationmark"
        case .authenticationFailed, .permissionDenied: "person.badge.key"
        case .hostKeyRejected: "exclamationmark.shield"
        case .localNetworkDenied: "network.slash"
        case .tunnelFailed: "lock.trianglebadge.exclamationmark"
        case .unsupportedServer, .otherProtocol, .protocolViolation: "questionmark.app.dashed"
        case .serverNotAuthenticated, .identityUnverifiable: "exclamationmark.shield"
        case .notEncrypted: "lock.trianglebadge.exclamationmark"
        case .modeUnavailable: "bolt.slash"
        case .busy: "person.2.slash"
        case .cancelled: "xmark"
        }
    }

    /// Said wherever the system's local network permission is what stopped a connection.
    public static let localNetworkMessage = String(localized: "Marionette needs local network access. You can turn it on in Settings.", bundle: #bundle)

    private static func suffix(_ detail: String) -> String {
        detail.isEmpty ? "" : " (\(detail))"
    }
}

extension ConnectionPhase {
    /// A whole sentence for each phase: a sentence put together from parts cannot be translated.
    fileprivate var timedOutMessage: String {
        switch self {
        case .openingTunnel: String(localized: "The computer stopped responding while opening the SSH tunnel.", bundle: #bundle)
        case .reachingHost: String(localized: "The computer stopped responding while being contacted.", bundle: #bundle)
        case .negotiating: String(localized: "The computer stopped responding while negotiating.", bundle: #bundle)
        case .authenticating: String(localized: "The computer stopped responding while signing in.", bundle: #bundle)
        case .waitingForRemoteUser: String(localized: "The computer stopped responding while waiting for permission.", bundle: #bundle)
        case .preparingDisplays: String(localized: "The computer stopped responding while preparing its displays.", bundle: #bundle)
        case .startingMedia: String(localized: "The computer stopped responding while starting video.", bundle: #bundle)
        }
    }
}

extension RecoveryAction {
    public var title: String {
        switch self {
        case .retry: String(localized: "Try Again", bundle: #bundle)
        case .editCredentials: String(localized: "Enter Password Again", bundle: #bundle)
        case .editConnection: String(localized: "Edit Computer", bundle: #bundle)
        case .openSystemSettings: String(localized: "Open Settings", bundle: #bundle)
        case .connectWithStandardMode: String(localized: "Connect in Standard Mode", bundle: #bundle)
        case .connectWithoutTunnel: String(localized: "Connect Without SSH Tunnel", bundle: #bundle)
        case .connectWithoutVerifying: String(localized: "Connect Anyway", bundle: #bundle)
        case .showHelp(let topic): topic.title
        }
    }

    public var symbolName: String {
        switch self {
        case .retry: "arrow.clockwise"
        case .editCredentials: "key"
        case .editConnection: "pencil"
        case .openSystemSettings: "gear"
        case .connectWithStandardMode: "display"
        case .connectWithoutTunnel: "lock.open"
        case .connectWithoutVerifying: "exclamationmark.shield"
        case .showHelp: "questionmark.circle"
        }
    }
}

extension HelpTopic {
    public var title: String {
        switch self {
        case .enableScreenSharing: String(localized: "How to Turn On Screen Sharing", bundle: #bundle)
        case .enableRemoteLogin: String(localized: "How to Turn On Remote Login", bundle: #bundle)
        case .localNetworkPermission: String(localized: "About Local Network Access", bundle: #bundle)
        case .highPerformanceRequirements: String(localized: "About High Performance Mode", bundle: #bundle)
        case .draggingFiles: String(localized: "About Dragging Files", bundle: #bundle)
        }
    }

    /// Short steps, one per element.
    public var steps: [String] {
        switch self {
        case .enableScreenSharing:
            [
                String(localized: "On the Mac, open System Settings and choose General, then Sharing.", bundle: #bundle),
                String(localized: "Turn on Screen Sharing.", bundle: #bundle),
                String(localized: "Select the info button next to it to choose who may connect.", bundle: #bundle),
                String(localized: "Use the Mac’s name or address shown there when you add it in Marionette.", bundle: #bundle),
            ]
        case .enableRemoteLogin:
            [
                String(localized: "On the Mac, open System Settings and choose General, then Sharing.", bundle: #bundle),
                String(localized: "Turn on Remote Login.", bundle: #bundle),
                String(localized: "Make sure your account is allowed to sign in.", bundle: #bundle),
            ]
        case .localNetworkPermission:
            [
                String(localized: "Open the Settings app on this device.", bundle: #bundle),
                String(localized: "Choose Privacy & Security, then Local Network.", bundle: #bundle),
                String(localized: "Turn on Marionette.", bundle: #bundle),
            ]
        case .highPerformanceRequirements:
            [
                String(localized: "Both devices need to reach each other directly, on the same network or over a VPN.", bundle: #bundle),
                String(localized: "The Mac needs Apple Silicon and a recent version of macOS.", bundle: #bundle),
                String(localized: "It can’t run through an SSH tunnel.", bundle: #bundle),
                String(localized: "Only one viewer can use it at a time.", bundle: #bundle),
            ]
        case .draggingFiles:
            [
                String(localized: "To send files, drag them from another app and drop them into a folder, a Finder window or the desktop in the remote session.", bundle: #bundle),
                String(localized: "To receive files, start dragging them on the Mac and drop them onto the box that appears on the top of the screen.", bundle: #bundle),
                String(localized: "Received files are saved to Marionette’s folder in the Files app.", bundle: #bundle),
            ]
        }
    }
}

extension DisconnectReason {
    public var title: String {
        switch self {
        case .userInitiated: String(localized: "Disconnected", bundle: #bundle)
        case .remoteClosed: String(localized: "The Remote Computer Ended the Session", bundle: #bundle)
        case .connectionLost: String(localized: "Connection Lost", bundle: #bundle)
        case .mediaStalled: String(localized: "Video Stopped", bundle: #bundle)
        case .protocolViolation: String(localized: "Unexpected Response", bundle: #bundle)
        }
    }

    public var message: String {
        switch self {
        case .userInitiated: ""
        case .remoteClosed(let detail): detail ?? String(localized: "Someone at the computer ended screen sharing, or it logged out or shut down.", bundle: #bundle)
        case .connectionLost(let detail): detail.isEmpty ? String(localized: "The network connection to the computer was interrupted.", bundle: #bundle) : detail
        case .mediaStalled: String(localized: "Video from the computer stopped arriving and couldn’t be restarted.", bundle: #bundle)
        case .protocolViolation(let detail): String(localized: "The computer sent something Marionette didn’t expect. \(detail)", bundle: #bundle)
        }
    }
}

extension RemoteAction {
    public var title: String {
        switch self {
        case .missionControl: String(localized: "Mission Control", bundle: #bundle)
        case .appExpose: String(localized: "App Exposé", bundle: #bundle)
        case .launchpad: String(localized: "Launchpad", bundle: #bundle)
        case .showDesktop: String(localized: "Show Desktop", bundle: #bundle)
        case .lockScreen: String(localized: "Lock Screen", bundle: #bundle)
        }
    }

    public var symbolName: String {
        switch self {
        case .missionControl: "rectangle.3.group"
        case .appExpose: "rectangle.on.rectangle"
        case .launchpad: "square.grid.3x3"
        case .showDesktop: "menubar.dock.rectangle"
        case .lockScreen: "lock"
        }
    }
}

extension SessionChoice {
    public var title: String {
        switch self {
        case .askToShareConsole: String(localized: "Ask to Share the Display", bundle: #bundle)
        case .logInAsSelf: String(localized: "Log In as Yourself", bundle: #bundle)
        }
    }

    public func explanation(consoleUser: String) -> String {
        switch self {
        case .askToShareConsole: String(localized: "\(consoleUser) sees a request and can let you view and control what’s on screen.", bundle: #bundle)
        case .logInAsSelf: String(localized: "Use the computer in your own session.", bundle: #bundle)
        }
    }
}
