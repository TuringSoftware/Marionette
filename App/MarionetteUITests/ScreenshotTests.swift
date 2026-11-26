// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import XCTest

/// Takes the review screenshots. Run through `Scripts/screenshots.sh`, which collects the PNGs from
/// this test runner's Documents folder into `Artifacts/screenshots/<device>/`.
///
/// The script runs the class twice, in light and then dark appearance. Screens laid out with
/// `-MarionetteFoldOverride` carry "simulated-fold" in their name and a label on screen: they show
/// this app's layout for a pose the simulator cannot take, not what the system does.
final class ScreenshotTests: XCTestCase {
    /// The appearance of this pass, chosen by the script. The app is launched with it (see
    /// `XCUIApplication.marionette`) and the files are named after it.
    private var appearance: String {
        ProcessInfo.processInfo.environment["MARIONETTE_SCREENSHOT_APPEARANCE"] ?? "light"
    }

    private var outputDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Screenshots")
    }

    override func setUp() {
        continueAfterFailure = true
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    /// Launches the app, lets `prepare` bring it to the screen, and saves what is showing.
    @MainActor
    private func capture(
        _ name: String,
        scenario: String? = nil,
        autoConnect: Bool = false,
        extra: [String] = [],
        settle: TimeInterval = 1.0,
        prepare: (XCUIApplication) -> Void
    ) {
        let app = XCUIApplication.marionette(scenario: scenario, autoConnect: autoConnect, extra: extra)
        prepare(app)
        // Let the last layout pass and a fresh remote frame reach the screen.
        Thread.sleep(forTimeInterval: settle)
        let screenshot = XCUIScreen.main.screenshot()
        let file = outputDirectory.appending(path: "\(name)-\(appearance).png")
        do {
            try screenshot.pngRepresentation.write(to: file)
        } catch {
            XCTFail("could not write \(file.path): \(error)")
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name)-\(appearance)"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    @MainActor
    private func waitForSession(_ app: XCUIApplication, mode: String = "High Performance") {
        app.remoteDisplay.waitToExist()
        XCTAssertTrue(app.waitForRemoteDisplay(containing: mode))
    }

    // MARK: Library and editor

    @MainActor
    func testLibraryEmpty() {
        capture("01-library-empty", scenario: "empty") { app in
            app.staticTexts["No Computers"].waitToExist()
        }
    }

    @MainActor
    func testLibraryPopulated() {
        capture("02-library-populated") { app in
            app.buttons["computer-Studio Mac"].waitToExist()
        }
    }

    @MainActor
    func testLibraryDiscovery() {
        capture("03-library-on-this-network") { app in
            app.buttons["computer-Studio Mac"].waitToExist()
            app.staticTexts["On This Network"].waitToExist()
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Kitchen iMac")).firstMatch.waitToExist()
        }
    }

    @MainActor
    func testEditor() {
        capture("04-editor-ssh-tunnel") { app in
            app.buttons["computer-Mac mini"].waitToExist().press(forDuration: 1.0)
            app.buttons["Edit"].waitToExist().tap()
            app.element("address").waitToExist()
            // The tunnel is on for this computer; opening Connection shows the mode it forces.
            app.staticTexts["Connection"].waitToExist().tap()
            app.switches["View Only"].waitToExist()
        }
    }

    @MainActor
    func testEditorDisplayOptions() {
        capture("04b-editor-display-options") { app in
            app.buttons["computer-Studio Mac"].waitToExist().press(forDuration: 1.0)
            app.buttons["Edit"].waitToExist().tap()
            app.element("address").waitToExist()
            let display = app.staticTexts["Display"]
            for _ in 0..<4 where !display.isHittable { app.swipeUp() }
            display.waitToExist().tap()
            // The options belong to Fit This Device.
            XCTAssertFalse(app.switches["retina-display"].exists)
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Show")).firstMatch.waitToExist().tap()
            app.buttons["Fit This Device"].waitToExist().tap()
            let secondary = app.switches["secondary-display"]
            for _ in 0..<4 where !secondary.isHittable { app.swipeUp() }
            app.switches["retina-display"].waitToExist()
            secondary.waitToExist()
        }
    }

    @MainActor
    func testEditorPasswordSecurity() {
        capture("04c-editor-password-security") { app in
            app.buttons["computer-Studio Mac"].waitToExist().press(forDuration: 1.0)
            app.buttons["Edit"].waitToExist().tap()
            app.staticTexts["Password Security"].waitToExist().tap()
            app.switches["include-in-backups"].waitToExist()
        }
    }

    // MARK: Connecting

    @MainActor
    func testConnecting() {
        capture("05-connecting", scenario: "slow", autoConnect: true) { app in
            app.element("connecting").waitToExist()
        }
    }

    @MainActor
    func testCredentialPrompt() {
        capture("06-credential-prompt-retry", scenario: "bad-password", autoConnect: true) { app in
            app.element("prompt-error").waitToExist()
        }
    }

    @MainActor
    func testHostKeyChanged() {
        capture("07-host-key-changed", scenario: "host-key-changed", autoConnect: true) { app in
            app.buttons["Connect Anyway"].waitToExist()
        }
    }

    @MainActor
    func testSessionSelect() {
        capture("08-session-select", scenario: "session-select", autoConnect: true) { app in
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask to Share the Display")).firstMatch.waitToExist()
        }
    }

    @MainActor
    func testFailure() {
        capture("09-failure-unreachable", scenario: "unreachable", autoConnect: true) { app in
            app.element("connection-failure").waitToExist()
        }
    }

    // MARK: Session

    @MainActor
    func testSession() {
        capture("10-session-fit", autoConnect: true) { app in
            waitForSession(app)
        }
    }

    @MainActor
    func testSessionZoomed() {
        capture("11-session-touch-zoomed", autoConnect: true) { app in
            waitForSession(app)
            app.remoteDisplay.pinch(withScale: 2.6, velocity: 2)
            app.remoteDisplay.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        }
    }

    @MainActor
    func testSessionWithInputDeck() {
        capture("12-session-input-deck", autoConnect: true) { app in
            waitForSession(app)
            app.showInputPanel("Trackpad")
            app.element("deck-trackpad").waitToExist()
        }
    }

    @MainActor
    func testSessionWithDeckKeyboard() {
        capture("13-session-input-deck-keyboard", autoConnect: true) { app in
            waitForSession(app)
            app.showInputPanel("Mac Keyboard")
            app.element("mac-keyboard").waitToExist()
            app.element("modifier-command").waitToExist().tap()
        }
    }

    @MainActor
    func testSessionFallbackBanner() {
        capture("14-session-fallback-banner", scenario: "fallback", autoConnect: true) { app in
            waitForSession(app, mode: "Standard")
            app.element("session-banner").waitToExist()
        }
    }

    @MainActor
    func testSessionReconnecting() {
        capture("15-session-reconnecting", scenario: "drop", autoConnect: true, settle: 0.5) { app in
            // The session drops three seconds after it connects; on a busy host that can be before
            // the connected state is ever observed, so only the end state is waited for.
            app.remoteDisplay.waitToExist(30)
            app.staticTexts["Reconnecting…"].waitToExist(30)
        }
    }

    @MainActor
    func testSessionSoftwareKeyboard() {
        capture("16-session-software-keyboard", autoConnect: true) { app in
            waitForSession(app)
            app.showInputPanel("System Keyboard")
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
        }
    }

    @MainActor
    func testSessionKeyboardAccessory() {
        capture("18-session-keyboard-accessory", autoConnect: true) { app in
            waitForSession(app)
            app.showInputPanel("System Keyboard")
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
            // One modifier on for the next key, one locked: the three states side by side.
            app.element("modifier-command").waitToExist().tap()
            app.element("modifier-shift").tap()
            app.element("modifier-shift").tap()
        }
        capture("19-session-keyboard-accessory-function-keys", autoConnect: true) { app in
            waitForSession(app)
            app.showInputPanel("System Keyboard")
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
            app.element("accessory-page-functionKeys").waitToExist().tap()
            app.element("key-F5").waitToExist()
        }
        capture("19b-session-keyboard-accessory-more-keys", autoConnect: true) { app in
            waitForSession(app)
            app.showInputPanel("System Keyboard")
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
            app.element("accessory-page-moreKeys").waitToExist().tap()
            app.element("key-Home").waitToExist()
        }
    }

    @MainActor
    func testSessionClipboardChanged() {
        capture("28-session-paste-control-changed", autoConnect: true) { app in
            waitForSession(app)
            // Let the simulated Mac's own copy land first; then copy something here.
            Thread.sleep(forTimeInterval: 2)
            UIPasteboard.general.string = "Copied on this device"
            app.element("clipboard-changed").waitToExist()
        }
    }

    @MainActor
    func testSettings() {
        capture("26-settings") { app in
            app.buttons["computer-Studio Mac"].waitToExist()
            if !app.buttons["Settings"].exists { app.buttons["More"].firstMatch.tap() }
            app.buttons["Settings"].waitToExist().tap()
            app.switches["natural-scrolling"].waitToExist()
        }
        capture("27-ssh-keys") { app in
            libraryAction(app, "SSH Keys")
            app.buttons["New Key"].firstMatch.waitToExist().tap()
            app.buttons["Create"].waitToExist().tap()
            app.element("ssh-key-Ed25519 Key").waitToExist()
        }
        capture("27b-ssh-key-new") { app in
            libraryAction(app, "SSH Keys")
            app.buttons["New Key"].firstMatch.waitToExist().tap()
            app.buttons["ssh-key-type"].waitToExist().tap()
            app.buttons["RSA"].waitToExist().tap()
            app.staticTexts["Storage"].waitToExist().tap()
            app.switches["include-in-icloud"].waitToExist()
        }
        capture("27c-ssh-key-import") { app in
            libraryAction(app, "SSH Keys")
            app.buttons["add-ssh-key"].waitToExist().tap()
            app.buttons["Import Existing Key"].waitToExist().tap()
            app.textViews["ssh-key-text"].waitToExist()
        }
    }

    @MainActor
    func testFiles() {
        capture("23-files", autoConnect: true) { app in
            waitForSession(app)
            app.buttons["more-menu"].waitToExist().tap()
            app.buttons["open-files"].waitToExist().tap()
            app.element("file-Documents").waitToExist().tap()
            app.element("file-Readme.txt").waitToExist().tap()
            app.element("transfer-Readme.txt").waitToExist()
        }
    }

    @MainActor
    func testFilesSendOnly() {
        capture("29-files-send-only", scenario: "files-send-only", autoConnect: true) { app in
            waitForSession(app)
            app.buttons["more-menu"].waitToExist().tap()
            app.buttons["open-files"].waitToExist().tap()
            app.element("files-send").waitToExist()
        }
    }

    @MainActor
    func testSessionUnreliableNetworkBanner() {
        capture("24-session-unreliable-network-banner", scenario: "unreliable-network", autoConnect: true) { app in
            waitForSession(app, mode: "Standard")
            app.element("session-banner").waitToExist()
        }
    }

    @MainActor
    func testSessionFitToDevice() {
        capture("25-session-fit-to-device", scenario: "fit-to-device", autoConnect: true, settle: 2.5) { app in
            waitForSession(app)
        }
    }

    @MainActor
    func testSessionLandscape() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        var rotated = false
        capture("17-session-landscape", autoConnect: true, settle: 1.5) { app in
            waitForSession(app)
            // Element frames are not a reliable sign of rotation (an iPhone reports them unrotated).
            // The fitted zoom is: a landscape pane fits the desktop at a different scale.
            let before = app.remoteDisplay.value as? String ?? ""
            XCUIDevice.shared.orientation = .landscapeLeft
            // Up to 20 s: on a loaded host the rotation and the re-fit can take several seconds.
            for _ in 0..<40 where !rotated {
                rotated = (app.remoteDisplay.value as? String ?? before) != before
                if !rotated { Thread.sleep(forTimeInterval: 0.5) }
            }
        }
        if !rotated {
            // The app did not turn (the Duo's outer display, for one, may not). Do not leave a
            // portrait picture behind under a landscape name.
            try? FileManager.default.removeItem(at: outputDirectory.appending(path: "17-session-landscape-\(appearance).png"))
            throw XCTSkip("the interface did not rotate to landscape on this device")
        }
    }

    // MARK: Menus, secondary screens and less common states

    /// Opens a library toolbar action, which a narrow bar keeps in its More menu.
    @MainActor
    private func libraryAction(_ app: XCUIApplication, _ title: String) {
        app.buttons["computer-Studio Mac"].waitToExist()
        if !app.buttons[title].exists { app.buttons["More"].firstMatch.tap() }
        app.buttons[title].waitToExist().tap()
    }

    @MainActor
    func testLibraryContextMenu() {
        capture("30-library-context-menu") { app in
            app.buttons["computer-Studio Mac"].waitToExist().press(forDuration: 1.0)
            app.buttons["Duplicate"].waitToExist()
        }
    }

    @MainActor
    func testLibraryMoreMenu() {
        capture("31-library-more-menu") { app in
            app.buttons["computer-Studio Mac"].waitToExist()
            if app.buttons["More"].firstMatch.exists { app.buttons["More"].firstMatch.tap() }
            app.buttons["Settings"].waitToExist()
        }
    }

    @MainActor
    func testEditorNewComputer() {
        capture("32-editor-new-computer") { app in
            app.buttons["computer-Studio Mac"].waitToExist()
            app.buttons["Add Computer"].waitToExist().tap()
            app.element("address").waitToExist()
        }
    }

    @MainActor
    func testHelp() {
        capture("33-help-turn-on-screen-sharing") { app in
            libraryAction(app, "How to Turn On Screen Sharing")
        }
    }

    @MainActor
    func testLocalNetworkDenied() {
        capture("34-library-local-network-denied", scenario: "local-network-denied") { app in
            app.staticTexts["Local Network Access Is Off"].waitToExist()
        }
    }

    @MainActor
    func testSettingsSubpages() {
        capture("35-ssh-keys-known-hosts") { app in
            libraryAction(app, "SSH Keys")
            app.buttons["Known Hosts"].waitToExist().tap()
            app.staticTexts["No Known Hosts"].waitToExist()
        }
        capture("36-settings-licences") { app in
            libraryAction(app, "Settings")
            let licences = app.buttons["Licences"]
            for _ in 0..<4 where !licences.isHittable { app.swipeUp() }
            licences.waitToExist().tap()
        }
    }

    @MainActor
    func testSessionSelectWaiting() {
        capture("37-session-select-waiting", scenario: "session-select-waiting", autoConnect: true) { app in
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask to Share the Display")).firstMatch.waitToExist().tap()
            app.staticTexts["Waiting for permission…"].waitToExist()
        }
    }

    @MainActor
    func testSessionSelectDeclined() {
        capture("38-session-select-declined", scenario: "session-select-declined", autoConnect: true) { app in
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Ask to Share the Display")).firstMatch.waitToExist().tap()
            app.staticTexts["Alex declined your request to share the display."].waitToExist()
        }
    }

    @MainActor
    func testHostKeyNew() {
        capture("39-host-key-new", scenario: "host-key", autoConnect: true) { app in
            app.buttons["Trust"].waitToExist()
        }
    }

    @MainActor
    func testKeyboardInteractive() {
        capture("40-ssh-two-factor", scenario: "keyboard-interactive", autoConnect: true) { app in
            app.buttons["Continue"].waitToExist()
        }
    }

    @MainActor
    func testFailureBusy() {
        capture("41-failure-busy", scenario: "busy", autoConnect: true) { app in
            app.element("connection-failure").waitToExist()
        }
    }

    @MainActor
    func testSessionEnded() {
        capture("42-session-ended", scenario: "remote-closed", autoConnect: true) { app in
            app.remoteDisplay.waitToExist()
            app.buttons["Reconnect"].waitToExist(20)
        }
    }

    @MainActor
    func testSessionMenus() {
        capture("43-session-title-menu", autoConnect: true) { app in
            waitForSession(app)
            let bar = app.navigationBars.firstMatch
            let title = bar.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Studio Mac")).firstMatch
            if title.exists { title.tap() } else { bar.staticTexts["Studio Mac"].firstMatch.waitToExist().tap() }
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Direct Connection")).firstMatch.waitToExist()
        }
        capture("44-session-more-menu", autoConnect: true) { app in
            waitForSession(app)
            app.buttons["more-menu"].waitToExist().tap()
            app.buttons["open-files"].waitToExist()
        }
        capture("45-session-view-menu-two-displays", scenario: "two-displays", autoConnect: true) { app in
            waitForSession(app)
            app.openViewMenu()
            app.buttons["Built-in Display"].firstMatch.waitToExist()
        }
        capture("46-session-keyboard-shortcuts", autoConnect: true) { app in
            waitForSession(app)
            app.buttons["more-menu"].waitToExist().tap()
            app.buttons["Keyboard Shortcuts"].waitToExist().tap()
        }
    }

    @MainActor
    func testSessionFullScreen() {
        capture("47-session-full-screen", autoConnect: true, settle: 2.5) { app in
            waitForSession(app)
            app.enterFullScreen()
        }
        capture("53-session-full-screen-controls-folded", autoConnect: true, settle: 1.5) { app in
            waitForSession(app)
            app.enterFullScreen()
            app.buttons["collapse-controls"].waitToExist().tap()
            app.buttons["expand-controls"].waitToExist()
        }
        capture("55-session-controls-over-picture", scenario: "fit-to-device", autoConnect: true, settle: 3.0) { app in
            // The Mac's display fills the screen, so the strip floats over the picture itself.
            waitForSession(app)
            app.enterFullScreen()
        }
        capture("56-session-in-a-window", autoConnect: true, extra: ["-MarionetteWindowed"], settle: 2.5) { app in
            // As in an iPad window smaller than the screen: always full screen, at the window's size.
            waitForSession(app)
            app.buttons["more-menu"].waitToExist()
        }
        capture("54-session-controls-folded", autoConnect: true, settle: 1.0) { app in
            waitForSession(app)
            app.buttons["collapse-controls"].waitToExist().tap()
            app.buttons["expand-controls"].waitToExist()
        }
    }

    @MainActor
    func testSessionVNC() {
        capture("48-session-vnc", scenario: "vnc", autoConnect: true, settle: 2) { app in
            app.remoteDisplay.waitToExist(30)
        }
    }

    @MainActor
    func testDisplayWindow() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "windows of their own are an iPad feature")
        capture("49-ipad-display-window", scenario: "two-displays", autoConnect: true, settle: 2) { app in
            waitForSession(app)
            app.openViewMenu()
            app.buttons["open-display-window"].waitToExist().tap()
            app.element("display-window").waitToExist(20)
        }
    }

    @MainActor
    func testFirstLaunch() {
        capture("50-library-first-launch", scenario: "first-launch") { app in
            app.staticTexts["On This Network"].waitToExist()
            app.staticTexts["Add a Computer"].waitToExist()
        }
    }

    @MainActor
    func testSignInToAFoundComputer() {
        capture("51-sign-in-save-computer", scenario: "first-launch") { app in
            app.buttons["Close"].firstMatch.waitToExist().tap()
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Kitchen iMac")).firstMatch.waitToExist().tap()
            app.element("prompt-save-computer").waitToExist()
        }
    }

    @MainActor
    func testKeyboardControlMenu() {
        capture("52-session-keyboard-control-menu", autoConnect: true) { app in
            waitForSession(app)
            app.buttons["input-panel"].waitToExist().press(forDuration: 1.0)
            app.buttons["System Keyboard"].waitToExist()
        }
    }

    @MainActor
    func testMenuBar() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the menu bar is an iPad feature")
        capture("57-ipad-menu-bar", autoConnect: true, settle: 1.5) { app in
            waitForSession(app)
            // The menu bar belongs to the system, so it is reached through SpringBoard.
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let name = system.staticTexts["Marionette"].firstMatch
            if name.waitForExistence(timeout: 3) {
                name.tap()
            } else {
                let top = system.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.0))
                top.press(forDuration: 0.3, thenDragTo: system.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.03)), withVelocity: .slow, thenHoldForDuration: 0.5)
            }
            for candidate in [system.menuBarItems["Session"], system.buttons["Session"], app.menuBarItems["Session"], app.buttons["Session"]] where candidate.waitForExistence(timeout: 2) {
                candidate.tap()
                break
            }
        }
    }

    // MARK: Simulated fold (iPhone Duo)

    @MainActor
    func testSimulatedFoldDocked() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MARIONETTE_SCREENSHOT_FOLD"] == "1", "only captured on the iPhone Duo")
        capture("20-session-docked-trackpad-simulated-fold", autoConnect: true, extra: ["-MarionetteFoldOverride", "docked"]) { app in
            waitForSession(app)
            app.element("simulated-fold-label").waitToExist()
            // Nothing at the bottom becomes the trackpad; the strip is left open to show its controls.
            app.showControls()
            app.element("deck-trackpad").waitToExist()
        }
        capture("21-session-docked-keyboard-simulated-fold", autoConnect: true, extra: ["-MarionetteFoldOverride", "docked"]) { app in
            waitForSession(app)
            app.showControls()
            app.buttons["input-panel"].waitToExist().tap()
            app.element("mac-keyboard").waitToExist()
        }
    }

    @MainActor
    func testSimulatedFoldBook() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MARIONETTE_SCREENSHOT_FOLD"] == "1", "only captured on the iPhone Duo")
        capture("22-session-book-simulated-fold", autoConnect: true, extra: ["-MarionetteFoldOverride", "book"]) { app in
            waitForSession(app)
            app.element("simulated-fold-label").waitToExist()
        }
    }
}
