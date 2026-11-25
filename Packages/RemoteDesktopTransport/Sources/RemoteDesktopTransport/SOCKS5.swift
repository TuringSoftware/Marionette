// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// Adapted from rootshell-vnc's SOCKS5Proxy.swift (MIT, © 2026 Rootshell LLC, Kit Knox).

import CFNetwork
import Foundation
import Network
import RemoteDesktopCore

/// The SOCKS proxy the system settings route a TCP destination through.
///
/// Network.framework can speak SOCKS for a connection itself, but when the proxy's reply and the
/// server's first bytes arrive together it never passes those bytes on, and a protocol where the
/// server speaks first (RFB, SSH) hangs (macOS 27). So a connection the settings send through a
/// SOCKS proxy asks Network.framework for no proxy, and negotiates with the proxy here.
enum SystemSOCKSProxy {
    /// The proxy for `host:port`, or `nil` for a direct route or one decided by a PAC file, which
    /// Network.framework still evaluates itself.
    static func endpoint(forHost host: String, port: UInt16) -> Endpoint? {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else { return nil }
        return endpoint(forHost: host, port: port, settings: settings)
    }

    static func endpoint(forHost host: String, port: UInt16, settings: CFDictionary) -> Endpoint? {
        guard let url = destinationURL(host: host, port: port) else { return nil }
        // A scheme other than HTTP gets only a SOCKS or a direct entry, with the bypass list already
        // applied; a PAC entry, if any, comes first.
        let proxies = CFNetworkCopyProxiesForURL(url as CFURL, settings).takeRetainedValue() as? [[String: Any]]
        guard let first = proxies?.first,
              first[kCFProxyTypeKey as String] as? String == kCFProxyTypeSOCKS as String,
              let proxyHost = first[kCFProxyHostNameKey as String] as? String, !proxyHost.isEmpty,
              let proxyPort = (first[kCFProxyPortNumberKey as String] as? NSNumber).flatMap({ UInt16(exactly: $0.intValue) }),
              proxyPort != 0
        else { return nil }
        return Endpoint(host: proxyHost, port: proxyPort)
    }

    static func destinationURL(host: String, port: UInt16) -> URL? {
        var literal = SOCKS5.unbracketed(host)
        if literal.contains(":") {
            literal = "[\(literal.replacingOccurrences(of: "%", with: "%25"))]"
        }
        return URL(string: "socks://\(literal):\(port)")
    }
}

/// RFC 1928 CONNECT with no authentication.
enum SOCKS5 {
    enum Failure: Error, Equatable {
        /// The proxy wants a login. Network.framework can use credentials the system saved for it;
        /// this client cannot.
        case authenticationRequired
        case rejected(UInt8)
        case malformed(String)

        var transportError: TransportError {
            switch self {
            case .authenticationRequired: .unreachable(detail: "the SOCKS proxy requires a login")
            case .rejected(let code): .unreachable(detail: "the SOCKS proxy could not connect: \(SOCKS5.replyText(code))")
            case .malformed(let detail): .other(detail: "the SOCKS proxy answered with \(detail)")
            }
        }
    }

    /// What follows the 4-byte reply header.
    enum BoundAddress: Equatable {
        /// This many address and port bytes.
        case fixed(Int)
        /// A length byte, that many name bytes, then the port.
        case domain
    }

    static let methodRequest = Data([0x05, 0x01, 0x00])

    static func checkMethodSelection(_ reply: Data) throws(Failure) {
        let bytes = [UInt8](reply)
        guard bytes.count == 2, bytes[0] == 0x05 else { throw .malformed("method selection \(hex(bytes))") }
        switch bytes[1] {
        case 0x00: return
        case 0xFF: throw .authenticationRequired
        default: throw .malformed("a method it was not offered (\(bytes[1]))")
        }
    }

    /// Address literals go as addresses; names go as names, so that the proxy resolves them.
    static func connectRequest(host: String, port: UInt16) throws(Failure) -> Data {
        var request: [UInt8] = [0x05, 0x01, 0x00]
        let literal = unbracketed(host)
        if let address = IPv4Address(literal) {
            request.append(0x01)
            request += address.rawValue
        } else if let address = IPv6Address(literal) {
            request.append(0x04)
            request += address.rawValue
        } else {
            let name = Array(literal.utf8)
            guard (1...255).contains(name.count) else { throw .malformed("a host name of \(name.count) bytes; SOCKS allows 1–255") }
            request.append(0x03)
            request.append(UInt8(name.count))
            request += name
        }
        request += [UInt8(port >> 8), UInt8(port & 0xFF)]
        return Data(request)
    }

    static func boundAddress(afterReplyHeader header: Data) throws(Failure) -> BoundAddress {
        let bytes = [UInt8](header)
        guard bytes.count == 4, bytes[0] == 0x05 else { throw .malformed("reply header \(hex(bytes))") }
        guard bytes[1] == 0x00 else { throw .rejected(bytes[1]) }
        switch bytes[3] {
        case 0x01: return .fixed(4 + 2)
        case 0x04: return .fixed(16 + 2)
        case 0x03: return .domain
        default: throw .malformed("address type \(bytes[3])")
        }
    }

    static func replyText(_ code: UInt8) -> String {
        switch code {
        case 0x01: "general failure"
        case 0x02: "not allowed by its rules"
        case 0x03: "network unreachable"
        case 0x04: "host unreachable"
        case 0x05: "connection refused"
        case 0x06: "TTL expired"
        case 0x07: "command not supported"
        case 0x08: "address type not supported"
        default: "reply code \(code)"
        }
    }

    static func unbracketed(_ host: String) -> String {
        guard host.first == "[", host.last == "]" else { return host }
        return String(host.dropFirst().dropLast())
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.isEmpty ? "nothing" : bytes.map { String(format: "%02x", $0) }.joined()
    }
}
