// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import XCTest

/// Files dragged on the simulated computer, taken with the drop well.
///
/// The other direction, a drag from another app onto the remote display, needs a second app beside
/// this one and is covered below the interface, in MarionetteKit's tests.
final class FileDragTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testFilesDraggedOnTheComputerAreCopiedByLettingGoOverTheWell() {
        // In this scenario the simulated Mac picks two files up by itself a moment after connecting.
        let app = XCUIApplication.marionette(scenario: "remote-drag", autoConnect: true)
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let well = app.element("remote-drag-well").waitToExist()
        XCTAssertEqual(well.label, "Copy to \(device)")
        XCTAssertEqual(well.value as? String, "2 Items")
        XCTAssertFalse(app.buttons["transfer-indicator"].exists)

        // A long press picks things up in touch mode, and the finger carries the Mac's pointer.
        // Letting go anywhere but on the well leaves the Mac's drag to the Mac.
        let start = app.remoteDisplay.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.6))
        let target = well.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.8, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 1.5)
        XCTAssertTrue(well.waitForNonExistence(timeout: 5))

        app.buttons["transfer-indicator"].waitToExist().tap()
        let saved = NSPredicate(format: "label CONTAINS %@", "Saved to Files")
        for name in ["Holiday.mov", "Readme.txt"] {
            let transfer = app.element("transfer-\(name)").waitToExist()
            XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: saved, object: transfer)], timeout: 30), .completed, name)
        }
        app.buttons["files-drag-help"].waitToExist().tap()
        let help = app.navigationBars["About Dragging Files"].waitToExist()
        help.buttons["Done"].tap()
        XCTAssertTrue(help.waitForNonExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.remoteDisplay.waitForExistence(timeout: 5))
    }
}
