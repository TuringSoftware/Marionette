// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import XCTest

/// End-to-end flows against the simulated back end.
final class SessionFlowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testConnectTypeClickZoomAndDisconnect() {
        let app = XCUIApplication.marionette()
        app.buttons["computer-Studio Mac"].waitToExist().tap()
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))

        app.remoteDisplay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "1 clicks"))

        app.showInputPanel("System Keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        app.typeText("hi")
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "typed “hi”"))
        app.showInputPanel("Hidden")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))

        XCTAssertTrue(app.waitForRemoteDisplay(containing: "touch mode"))
        let before = app.remoteDisplay.value as? String ?? ""
        app.remoteDisplay.pinch(withScale: 2.5, velocity: 2)
        let predicate = NSPredicate(format: "value != %@", before)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: app.remoteDisplay)], timeout: 10), .completed)
        XCTAssertTrue((app.remoteDisplay.value as? String ?? "").contains("1 clicks"), "a pinch must not click")

        app.buttons["toggle-input-mode"].tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "trackpad mode"))

        app.buttons["close-session"].tap()
        app.buttons["computer-Studio Mac"].waitToExist()
    }

    @MainActor
    func testWrongPasswordShowsInlineErrorThenConnects() {
        let app = XCUIApplication.marionette(scenario: "bad-password", autoConnect: true)
        app.element("prompt-error").waitToExist()
        let password = app.secureTextFields["prompt-password"].waitToExist()
        password.tap()
        password.typeText("demo")
        app.buttons["Connect"].tap()
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
    }

    @MainActor
    func testChangedHostKeyOffersCancelAsTheSafeChoice() {
        let app = XCUIApplication.marionette(scenario: "host-key-changed", autoConnect: true)
        app.buttons["Connect Anyway"].waitToExist()
        // No toolbar confirmation button on the warning; stopping is the prominent action.
        XCTAssertFalse(app.buttons["Trust"].exists)
        app.buttons["Cancel Connection"].tap()
        app.element("connection-failure").waitToExist()
        XCTAssertTrue(app.staticTexts["Host Key Not Trusted"].exists)
    }

    @MainActor
    func testFailureOffersRecoveryActions() {
        let app = XCUIApplication.marionette(scenario: "hp-unavailable", autoConnect: true)
        app.buttons["Connect in Standard Mode"].waitToExist().tap()
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "Standard"))
    }

    @MainActor
    func testCancelWhileConnectingReturnsToTheLibrary() {
        let app = XCUIApplication.marionette(scenario: "slow", autoConnect: true)
        app.element("connecting").waitToExist()
        app.buttons["Cancel"].tap()
        app.buttons["computer-Studio Mac"].waitToExist()
    }

    @MainActor
    func testConnectingToAFoundComputerAndSavingIt() {
        let app = XCUIApplication.marionette(scenario: "first-launch")
        app.staticTexts["Add a Computer"].waitToExist()
        // What is behind the tip stays usable: tapping a Mac closes the tip and connects.
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Kitchen iMac")).firstMatch.waitToExist().tap()
        let save = app.switches["prompt-save-computer"].waitToExist()
        XCTAssertEqual(save.value as? String, "1")
        let username = app.textFields["prompt-username"].waitToExist()
        username.tap()
        username.typeText("demo")
        app.secureTextFields["prompt-password"].tap()
        app.secureTextFields["prompt-password"].typeText("demo")
        app.buttons["Connect"].tap()
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        app.answerSavePasswordPrompt()
        app.buttons["close-session"].tap()
        // Saved, with its password: it is now a computer of the library, and connects without asking.
        let saved = app.buttons["computer-Kitchen iMac"].waitToExist()
        saved.tap()
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        XCTAssertFalse(app.secureTextFields["prompt-password"].exists)
    }

    @MainActor
    func testKeyboardControlFullScreenAndStripCarryOverToTheNextSession() {
        let app = XCUIApplication.marionette(autoConnect: true)
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))

        let control = app.buttons["input-panel"].waitToExist()
        XCTAssertEqual(control.value as? String, "Hidden")
        app.showInputPanel("Trackpad")
        app.element("deck-trackpad").waitToExist()
        app.showInputPanel("Mac Keyboard")
        app.element("mac-keyboard").waitToExist()
        // The Mac keyboard is the app's own: no system keyboard, and no bar of Mac keys with it.
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCTAssertFalse(app.element("keyboard-accessory").exists)
        control.tap()
        XCTAssertEqual(control.value as? String, "Hidden")
        XCTAssertTrue(app.element("mac-keyboard").waitForNonExistence(timeout: 5))
        control.tap()
        XCTAssertEqual(control.value as? String, "Mac Keyboard")
        app.showInputPanel("System Keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        app.element("keyboard-accessory").waitToExist()
        XCTAssertTrue(app.element("mac-keyboard").waitForNonExistence(timeout: 5))
        XCTAssertTrue(control.isHittable)
        XCTAssertLessThanOrEqual(app.element("control-strip").frame.maxY, app.element("keyboard-accessory").frame.minY + 1)
        control.tap()
        XCTAssertEqual(control.value as? String, "Hidden")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.showInputPanel("Mac Keyboard")

        app.enterFullScreen()
        XCTAssertFalse(app.buttons["close-session"].isHittable)
        app.buttons["exit-full-screen"].waitToExist()

        app.buttons["collapse-controls"].tap()
        let handle = app.buttons["expand-controls"].waitToExist()
        XCTAssertTrue(app.buttons["input-panel"].waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(handle.frame.midX, app.remoteDisplay.frame.midX, "the handle sits at the side of the screen")

        let gone = NSPredicate(format: "exists == false OR isHittable == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: handle)], timeout: 12), .completed, "the handle should fade")
        app.remoteDisplay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let back = NSPredicate(format: "exists == true AND isHittable == true")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: back, object: handle)], timeout: 5), .completed, "a touch should bring the handle back")

        // Leave with the strip folded, in full screen, on the Mac keyboard: the next session
        // starts the same way.
        handle.tap()
        app.buttons["more-menu"].waitToExist().tap()
        app.buttons["Disconnect"].waitToExist().tap()

        app.buttons["computer-Studio Mac"].waitToExist().tap()
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        app.element("mac-keyboard").waitToExist()
        XCTAssertFalse(app.buttons["enter-full-screen"].exists, "still in full screen")
        app.buttons["exit-full-screen"].waitToExist()
        app.exitFullScreen()
        app.buttons["close-session"].waitToExist()
    }

    @MainActor
    func testAddingAComputerFromTheEmptyLibrary() {
        let app = XCUIApplication.marionette(scenario: "empty")
        app.staticTexts["No Computers"].waitToExist()
        // The tip points at +, and + works at once while it does.
        app.staticTexts["Add a Computer"].waitToExist()
        app.buttons["Add Computer"].firstMatch.tap()
        let address = app.textFields["address"].waitToExist()
        XCTAssertFalse(app.buttons["Add"].isEnabled)
        address.tap()
        address.typeText("studio-mac.local")
        XCTAssertTrue(app.buttons["Add"].isEnabled)
        app.buttons["Add"].tap()
        app.buttons["computer-studio-mac.local"].waitToExist()
    }

    @MainActor
    func testKeyboardAccessory() {
        let app = XCUIApplication.marionette(autoConnect: true)
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        app.showInputPanel("System Keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))

        // ⌘ latched on the bar applies to the next key typed on the system keyboard, then lets go.
        let command = app.element("modifier-command").waitToExist()
        command.tap()
        XCTAssertEqual(command.value as? String, "On for the next key")
        app.typeText("c")
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "2 key presses"))
        XCTAssertEqual(command.value as? String, "Off")
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "typed “”"), "⌘C types nothing")

        app.element("key-Escape").tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "3 key presses"))

        app.element("accessory-page-functionKeys").tap()
        app.element("key-F5").waitToExist().tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "4 key presses"))
        app.element("accessory-page-moreKeys").tap()
        app.element("key-Page Down").waitToExist().tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "5 key presses"))
        app.element("accessory-page-keys").tap()
        app.element("key-Escape").waitToExist()

        app.element("accessory-dismiss").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))
    }

    /// Scale to Fit stays fitted and is disabled while it is; Actual Size is a zoom like any other.
    @MainActor
    func testZoomButtonsScaleToFitAndActualSize() {
        let app = XCUIApplication.marionette(autoConnect: true)
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        let fitted = app.remoteDisplay.value as? String ?? ""
        app.showControls()
        let fit = app.buttons["scale-to-fit"].waitToExist()
        XCTAssertFalse(fit.isEnabled, "already fitted")
        app.buttons["actual-size"].tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "zoom 100 %"))
        XCTAssertTrue(fit.isEnabled)
        fit.tap()
        let zoom = fitted.components(separatedBy: ", ").first { $0.hasPrefix("zoom ") } ?? "zoom"
        XCTAssertTrue(app.waitForRemoteDisplay(containing: zoom), "back to the fitted zoom")
        XCTAssertFalse(fit.isEnabled)
        // With one display and no monitor, the View menu has nothing to hold and is left out.
        app.buttons["more-menu"].tap()
        app.buttons["open-files"].waitToExist()
        XCTAssertFalse(app.buttons["view-menu"].exists)
    }

    /// Guards against a pinch right after switching displays doing nothing until the pointer moves.
    @MainActor
    func testPinchRightAfterSwitchingDisplays() {
        let app = XCUIApplication.marionette(scenario: "two-displays", autoConnect: true)
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "zoom"))
        if ProcessInfo.processInfo.environment["PINCH_TRACKPAD"] == "1" {
            app.showControls()
            app.buttons["toggle-input-mode"].waitToExist().tap()
            XCTAssertTrue(app.waitForRemoteDisplay(containing: "trackpad mode"))
        }
        app.openViewMenu()
        app.buttons["External Display"].firstMatch.waitToExist().tap()
        Thread.sleep(forTimeInterval: 1)
        let before = app.remoteDisplay.value as? String ?? ""
        app.remoteDisplay.pinch(withScale: 2.5, velocity: 2)
        Thread.sleep(forTimeInterval: 1)
        let after = app.remoteDisplay.value as? String ?? ""
        print("PINCH before: \(before)\nPINCH after: \(after)")
        XCTAssertNotEqual(before.components(separatedBy: ", ").first { $0.hasPrefix("zoom") },
                          after.components(separatedBy: ", ").first { $0.hasPrefix("zoom") }, "the pinch zoomed")
    }

    @MainActor
    func testSettingsSSHKeysAndKnownHosts() {
        let app = XCUIApplication.marionette()
        app.buttons["computer-Studio Mac"].waitToExist()
        openLibraryMenuItem(app, "Settings")
        let natural = app.switches["natural-scrolling"].waitToExist()
        XCTAssertEqual(natural.value as? String, "1", "natural scrolling is on by default")
        app.buttons["Automatically"].waitToExist().tap()
        app.buttons["When You Paste"].waitToExist().tap()
        app.buttons["SSH Keys"].waitToExist().tap()
        app.staticTexts["No SSH Keys"].waitToExist()
        app.buttons["Generate a Key"].firstMatch.tap()
        app.element("ssh-key-Marionette Key").waitToExist()
        XCTAssertTrue(app.buttons["Copy Public Key"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "SHA256:")).firstMatch.exists)
        let back = app.buttons["BackButton"].exists ? app.buttons["BackButton"] : app.navigationBars.buttons["Settings"]
        back.firstMatch.tap()
        app.buttons["Known Hosts"].waitToExist().tap()
        app.staticTexts["No Known Hosts"].waitToExist()
    }

    @MainActor
    private func openLibraryMenuItem(_ app: XCUIApplication, _ title: String) {
        if !app.buttons[title].exists { app.buttons["More"].firstMatch.tap() }
        app.buttons[title].waitToExist().tap()
    }

    /// A hardware keyboard's combinations go to the remote machine as key codes, not as text.
    @MainActor
    func testHardwareKeyCombination() {
        let app = XCUIApplication.marionette(autoConnect: true)
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        // A plain key first: on the iOS 26.1 simulator the first ⌘ combination XCUITest types after a
        // launch never reaches the app.
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "has keyboard focus"), "the remote display takes hardware keys: \(app.remoteDisplay.value ?? "")")
        app.typeFirstHardwareKey()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "1 key presses"))
        app.typeKey("a", modifierFlags: .command)
        // ⌘ down and A down: two more key presses, and nothing more typed.
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "3 key presses"))
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "typed “b”"))
    }

    /// This device's clipboard goes to the remote computer when the user pastes: with the system
    /// paste control on the keyboard bar, then with ⌘V on a hardware keyboard.
    ///
    /// The clipboard is set by this runner, so to the app it is another app's. The system paste
    /// control hands it over without iOS asking. ⌘V and the strip's own paste glyph read it in the
    /// press; on iOS 26.1 such a read, triggered by XCUITest, can block the app's main thread until
    /// the test times out, so the ⌘V half runs on iOS 27 and later.
    @MainActor
    func testClipboardHardwarePasteAndPasteControl() {
        let app = XCUIApplication.marionette(autoConnect: true)
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        // The simulated Mac puts something on the clipboard as it connects; let that land first.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertFalse(app.element("clipboard-changed").exists, "a remote copy is not news")

        // A plain key first: on a freshly booted simulator the first ⌘ combination XCUITest types is
        // dropped before it reaches the app.
        app.typeFirstHardwareKey()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "1 key presses"))

        UIPasteboard.general.string = "from the phone"
        app.element("clipboard-changed").waitToExist(10)
        app.showInputPanel("System Keyboard")
        app.element("accessory-paste").waitToExist().tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "1 clipboard sends"))
        // ⌘ down, then V down: the paste reached the Mac as ⌘V.
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "3 key presses"))
        XCTAssertTrue(app.element("clipboard-changed").waitForNonExistence(timeout: 5))
        app.element("accessory-dismiss").tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 10))

        guard #available(iOS 27, *) else { return }
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "2 clipboard sends"))
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "5 key presses"))
        XCTAssertFalse(app.element("clipboard-changed").exists)
    }

    @MainActor
    func testFilesBrowseAndDownload() {
        let app = XCUIApplication.marionette(autoConnect: true)
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        app.buttons["more-menu"].waitToExist().tap()
        app.buttons["open-files"].waitToExist().tap()
        // The simulated Mac's home folder.
        app.element("file-Documents").waitToExist().tap()
        app.element("file-Readme.txt").waitToExist().tap()
        let transfer = app.element("transfer-Readme.txt").waitToExist()
        let saved = NSPredicate(format: "label CONTAINS %@", "Saved to Files")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: saved, object: transfer)], timeout: 15), .completed)
        app.buttons["files-up"].tap()
        app.element("file-Documents").waitToExist()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.remoteDisplay.waitForExistence(timeout: 5))
    }

    @MainActor
    func testAppShortcutsFromAHardwareKeyboard() {
        let app = XCUIApplication.marionette(autoConnect: true)
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        // A plain key first: the simulator drops the first modified key after a launch.
        app.typeFirstHardwareKey()

        // ⌃⌥⌘F is the app's own: full screen, and the Mac never sees an F.
        let chord: XCUIElement.KeyModifierFlags = [.control, .option, .command]
        app.typeKey("f", modifierFlags: chord)
        app.buttons["exit-full-screen"].waitToExist()
        XCTAssertFalse(app.buttons["enter-full-screen"].exists)
        app.typeKey("f", modifierFlags: chord)
        app.buttons["enter-full-screen"].waitToExist()
        // ⌃⌥⌘K presses the keyboard control: the on-screen input from Settings comes, then goes.
        app.typeKey("k", modifierFlags: chord)
        XCTAssertEqual(app.buttons["input-panel"].waitToExist().value as? String, "System Keyboard")
        app.typeKey("k", modifierFlags: chord)
        XCTAssertEqual(app.buttons["input-panel"].waitToExist().value as? String, "Hidden")
        XCTAssertTrue((app.remoteDisplay.value as? String ?? "").contains("typed “b”,"), "only the b was typed at the Mac: \(app.remoteDisplay.value ?? "")")

        // Any other combination is the Mac's, ⌘ ones included: ⌘W closes a window there, not this session.
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.remoteDisplay.exists)
        app.buttons["close-session"].waitToExist()

        // ⌃⌥⌘W disconnects; in the library the usual ⌘N adds a computer.
        app.typeKey("w", modifierFlags: chord)
        app.buttons["computer-Studio Mac"].waitToExist()
        app.typeKey("n", modifierFlags: .command)
        app.textFields["address"].waitToExist()
    }

    @MainActor
    func testLibraryShortcutsFromAHardwareKeyboard() {
        let app = XCUIApplication.marionette()
        app.buttons["computer-Studio Mac"].waitToExist()
        // A plain key first: the simulator drops the first modified key after a launch.
        app.typeKey("b", modifierFlags: [])
        app.typeKey(",", modifierFlags: .command)
        app.buttons["SSH Keys"].waitToExist()
        app.buttons["Done"].tap()
        app.typeKey("n", modifierFlags: .command)
        app.textFields["address"].waitToExist()
    }

    @MainActor
    func testInAWindowTheSessionIsAlwaysFullScreen() {
        let app = XCUIApplication.marionette(autoConnect: true, extra: ["-MarionetteWindowed"])
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        // No title bar, and nothing that leaves full screen: the session is the window.
        app.buttons["more-menu"].waitToExist()
        XCTAssertFalse(app.buttons["enter-full-screen"].exists)
        XCTAssertFalse(app.buttons["close-session"].exists && app.buttons["close-session"].isHittable)
        XCTAssertFalse(app.buttons["exit-full-screen"].exists)
        app.buttons["scale-to-fit"].waitToExist()
        XCTAssertFalse(app.buttons["Full Screen"].exists)
        app.buttons["more-menu"].waitToExist().tap()
        app.buttons["Disconnect"].waitToExist().tap()
        app.buttons["computer-Studio Mac"].waitToExist()
    }

    @MainActor
    func testControlStripFoldsAndOpens() {
        let app = XCUIApplication.marionette(autoConnect: true)
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        app.buttons["collapse-controls"].waitToExist().tap()
        let handle = app.buttons["expand-controls"].waitToExist()
        XCTAssertTrue(app.buttons["more-menu"].waitForNonExistence(timeout: 5))
        handle.tap()
        app.buttons["more-menu"].waitToExist()
        // Folding and opening the strip clicks nothing on the Mac.
        XCTAssertTrue((app.remoteDisplay.value as? String ?? "").contains("0 clicks"))
    }

    @MainActor
    func testDeckTrackpadAndMacKeyboard() {
        let app = XCUIApplication.marionette(autoConnect: true)
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))

        app.showInputPanel("Trackpad")
        let trackpad = app.element("deck-trackpad").waitToExist()
        trackpad.tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "1 clicks"))
        XCTAssertLessThanOrEqual(app.element("control-strip").frame.maxY, app.element("input-deck").frame.minY + 1)

        app.showInputPanel("Mac Keyboard")
        let command = app.element("mac-keyboard").descendants(matching: .any).matching(identifier: "modifier-command").firstMatch
        command.waitToExist().tap()
        XCTAssertEqual(command.value as? String, "On for the next key")
        command.tap()
        XCTAssertEqual(command.value as? String, "Locked")
        command.tap()
        XCTAssertEqual(command.value as? String, "Off")
        app.element("mac-key-a").tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "typed “a”"))
        let shift = app.element("mac-keyboard").descendants(matching: .any).matching(identifier: "modifier-shift").firstMatch
        shift.tap()
        app.element("mac-key-a").tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "typed “aA”"))
        XCTAssertEqual(shift.value as? String, "Off", "a one-shot modifier is used up by the key")
        app.showInputPanel("Hidden")
        XCTAssertTrue(app.element("mac-keyboard").waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testFoldedLikeALaptopTheLowerPaneFollowsTheKeyboardControl() {
        let app = XCUIApplication.marionette(autoConnect: true, extra: ["-MarionetteFoldOverride", "docked"])
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "High Performance"))
        // Docked, the strip folds itself away, and nothing at the bottom becomes the trackpad.
        app.buttons["expand-controls"].waitToExist()
        XCTAssertFalse(app.buttons["collapse-controls"].exists)
        app.element("deck-trackpad").waitToExist()
        app.showControls()
        let panel = app.buttons["input-panel"].waitToExist()
        panel.tap()
        app.element("mac-keyboard").waitToExist()
        XCTAssertFalse(app.element("deck-trackpad").exists)
        // The pointer control is about the picture alone.
        app.buttons["toggle-input-mode"].tap()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: "trackpad mode"))
        XCTAssertTrue(app.element("mac-keyboard").exists)
        panel.tap()
        app.element("deck-trackpad").waitToExist()
        // A long press lists all four; the two the pane cannot hold cannot be chosen.
        panel.press(forDuration: 1.0)
        let system = app.buttons["System Keyboard"].firstMatch.waitToExist()
        XCTAssertFalse(system.isEnabled)
        XCTAssertFalse(app.buttons["Hidden"].firstMatch.isEnabled)
        XCTAssertTrue(app.buttons["Mac Keyboard"].firstMatch.isEnabled)
        app.buttons["Mac Keyboard"].firstMatch.tap()
        app.element("mac-keyboard").waitToExist()
    }
}
