// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

@testable import ARDProtocol
import Foundation
import Testing

@Suite struct CurtainTests {
    @Test func raisingCarriesTheNoteAndClearsVisible() {
        #expect(Curtain.message(curtained: true, note: "Hi") == Data([0x0c, 0, 0, 0, 0, 2]) + Data("Hi".utf8))
    }

    @Test func loweringSetsVisibleAndSendsNoNote() {
        #expect(Curtain.message(curtained: false, note: "ignored") == Data([0x0c, 0, 0, 1, 0, 0]))
    }

    @Test func theNoteIsMeasuredInUTF8Bytes() {
        let message = Curtain.message(curtained: true, note: String(repeating: "é", count: 150))
        #expect(message[4] == 0x01)
        #expect(message[5] == 0x2c)
        #expect(message.count == 6 + 300)
    }

    /// Over 512 bytes the Mac closes the connection; a note is cut to fit, between characters.
    @Test func aLongNoteIsCutBetweenCharacters() throws {
        let kana = Curtain.clampedNote(String(repeating: "あ", count: 200))
        #expect(kana.count == 510)
        #expect(try #require(String(data: kana, encoding: .utf8)).count == 170)
        // Eight bytes a flag: 64 fit exactly.
        let flags = Curtain.clampedNote(String(repeating: "🇫🇷", count: 100))
        #expect(flags.count == Curtain.maximumNoteBytes)
        #expect(try #require(String(data: flags, encoding: .utf8)).count == 64)
        #expect(Curtain.message(curtained: true, note: String(repeating: "a", count: 600)).count == 6 + Curtain.maximumNoteBytes)
    }

    /// Flags a Mac sent (macOS 27.0.1) and what they mean.
    @Test(arguments: [
        (UInt32(0x4), DisplayLayout.CurtainState.unavailable(because: [.onConsole])),
        (0x6, .available),
        (0x3, .curtained),
        (0xc, .unavailable(because: [.onConsole, .lockScreen])),
        (0x5, .unavailable(because: [.onConsole, .onVirtualDisplay])),
    ])
    func layoutFlagsTellTheCurtainsState(raw: UInt32, state: DisplayLayout.CurtainState) throws {
        var reader = WireReader(ServerBytes.layout(
            framebuffer: (10, 10), current: nil, flags: raw,
            screens: [.init(id: 1, density: 1, points: (0, 0, 10, 10), pixels: (0, 0, 10, 10))]
        ))
        #expect(try DisplayLayout.parse(&reader).curtainState == state)
    }
}
