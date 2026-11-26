// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

extension XCUIApplication {
    /// Launches Marionette in UI-test mode (seeded in-memory library, simulated back end, no animations).
    static func marionette(scenario: String? = nil, autoConnect: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-MarionetteUITestMode"]
        if let scenario { arguments += ["-MarionetteScenario", scenario] }
        if autoConnect { arguments.append("-MarionetteAutoConnect") }
        if let appearance = ProcessInfo.processInfo.environment["MARIONETTE_SCREENSHOT_APPEARANCE"] {
            arguments += ["-MarionetteAppearance", appearance]
        }
        app.launchArguments = arguments + extra
        app.launch()
        return app
    }

    /// An element by accessibility identifier, whatever its type.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    var remoteDisplay: XCUIElement { element("remote-display") }

    /// Answers iOS's "Allow Paste?" if it comes up (the clipboard was set by another app).
    func allowPasteIfAsked() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for allow in [buttons["Allow Paste"], springboard.buttons["Allow Paste"]] where allow.waitForExistence(timeout: 4) {
            allow.tap()
            return
        }
    }

    /// Opens the session's View menu, a submenu of More on the control strip.
    func openViewMenu() {
        showControls()
        buttons["more-menu"].waitToExist().tap()
        buttons["view-menu"].waitToExist().tap()
    }

    /// Shows the other display in a window of its own, from the View menu (iPad).
    func openDisplayWindow() {
        openViewMenu()
        // Items of a submenu lose their accessibility identifiers (iOS 27.0 simulators, both iPad
        // Pro sizes), so this one is found by its title, as the options of the menu's pickers are.
        buttons["Show Other Display in New Window"].waitToExist().tap()
    }

    /// Opens the control strip if it is folded into its handle. The handle fades when the screen
    /// has not been touched for a while; a touch brings it back.
    func showControls() {
        if buttons["collapse-controls"].waitForExistence(timeout: 2) { return }
        let handle = buttons["expand-controls"]
        if !handle.exists || !handle.isHittable { remoteDisplay.tap() }
        handle.waitToExist().tap()
        buttons["collapse-controls"].waitToExist()
    }

    /// Chooses the named state from the keyboard control's menu (press and hold): "Trackpad",
    /// "Mac Keyboard", "System Keyboard" or "Hidden".
    func showInputPanel(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        showControls()
        let control = buttons["input-panel"].waitToExist()
        if (control.value as? String) != title {
            control.press(forDuration: 1.0)
            buttons[title].firstMatch.waitToExist().tap()
            // The strip moves when a panel comes or goes; let it settle before aiming at it again.
            Thread.sleep(forTimeInterval: 0.8)
        }
        XCTAssertEqual(control.value as? String, title, file: file, line: line)
    }

    /// Types a plain "b" at the remote computer and makes sure it arrived. The simulators lose the
    /// first hardware key after a launch (the first ⌘ combination on iOS 26.1, any first key on the
    /// iPhone Duo's iOS 27.1), so the key is pressed again until one gets through. Afterwards the
    /// session has seen exactly one key press.
    func typeFirstHardwareKey(file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<3 {
            typeKey("b", modifierFlags: [])
            if waitForRemoteDisplay(containing: "typed “b”", timeout: 4) { return }
        }
        XCTFail("no hardware key reached the remote display: \(remoteDisplay.value ?? "")", file: file, line: line)
    }

    /// Dismisses iOS's "Save Password?" offer, if it appears after a sign-in form. It covers the app
    /// and takes every touch until answered; whether it appears depends on the simulator's AutoFill
    /// state. It is in the app's hierarchy, or on older systems SpringBoard's.
    func answerSavePasswordPrompt() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let candidates = [buttons["Not Now"], springboard.buttons["Not Now"]]
        guard let notNow = candidates.first(where: { $0.waitForExistence(timeout: 3) }) else { return }
        // The button exists while the sheet is still sliding in, and a tap then is lost (seen on the
        // iPhone 17 simulator, iOS 27): tap until the sheet has gone.
        for _ in 0..<4 where notNow.exists {
            notNow.tap()
            if notNow.waitForNonExistence(timeout: 3) { break }
        }
        // The sheet keeps taking touches until its dismissal has finished.
        Thread.sleep(forTimeInterval: 0.8)
    }

    /// Enters full screen from the title bar's button.
    func enterFullScreen() {
        buttons["enter-full-screen"].waitToExist().tap()
        XCTAssertTrue(buttons["enter-full-screen"].waitForNonExistence(timeout: 5))
    }

    /// Leaves full screen from the control strip.
    func exitFullScreen() {
        showControls()
        buttons["exit-full-screen"].waitToExist().tap()
        buttons["enter-full-screen"].waitToExist()
    }

    /// Waits until the remote display reports the given text in its accessibility value.
    @discardableResult
    func waitForRemoteDisplay(containing text: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: remoteDisplay)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

extension XCUIElement {
    @discardableResult
    func waitToExist(_ timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(waitForExistence(timeout: timeout), "\(self) did not appear", file: file, line: line)
        return self
    }
}
