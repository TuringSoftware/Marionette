// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import XCTest

/// The menu the control strip's paste glyph opens when held, and what its password items do.
///
/// The system's password picker is another process's and cannot be driven from here: the field is
/// typed into instead.
final class PasteMenuTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func connect() -> XCUIApplication {
        let app = XCUIApplication.marionette(autoConnect: true)
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        return app
    }

    @MainActor
    func testTheLoginPasswordIsTypedAndNotSentAsAClipboard() {
        let app = connect()
        app.openPasteMenu()
        XCTAssertTrue(app.pasteMenuItem("From Clipboard").waitToExist().exists)
        XCTAssertTrue(app.pasteMenuItem("Password…").isEnabled)
        app.pasteMenuItem("Login Password").tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "1 passwords"), "\(app.remoteDisplay.value ?? "")")
        // The session's own tally does not spell a password out.
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "typed “”"))
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "0 clipboard sends"))
    }

    @MainActor
    func testAPasswordEnteredInTheFieldIsSentWithReturnAndTheKeyboardGoesBack() {
        let app = connect()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "has keyboard focus"))
        app.openPasteMenu()
        app.pasteMenuItem("Password…").waitToExist().tap()
        let field = app.secureTextFields["password-entry-field"].waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "no keyboard focus"))
        XCTAssertFalse(app.buttons["toolbar-paste"].exists, "the field stands in the strip's place")
        field.typeText("hunter2\n")
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "1 passwords"), "\(app.remoteDisplay.value ?? "")")
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "has keyboard focus"))
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "typed “”"), "none of it went to the remote display as keys: \(app.remoteDisplay.value ?? "")")

        app.openPasteMenu()
        app.pasteMenuItem("Password…").waitToExist().tap()
        app.buttons["password-entry-cancel"].waitToExist().tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["toolbar-paste"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "has keyboard focus"))
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "1 passwords"))
    }

    /// The glyph reads the clipboard in the press. On iOS 26.1 such a read, triggered by XCUITest,
    /// can block the app's main thread until the test times out.
    @MainActor
    func testATipPointsAtTheMenuOnceTheGlyphHasPasted() throws {
        guard #available(iOS 27, *) else { throw XCTSkip("the paste glyph cannot be pressed by XCUITest before iOS 27") }
        UIPasteboard.general.items = []
        let app = connect()
        app.waitForTheMacsCopy()
        app.showControls()
        let tip = app.staticTexts["Paste Passwords"]
        XCTAssertFalse(tip.exists)
        app.buttons["toolbar-paste"].waitToExist().tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "1 clipboard sends"), "the paste itself still happens")
        XCTAssertTrue(tip.waitForExistence(timeout: 10))
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "has keyboard focus"), "the tip leaves the keyboard with the remote display")

        // Using the menu is what the tip asks for: it does not come back.
        app.openPasteMenu()
        app.pasteMenuItem("Login Password").waitToExist().tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "1 passwords"))
        XCTAssertTrue(tip.waitForNonExistence(timeout: 5))
    }
}
