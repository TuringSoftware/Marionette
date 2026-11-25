// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

@testable import ARDProtocol
import Foundation
import Testing

/// Session select, byte for byte as captured between Screen Sharing.app and macOS 27.0.1 (the
/// viewer's computer name replaced by "Viewer").
struct SessionSelectTests {
    static func name(_ text: String) -> [UInt8] {
        Array(text.utf8) + [UInt8](repeating: 0, count: 64 - text.utf8.count)
    }

    /// The Mac's offer: console user "Alex", commands 0 and 2.
    static let offer: [UInt8] = [0x00, 0x4a, 0x00, 0x01, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x00] + name("Alex")
    static let askAnswer: [UInt8] = [0x00, 0x48, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] + name("Viewer")
    static let accepted: [UInt8] = [0x00, 0x50, 0x00, 0x01, 0x00, 0x00] + [UInt8](repeating: 0, count: 76)
    static let declined: [UInt8] = [0x00, 0x50, 0x00, 0x01, 0x01, 0x00] + offer

    @Test func theMacsOfferNamesTheConsoleUserAndWhatItTakes() throws {
        var reader = WireReader(Data(Self.offer))
        let offer = try SessionSelectOffer.parse(&reader)
        #expect(reader.isAtEnd)
        #expect(offer.consoleUser == "Alex")
        #expect(offer.commands.contains(.askConsoleUser) && offer.commands.contains(.logInAsSelf))
        #expect(offer.commands.rawValue == 5)
        #expect(offer.encoded == Data(Self.offer))
    }

    @Test func askingTheConsoleUserIsSeventyFourBytes() {
        #expect(SessionSelectAnswer(command: .askConsoleUser, viewerName: "Viewer").encoded == Data(Self.askAnswer))
    }

    @Test func connectingToTheConsoleIsShapedLikeAsking() throws {
        // Unverified: built as rootshell sends it, since no Mac has offered command 1 to us.
        let encoded = SessionSelectAnswer(command: .connectToConsole, viewerName: "Viewer").encoded
        #expect(Array(encoded) == [0x00, 0x48, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00] + Self.name("Viewer"))
        var reader = WireReader(encoded)
        #expect(try SessionSelectAnswer.parse(&reader).command == .connectToConsole)
        #expect(SessionSelectOffer.Commands(rawValue: 2).contains(.connectToConsole))
    }

    @Test func loggingInCarriesTheSealedCredentials() throws {
        let sealed = Data((0..<128).map { UInt8($0) })
        let encoded = SessionSelectAnswer(command: .logInAsSelf, viewerName: "Viewer", sealedCredentials: sealed).encoded
        #expect(Array(encoded.prefix(10)) == [0x00, 0xc8, 0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00])
        #expect(encoded.count == 202)
        #expect(Array(encoded[10..<74]) == Self.name("Viewer"))
        #expect(encoded.suffix(128) == sealed)
        var reader = WireReader(encoded)
        let parsed = try SessionSelectAnswer.parse(&reader)
        #expect(parsed == SessionSelectAnswer(command: .logInAsSelf, viewerName: "Viewer", sealedCredentials: sealed))
    }

    @Test func verdicts() throws {
        var reader = WireReader(Data(Self.accepted))
        #expect(try SessionSelectResult.parse(&reader) == .accepted)
        #expect(reader.isAtEnd)
        #expect(SessionSelectResult.accepted.encoded == Data(Self.accepted))

        reader = WireReader(Data(Self.declined))
        let declined = try SessionSelectResult.parse(&reader)
        #expect(reader.isAtEnd)
        guard case .declined(let offer) = declined else {
            Issue.record("expected a refusal, got \(declined)")
            return
        }
        #expect(offer.consoleUser == "Alex")
        #expect(SessionSelectResult.declined(offer).encoded == Data(Self.declined))
    }

    @Test func namesAreCutAtACharacterAndAlwaysEndInANul() {
        let long = String(repeating: "é", count: 40) // 80 bytes of UTF-8
        let field = encodeName(long)
        #expect(field.count == 64)
        #expect(field.last == 0)
        #expect(decodeName(field) == String(repeating: "é", count: 31))
        #expect(decodeName(encodeName("Mac’s iPhone")) == "Mac’s iPhone")
    }

    @Test func hostileLengthsAreRefusedOrWaitedFor() throws {
        var reader = WireReader(Data([0xff, 0xff] + [UInt8](repeating: 0, count: 10)))
        #expect(throws: WireError.self) { _ = try SessionSelectOffer.parse(&reader) }
        reader = WireReader(Data([0x00, 0x4a, 0x00, 0x01]))
        #expect(throws: WireError.truncated(needed: 76)) { _ = try SessionSelectOffer.parse(&reader) }
        reader = WireReader(Data([0x00, 0x48, 0x00, 0x01, 0, 0, 0, 0, 9, 0] + Self.name("x")))
        #expect(throws: WireError.self) { _ = try SessionSelectAnswer.parse(&reader) }
        reader = WireReader(Data([0x00, 0x04, 0x00, 0x01, 0x01, 0x00]))
        #expect(try SessionSelectResult.parse(&reader) == .declined(SessionSelectOffer(commands: [], consoleUser: "")))
    }
}
