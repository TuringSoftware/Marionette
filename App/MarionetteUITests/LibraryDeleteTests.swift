// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Deleting a saved computer from its context menu asks first, next to that computer.
final class LibraryDeleteTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Where the question shows as a popover (iPad, an open Duo), it points at the saved computer
    /// being deleted, not at a card under On This Network.
    @MainActor
    func testTheDeleteQuestionAppearsAtTheComputerBeingDeleted() throws {
        let app = XCUIApplication.marionette()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'computer-'")).firstMatch.waitToExist()
        let nearby = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'discovered-'"))
        XCTAssertTrue(nearby.firstMatch.waitForExistence(timeout: 10), "the scenario should show computers nearby")
        saved.press(forDuration: 1.0)
        app.buttons["Delete"].waitToExist().tap()
        app.buttons["Delete Computer"].waitToExist()
        // The popover is the window-sized element holding the question's title.
        let confirm = app.otherElements.containing(NSPredicate(format: "elementType == %d AND label BEGINSWITH 'Delete “'", XCUIElement.ElementType.staticText.rawValue)).allElementsBoundByIndex
            .filter { $0.frame.width < app.windows.firstMatch.frame.width / 2 }.min { $0.frame.width < $1.frame.width } ?? app.buttons["Delete Computer"]
        // The gap between two frames' edges; 0 where they touch or overlap. A popover's arrow
        // touches what it points at.
        func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
            hypot(max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX)), max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY)))
        }
        let toSaved = distance(confirm.frame, saved.frame)
        let toNearby = nearby.allElementsBoundByIndex.map { distance(confirm.frame, $0.frame) }.min() ?? .infinity
        print("DELETE QUESTION at \(confirm.frame); saved card \(saved.frame), \(toSaved) away; nearest card nearby \(toNearby) away")
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertLessThan(toSaved, toNearby, "the question should be at the computer being deleted")
        }
        // A popover has no Cancel: a tap elsewhere closes it, and nothing is deleted.
        let identifier = saved.identifier
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap() }
        XCTAssertTrue(app.buttons["Delete Computer"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[identifier].exists, "closing the question deletes nothing")
    }
}
