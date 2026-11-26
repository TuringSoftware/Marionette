// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import StoreKitTest
import XCTest

/// The Support Us sheet and the tip that asks for a donation after ten sessions.
final class SupportTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// A store with the donation for sale and nothing bought, emptied again when the test ends:
    /// the simulator keeps what a test buys, and an app that finds the donation made never shows
    /// the tip.
    private func makeStore() throws -> SKTestSession {
        let store = try SKTestSession(configurationFileNamed: "Donations")
        store.disableDialogs = true
        store.clearTransactions()
        addTeardownBlock { store.clearTransactions() }
        return store
    }

    /// The tip's buttons are found by their titles: TipKit gives everything inside a tip its own
    /// identifier, over any set there.
    @MainActor
    private func tipButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.element("support-tip").buttons[title]
    }

    /// One session with the first computer of the library, ended from its title bar.
    @MainActor
    private func holdSession(_ app: XCUIApplication) {
        app.buttons["computer-Studio Mac"].waitToExist().tap()
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        app.buttons["close-session"].tap()
        app.buttons["computer-Studio Mac"].waitToExist()
    }

    /// Opens the sheet from the library's toolbar, which a narrow bar keeps in its More menu.
    @MainActor
    private func openSupportUs(_ app: XCUIApplication) {
        app.buttons["computer-Studio Mac"].waitToExist()
        if !app.buttons["Support Us"].exists { app.buttons["More"].firstMatch.tap() }
        app.buttons["Support Us"].waitToExist().tap()
        app.element("support-message").waitToExist()
    }

    @MainActor
    private func closeSupportUs(_ app: XCUIApplication) {
        app.buttons["Done"].tap()
        XCTAssertTrue(app.element("support-message").waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testOpeningSupportUsStartsTheCountAgain() throws {
        _ = try makeStore()
        let app = XCUIApplication.marionette(extra: ["-MarionetteSessionCount", "9"])
        openSupportUs(app)
        closeSupportUs(app)
        holdSession(app)
        XCTAssertFalse(app.element("support-tip").exists, "having looked at the sheet counts as Not Now")
    }

    @MainActor
    func testADonationIsThankedAndEndsTheTipBeforeItEverShows() throws {
        let store = try makeStore()
        // Five sessions behind it, so that the review has been asked for: the system's prompt would
        // otherwise come up over the library after the fifth of the sessions below.
        let app = XCUIApplication.marionette(extra: ["-MarionetteSessionCount", "5"])
        openSupportUs(app)
        app.element("donation").waitToExist()
        // StoreKit draws the buy button; the price is the only name it has.
        app.buttons.matching(NSPredicate(format: "label CONTAINS '9.99'")).firstMatch.waitToExist().tap()
        app.element("support-thanks").waitToExist()
        XCTAssertFalse(app.element("donation").exists, "the thanks take the place of the offer")
        XCTAssertEqual(store.allTransactions().map(\.productIdentifier), ["llc.turing.Marionette.one_time_donation"])
        closeSupportUs(app)
        openSupportUs(app)
        XCTAssertTrue(app.element("support-thanks").exists)
        closeSupportUs(app)
        for _ in 0..<10 { holdSession(app) }
        XCTAssertFalse(app.element("support-tip").exists, "someone who has donated is not asked")
    }

    /// As on a new phone, or after installing again: the App Store has the donation, the app has
    /// no memory of it, and enough sessions are behind it for the tip.
    @MainActor
    func testADonationMadeBeforeIsFoundAtLaunchAndKeepsTheTipAway() async throws {
        let store = try makeStore()
        _ = try await store.buyProduct(identifier: "llc.turing.Marionette.one_time_donation")
        let app = XCUIApplication.marionette(extra: ["-MarionetteSessionCount", "10"])
        app.buttons["computer-Studio Mac"].waitToExist()
        // The App Store answers a moment after launch; the sheet has not been opened.
        XCTAssertTrue(app.element("support-tip").waitForNonExistence(timeout: 10), "a donation found at launch ends the tip")
        holdSession(app)
        XCTAssertFalse(app.element("support-tip").exists)
        openSupportUs(app)
        app.element("support-thanks").waitToExist()
        XCTAssertFalse(app.buttons["restore-purchase"].exists, "nothing is left to restore")
    }

    @MainActor
    func testRestoringWithNothingBoughtSaysSo() throws {
        _ = try makeStore()
        let app = XCUIApplication.marionette()
        openSupportUs(app)
        app.buttons["restore-purchase"].waitToExist().tap()
        app.alerts["No Donation Found"].waitToExist().buttons["OK"].tap()
        XCTAssertTrue(app.element("donation").exists)
    }

    @MainActor
    func testTheTipAsksAfterTenSessionsAndAgainTenAfterNotNow() throws {
        _ = try makeStore()
        let app = XCUIApplication.marionette(extra: ["-MarionetteSessionCount", "9"])
        app.buttons["computer-Studio Mac"].waitToExist()
        XCTAssertFalse(app.element("support-tip").exists, "nine sessions are not enough")
        holdSession(app)
        app.element("support-tip").waitToExist()
        tipButton(app, "Not Now").tap()
        XCTAssertTrue(app.element("support-tip").waitForNonExistence(timeout: 5))
        holdSession(app)
        XCTAssertFalse(app.element("support-tip").exists, "the count starts again after Not Now")
    }

    @MainActor
    func testDoNotShowAgainEndsTheTip() throws {
        _ = try makeStore()
        let app = XCUIApplication.marionette(extra: ["-MarionetteSessionCount", "10"])
        app.element("support-tip").waitToExist()
        tipButton(app, "Do Not Show Again").tap()
        XCTAssertTrue(app.element("support-tip").waitForNonExistence(timeout: 5))
        holdSession(app)
        XCTAssertFalse(app.element("support-tip").exists)
    }

    @MainActor
    func testTheTipAndItsButtonOpenTheSheet() throws {
        _ = try makeStore()
        var app = XCUIApplication.marionette(extra: ["-MarionetteSessionCount", "10"])
        tipButton(app, "Support Us").waitToExist().tap()
        app.element("support-message").waitToExist()
        closeSupportUs(app)
        XCTAssertFalse(app.element("support-tip").exists, "opening the sheet answers the tip")
        holdSession(app)
        XCTAssertFalse(app.element("support-tip").exists, "and starts the count again")
        app.terminate()

        app = XCUIApplication.marionette(extra: ["-MarionetteSessionCount", "10"])
        // The words of the tip, above its buttons.
        app.element("support-tip").staticTexts["Enjoying Marionette?"].waitToExist().tap()
        app.element("support-message").waitToExist()
    }
}
