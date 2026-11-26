// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

public import Foundation

/// A touch screen's input report, as a Mac takes it in a ``ClientMessage/hidReport(display:report:)``.
///
/// For each display a Mac (macOS 27.3 and later) keeps a virtual touch screen that reads this
/// report: UniversalHID's digitizer report, ID 9, up to five fingers. Each report lists every finger
/// on the display at that moment, each in a slot of its own; a finger that lifts is listed once more,
/// neither touching nor in range, and then left out.
///
/// The layout, from the report descriptor UniversalHID gives it (all fields little-endian):
///
/// | Bytes | Field |
/// |---|---|
/// | 0 | Report ID, 9 |
/// | 1 | Contact count: slots in use |
/// | 2 | Contact count maximum, 5 |
/// | 3–27 | Five slots of 5 bytes: bits 0–4 the contact identifier (0–4), bit 5 resting, bit 6 touching, bit 7 in range; `u16` x and y over the display, 0–65535 |
/// | 28–39 | Scroll fields, unused here |
/// | 40–44 | One byte per slot (vendor usage 0xE0F4), unused here |
/// | 45–52 | `u64` remote timestamp, unused here |
/// | 53–57 | Seven groups of five bits, one bit per slot: swipe pending, swipe locked, swipe up, down, left, right, and cancelled; then five bits of padding |
public struct DigitizerReport: Sendable, Hashable {
    public struct Contact: Sendable, Hashable {
        /// 0 ..< ``DigitizerReport/maximumContacts``, the same from landing to lifting.
        public var identifier: UInt8
        public var isTouching: Bool
        public var isInRange: Bool
        /// The finger was taken away rather than lifted (the report's cancel bit for its slot).
        public var isCancelled: Bool
        /// Across the display, 0 at the left edge to 65535 at the right.
        public var x: UInt16
        /// Down the display, 0 at the top edge to 65535 at the bottom.
        public var y: UInt16

        public init(identifier: UInt8, isTouching: Bool, isInRange: Bool? = nil, isCancelled: Bool = false, x: UInt16, y: UInt16) {
            self.identifier = identifier
            self.isTouching = isTouching
            self.isInRange = isInRange ?? isTouching
            self.isCancelled = isCancelled
            self.x = x
            self.y = y
        }

        /// A position as a fraction of the display's width and height, each clamped to 0…1.
        public static func scaled(_ fraction: Double) -> UInt16 {
            guard fraction.isFinite else { return 0 }
            return UInt16((min(max(fraction, 0), 1) * 65535).rounded(.down))
        }
    }

    public static let reportID: UInt8 = 9
    public static let maximumContacts = 5
    public static let byteCount = 58

    private static let contactsOffset = 3
    private static let contactLength = 5
    /// Where the bit groups start, in bits: the cancel group is the seventh.
    private static let cancelBitOffset = 53 * 8 + 6 * maximumContacts

    /// In slot order; at most ``maximumContacts``.
    public var contacts: [Contact]

    public init(contacts: [Contact]) {
        self.contacts = contacts
    }

    public var data: Data {
        var bytes = [UInt8](repeating: 0, count: Self.byteCount)
        bytes[0] = Self.reportID
        let slots = contacts.prefix(Self.maximumContacts)
        bytes[1] = UInt8(slots.count)
        bytes[2] = UInt8(Self.maximumContacts)
        for (slot, contact) in slots.enumerated() {
            let offset = Self.contactsOffset + slot * Self.contactLength
            bytes[offset] = contact.identifier & 0x1f | (contact.isTouching ? 0x40 : 0) | (contact.isInRange ? 0x80 : 0)
            bytes[offset + 1] = UInt8(contact.x & 0xff)
            bytes[offset + 2] = UInt8(contact.x >> 8)
            bytes[offset + 3] = UInt8(contact.y & 0xff)
            bytes[offset + 4] = UInt8(contact.y >> 8)
            if contact.isCancelled {
                let bit = Self.cancelBitOffset + slot
                bytes[bit / 8] |= 1 << (bit % 8)
            }
        }
        return Data(bytes)
    }

    /// Reads a report as a Mac would; for tests and stand-ins for a Mac.
    public static func parse(_ data: Data) throws(WireError) -> DigitizerReport {
        let bytes = [UInt8](data)
        guard bytes.count == byteCount, bytes[0] == reportID else {
            throw .malformed("a digitizer report of \(bytes.count) bytes, ID \(bytes.first ?? 0)")
        }
        let count = Int(bytes[1])
        guard count <= maximumContacts else { throw .malformed("a digitizer report with \(count) contacts") }
        let contacts = (0..<count).map { slot in
            let offset = contactsOffset + slot * contactLength
            let bit = cancelBitOffset + slot
            return Contact(
                identifier: bytes[offset] & 0x1f,
                isTouching: bytes[offset] & 0x40 != 0,
                isInRange: bytes[offset] & 0x80 != 0,
                isCancelled: bytes[bit / 8] >> (bit % 8) & 1 != 0,
                x: UInt16(bytes[offset + 1]) | UInt16(bytes[offset + 2]) << 8,
                y: UInt16(bytes[offset + 3]) | UInt16(bytes[offset + 4]) << 8
            )
        }
        return DigitizerReport(contacts: contacts)
    }
}
