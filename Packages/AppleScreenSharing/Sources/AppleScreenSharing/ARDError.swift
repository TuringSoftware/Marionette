// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ARDCrypto
import ARDProtocol
public import RemoteDesktopCore

/// Why a connection to a Mac failed or ended.
public enum ARDError: Error, Sendable, Equatable {
    case transport(TransportError)
    case closedByPeer
    /// The Mac refused the connection before any login, with its reason.
    case refused(reason: String)
    /// The login was rejected. A Mac gives no reason, and answers the same way for a wrong password
    /// and for an account without screen sharing permission.
    case authenticationFailed
    /// The name or password is longer than the login type can carry.
    case credentialTooLong
    /// The login went through but whatever answered could not prove it is the Mac: it does not
    /// hold the account's SRP verifier. Possibly a machine in the middle.
    case serverNotAuthenticated
    /// The session would not be encrypted where it must be: a Mac that says it will not encrypt
    /// (a Mac always does), or any server when ``ARDConnection/Configuration/requiresEncryption``
    /// is set. Nothing beyond the login was sent.
    case notEncrypted(String)
    /// The server is not something this client can talk to.
    case unsupported(String)
    /// The server is not speaking Apple's protocol at all (another RFB version): nothing was sent.
    case otherProtocol(String)
    /// The Mac sent something that breaks the protocol.
    case protocolViolation(String)
    case cancelled

    static let serverNotAuthenticatedExplanation =
        String(localized: "The computer accepted the password but could not prove it is the Mac it claims to be. It may not be the computer you meant to reach.", bundle: #bundle)

    init(_ error: WireError) {
        switch error {
        case .truncated: self = .closedByPeer
        case .malformed(let detail): self = .protocolViolation(detail)
        }
    }

    init(_ error: any Error) {
        switch error {
        case let error as ARDError: self = error
        case let error as TransportError: self = error == .closed ? .closedByPeer : .transport(error)
        case let error as WireError: self.init(error)
        case let error as RecordError: self = .protocolViolation("record layer: \(error)")
        case let error as CryptoError: self = .protocolViolation("cryptography: \(error)")
        case let error as CompressionError: self = .protocolViolation("compression: \(error)")
        case is CancellationError: self = .cancelled
        default: self = .transport(.other(detail: String(describing: error)))
        }
    }
}
