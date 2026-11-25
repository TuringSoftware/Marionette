// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

/// Not a test: prepares a simulator for testing by hand by adding computers to the live app's
/// library through the editor, and leaves them there. Opt-in, from environment variables passed to
/// the runner (`TEST_RUNNER_` prefix):
///
/// - `MARIONETTE_TEST_HOST`, `MARIONETTE_TEST_USER`, `MARIONETTE_TEST_PASSWORD`: a Mac, added as
///   "Mac VM" with Screen Sharing in Automatic mode;
/// - `MARIONETTE_SETUP_VNC_ADDRESS` (`host:port`) and optionally `MARIONETTE_SETUP_VNC_PASSWORD`: a VNC
///   server, added as "Ubuntu VM" (its protocol is found out on connecting).
///
/// A computer that is already in the library under the same name is left as it is.
final class ManualTestSetup: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testAddComputersForManualTesting() throws {
        let environment = ProcessInfo.processInfo.environment
        let mac = environment["MARIONETTE_TEST_HOST"]
        let vnc = environment["MARIONETTE_SETUP_VNC_ADDRESS"]
        guard mac != nil || vnc != nil else { throw XCTSkip("nothing to add") }
        let app = XCUIApplication()
        app.launch()
        if let mac {
            add(app, name: "Mac VM", address: mac,
                user: environment["MARIONETTE_TEST_USER"], password: environment["MARIONETTE_TEST_PASSWORD"])
        }
        if let vnc {
            add(app, name: "Ubuntu VM", address: vnc,
                user: nil, password: environment["MARIONETTE_SETUP_VNC_PASSWORD"])
        }
        app.terminate()
    }

    @MainActor
    private func add(_ app: XCUIApplication, name: String, address: String, user: String?, password: String?) {
        let card = app.buttons["computer-\(name)"]
        if card.waitForExistence(timeout: 3) {
            print("SETUP \(name) is already in the library")
            return
        }
        app.buttons["Add Computer"].firstMatch.waitToExist().tap()
        let field = app.textFields["address"].waitToExist()
        field.tap()
        field.typeText(address)
        let nameField = app.textFields["name"]
        nameField.tap()
        nameField.typeText(name)
        if let user, !user.isEmpty {
            let username = app.textFields["username"]
            username.tap()
            username.typeText(user)
        }
        if let password, !password.isEmpty {
            let secret = app.secureTextFields["password"]
            secret.tap()
            secret.typeText(password)
        }
        app.buttons["Add"].tap()
        // iOS offers to save a password it saw typed (on iOS 27 simulators too); the offer takes
        // the next tap.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for notNow in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where notNow.waitForExistence(timeout: 4) {
            notNow.tap()
            break
        }
        if app.buttons["Add"].exists { app.buttons["Add"].tap() }
        card.waitToExist()
        print("SETUP added \(name)")
    }
}
