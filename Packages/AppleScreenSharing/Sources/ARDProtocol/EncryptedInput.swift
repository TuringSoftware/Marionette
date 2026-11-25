// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation

/// `EncryptedInputEvent` (`0x10`): a key or pointer event as Screen Sharing.app sends every one of
/// them (Docs/protocol/apple-screen-sharing.md, "Apple's viewer and input").
///
///     10 | u8 flags | one AES-128-ECB block under the record layer's key
///
/// The block holds a key event or a pointer event; which one shows in where its `0xff` marker is.
/// Besides hiding input from the record layer's known-plaintext structure, the Mac takes pointer
/// events sent this way as coming from a viewer that may drag files in and out: a drag announced
/// by a viewer whose pointer events are plain is not picked up.
///
/// This file only lays the block out; encrypting it needs the session's key (`ARDCrypto`).
public enum EncryptedInputEvent {
    public static let blockLength = 16

    /// The flag byte this client sends: nothing but the event. The Mac then counts clicks itself,
    /// from the elapsed times and its own double-click setting, and maps a key by its keysym.
    ///
    /// Screen Sharing.app sets bit 0 and puts its own click count in bits 1–3 of a pointer event
    /// (`01` with no button down, `03` while one is, read from screensharingd). On a key event it
    /// sends `03` and fills in its keyboard's type and the key's virtual code, which the Mac then
    /// goes by: with `03` and those fields zero, ⌘Space did nothing on macOS 27.0.1, while `00`
    /// and `01` typed as a plain key event does.
    public static let plainFlags: UInt8 = 0x00

    /// A pointer event's block: six zero bytes, the microseconds since the event before it (what
    /// the Mac times double clicks by), the marker, the button mask (Apple's numbering: bit 0 left, bit 1 right, bit 2 centre), x, y.
    public static func pointerBlock(buttonMask: UInt8, x: UInt16, y: UInt16, elapsedMicroseconds: UInt32) -> Data {
        var writer = WireWriter(capacity: blockLength)
        writer.zeros(6)
        writer.u32(elapsedMicroseconds)
        writer.u8(0xff)
        writer.u8(buttonMask)
        writer.u16(x)
        writer.u16(y)
        return writer.data
    }

    /// A key event's block: the marker, the down flag, the keysym, the microseconds since the
    /// event before it, and six bytes Screen Sharing.app fills with its keyboard's type and the
    /// key's virtual code. Left zero, the Mac maps the keysym through its own layout, as it does
    /// for a plain key event.
    public static func keyBlock(keysym: UInt32, isDown: Bool, elapsedMicroseconds: UInt32) -> Data {
        var writer = WireWriter(capacity: blockLength)
        writer.u8(0xff)
        writer.u8(isDown ? 1 : 0)
        writer.u32(keysym)
        writer.u32(elapsedMicroseconds)
        writer.zeros(6)
        return writer.data
    }

    /// The message around an encrypted block.
    public static func message(flags: UInt8, sealedBlock: Data) -> Data {
        var writer = WireWriter(capacity: 2 + blockLength)
        writer.u8(ClientMessageType.encryptedInputEvent)
        writer.u8(flags)
        writer.bytes(sealedBlock)
        return writer.data
    }

    public enum Event: Sendable, Equatable {
        case pointer(buttonMask: UInt8, x: UInt16, y: UInt16)
        case key(keysym: UInt32, isDown: Bool)
    }

    /// Reads a decrypted block; `nil` when it carries neither marker.
    public static func parse(block: Data) -> Event? {
        guard block.count == blockLength else { return nil }
        let bytes = [UInt8](block)
        if bytes[10] == 0xff, bytes[0] == 0 {
            return .pointer(
                buttonMask: bytes[11], x: UInt16(bytes[12]) << 8 | UInt16(bytes[13]), y: UInt16(bytes[14]) << 8 | UInt16(bytes[15])
            )
        }
        if bytes[0] == 0xff {
            let keysym = bytes[2...5].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return .key(keysym: keysym, isDown: bytes[1] != 0)
        }
        return nil
    }
}
