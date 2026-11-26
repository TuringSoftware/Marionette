// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
import ARDTestSupport
import Foundation
import Testing

/// Touch screen reports and the message that carries them. The reports are byte for byte what
/// UniversalHID's own `DigitizerReport` (macOS 27) builds for the same fingers; the message is the
/// one a macOS 27.3 virtual machine acted on, opening the Apple menu under the finger.
@Suite struct DigitizerReportTests {
    private static func zeros(_ count: Int) -> String { String(repeating: "00", count: count) }

    @Test func twoFingersAreTwoSlotsOfIdentifierStateAndPosition() throws {
        let report = DigitizerReport(contacts: [
            .init(identifier: 1, isTouching: true, x: DigitizerReport.Contact.scaled(0.5), y: DigitizerReport.Contact.scaled(0.25)),
            .init(identifier: 2, isTouching: true, x: DigitizerReport.Contact.scaled(0.75), y: DigitizerReport.Contact.scaled(0.75)),
        ])
        let expected = "090205" + "c1ff7fff3f" + "c2ffbfffbf" + Self.zeros(45)
        #expect(report.data.hex == expected)
        #expect(try DigitizerReport.parse(report.data) == report)
    }

    @Test func aLiftedFingerIsNeitherTouchingNorInRange() {
        let report = DigitizerReport(contacts: [.init(identifier: 3, isTouching: false, x: 0x1234, y: 0x5678)])
        #expect(report.data.hex == "090105" + "0334127856" + Self.zeros(50))
    }

    @Test func aCancelledFingerSetsItsSlotsBitInTheSeventhGroup() throws {
        // UniversalHID's setContactCancel(true, atIndex: 0) sets bit 6 of byte 56; index 2, bit 0 of byte 57.
        let first = DigitizerReport(contacts: [.init(identifier: 0, isTouching: false, isCancelled: true, x: 0, y: 0)])
        #expect(first.data.hex == "090105" + Self.zeros(53) + "40" + "00")
        let third = DigitizerReport(contacts: [
            .init(identifier: 0, isTouching: true, x: 0, y: 0),
            .init(identifier: 1, isTouching: true, x: 0, y: 0),
            .init(identifier: 4, isTouching: false, isCancelled: true, x: 0, y: 0),
        ])
        #expect(third.data.suffix(2).hex == "0001")
        #expect(try DigitizerReport.parse(third.data) == third)
    }

    @Test func positionsScaleAcrossTheWholeRangeAndClamp() {
        #expect(DigitizerReport.Contact.scaled(0) == 0)
        #expect(DigitizerReport.Contact.scaled(1) == 65535)
        #expect(DigitizerReport.Contact.scaled(0.999999) == 0xfffe)
        #expect(DigitizerReport.Contact.scaled(-3) == 0)
        #expect(DigitizerReport.Contact.scaled(7) == 65535)
        #expect(DigitizerReport.Contact.scaled(.nan) == 0)
    }

    @Test func noMoreThanFiveFingersGoIntoAReport() throws {
        let six = (0..<6).map { DigitizerReport.Contact(identifier: UInt8($0), isTouching: true, x: 0, y: 0) }
        let parsed = try DigitizerReport.parse(DigitizerReport(contacts: six).data)
        #expect(parsed.contacts.map(\.identifier) == [0, 1, 2, 3, 4])
    }

    @Test func malformedReportsAreRefused() {
        #expect(throws: WireError.self) { try DigitizerReport.parse(Data([9, 0, 5])) }
        var wrongID = DigitizerReport(contacts: []).data
        wrongID[0] = 8
        #expect(throws: WireError.self) { try DigitizerReport.parse(wrongID) }
        var tooMany = DigitizerReport(contacts: []).data
        tooMany[1] = 6
        #expect(throws: WireError.self) { try DigitizerReport.parse(tooMany) }
    }

    @Test func theMessageIsLittleEndianWithTheDisplayAndTheReportsLength() {
        let tap = DigitizerReport(contacts: [.init(identifier: 1, isTouching: true, x: 0x03bc, y: 0x01d1)])
        let message = ClientMessage.hidReport(display: 1, report: tap.data)
        #expect(message.count == 78)
        #expect(message.hex == "2600" + "4a00" + "0100" + Self.zeros(8) + "01000000" + "3a00" + "090105c1bc03d101" + Self.zeros(50))
        #expect(ClientMessage.hidReport(display: 0x0403_0201, report: Data([9])).hex == "2600" + "1100" + "0100" + Self.zeros(8) + "01020304" + "0100" + "09")
    }
}
