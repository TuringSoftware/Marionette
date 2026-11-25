// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import RemoteDesktopCore
import Testing

@Suite struct X11KeysymTests {
    @Test(arguments: [
        ("a", [0x61]),
        ("é", [0xe9]),
        // A letter and a combining accent, as some input methods and pastes deliver it: composed.
        ("e\u{301}", [0xe9]),
        ("€", [0x0100_20ac]),
        // Characters of several scalars go one scalar at a time.
        ("❤️", [0x0100_2764, 0x0100_fe0f]),
        ("👍🏽", [0x0101_f44d, 0x0101_f3fd]),
        ("🇫🇷", [0x0101_f1eb, 0x0101_f1f7]),
        ("👩‍💻", [0x0101_f469, 0x0100_200d, 0x0101_f4bb]),
        // A letter with an accent that has no composed form keeps its accent as a second keysym.
        ("q\u{301}", [0x71, 0x0100_0301]),
        ("\n", [0xff0d]),
        ("\r\n", [0xff0d]),
        ("\t", [0xff09]),
        ("\u{1}", []),
    ] as [(Character, [UInt32])])
    func charactersBecomeKeysyms(character: Character, keysyms: [UInt32]) {
        #expect(X11Keysym.keysyms(for: character) == keysyms)
        #expect(X11Keysym.forCharacter(character) == (keysyms.count == 1 ? keysyms.first : nil))
    }

    /// A Mac's server takes a Unicode keysym as one UTF-16 code unit.
    @Test func aMacGetsCharactersBeyondTheBasicPlaneAsSurrogates() {
        #expect(X11Keysym.keysyms(for: "👍🏽", style: .mac) == [0x0100_d83d, 0x0100_dc4d, 0x0100_d83c, 0x0100_dffd])
        #expect(X11Keysym.keysyms(for: "❤️", style: .mac) == [0x0100_2764, 0x0100_fe0f])
        #expect(X11Keysym.keysyms(for: "é", style: .mac) == [0xe9])
        #expect(X11Keysym.forCharacter("😀", style: .mac) == nil)
        #expect(X11Keysym.forCharacter("😀") == 0x0101_f600)
    }

    @Test(arguments: [
        (KeyCode.printScreen, 0xff61),
        (.scrollLock, 0xff14),
        (.pause, 0xff13),
        (.application, 0xff67),
        (.f13, 0xffca),
        (.f20, 0xffd1),
        (KeyCode(rawValue: 0x70), 0xffd2),
        (KeyCode(rawValue: 0x73), 0xffd5),
    ] as [(KeyCode, UInt32)])
    func keysWithoutCharactersHaveKeysyms(key: KeyCode, keysym: UInt32) {
        #expect(X11Keysym.forKey(key) == keysym)
    }

    @Test func pastF24IsNothing() {
        #expect(X11Keysym.forKey(KeyCode(rawValue: 0x74)) == nil)
    }
}
