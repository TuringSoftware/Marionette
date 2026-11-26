// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import XCTest

/// A monitor attached to the simulator. XCUITest cannot attach one, so these skip unless the host
/// does while the test waits (`Scripts/external-display.sh` powers display 2 on about 20 s after
/// the test starts: the simulator does not reliably report a monitor already on at launch).
final class ExternalDisplayTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testViewMenuSwitchesBetweenExternalOnlyAndMirror() throws {
        let app = XCUIApplication.marionette(autoConnect: true, extra: ["-MarionetteScenario", "two-displays"])
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        // On a phone, External Only is where a session starts when a monitor is there.
        guard app.element("external-only-trackpad").waitForExistence(timeout: 45) else {
            throw XCTSkip("no external display attached to this simulator")
        }
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "trackpad mode"))
        XCTAssertFalse(app.buttons["toggle-input-mode"].isEnabled, "the picture is on the monitor: trackpad only")

        app.openViewMenu()
        app.buttons["Both Displays"].waitToExist().tap()
        XCTAssertTrue(app.element("external-only-trackpad").waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "touch mode"), "the user's own input mode comes back")
        XCTAssertTrue(app.buttons["toggle-input-mode"].isEnabled)

        app.openViewMenu()
        app.buttons["Mirror This Device"].waitToExist().tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "touch mode"))

        app.openViewMenu()
        app.buttons["External Display Only"].waitToExist().tap()
        app.element("external-only-trackpad").waitToExist()
    }

    /// iPad: another display of the session in a window of its own (with Stage Manager on an
    /// extended display, windows are the way onto the monitor).
    @MainActor
    func testOtherDisplayInANewWindowOnIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "windows of their own are an iPad feature")
        let app = XCUIApplication.marionette(autoConnect: true, extra: ["-MarionetteScenario", "two-displays"])
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        app.openDisplayWindow()
        app.element("display-window").waitToExist(20)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "display-window"
        shot.lifetime = .keepAlways
        add(shot)
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Screenshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: directory.appending(path: "30-display-window.png"))
    }
}
