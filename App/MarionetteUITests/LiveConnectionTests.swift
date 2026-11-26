// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import XCTest

/// Connects the real app, in its live environment, to a real Mac. Opt-in: these run only when
/// `MARIONETTE_TEST_HOST`, `MARIONETTE_TEST_USER` and `MARIONETTE_TEST_PASSWORD` are set for the test runner, e.g.
///
///     TEST_RUNNER_MARIONETTE_TEST_HOST=<mac> TEST_RUNNER_MARIONETTE_TEST_USER=… TEST_RUNNER_MARIONETTE_TEST_PASSWORD=… \
///         xcodebuild test -project Marionette.xcodeproj -scheme Marionette -destination … \
///         -only-testing:MarionetteUITests/LiveConnectionTests/testHighPerformance
///
/// Only one viewer at a time can hold a High Performance session, so run one test at a time and
/// never in parallel with anything else that connects to the Mac. Each test adds the computer and
/// deletes it again afterwards (removing its keychain password). Screenshots land in the runner's
/// Documents/Screenshots.
final class LiveConnectionTests: XCTestCase {
    private struct Host {
        var address: String
        var user: String
        var password: String
    }

    private func host() throws -> Host {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["MARIONETTE_TEST_HOST"], let user = environment["MARIONETTE_TEST_USER"],
              let password = environment["MARIONETTE_TEST_PASSWORD"]
        else { throw XCTSkip("set MARIONETTE_TEST_HOST, MARIONETTE_TEST_USER and MARIONETTE_TEST_PASSWORD to run against a real Mac") }
        return Host(address: address, user: user, password: password)
    }

    override func setUp() {
        continueAfterFailure = false
        // Whatever happens, no session may be left holding the Mac: a test that fails half-way
        // never reaches its own disconnect, so the app is stopped, which closes its connections.
        addTeardownBlock { @MainActor in
            XCUIApplication().terminate()
        }
    }

    // MARK: The four ways in

    /// Automatic mode on a direct path: High Performance, with a display shaped like this device.
    @MainActor
    func testHighPerformance() throws {
        let host = try host()
        let app = launchAndAdd(host) { _ in }
        let value = connect(app, host, expecting: "High Performance")
        // "display 804×1748": the display takes the window's shape, portrait or landscape (a phone
        // held upright; an iPhone Duo open flat), not a letterboxed desktop.
        if let size = Self.displaySize(in: value), UIDevice.current.userInterfaceIdiom == .phone {
            let window = app.windows.firstMatch.frame
            XCTAssertEqual(size.height > size.width, window.height > window.width, "expected the window's shape \(window.size), got \(size)")
        }
        save(app, "live-high-performance")
        disconnectAndDelete(app, host)
    }

    /// Fit This Device with Retina (the default) on its side: a 2x display that fills the screen
    /// once fitted.
    @MainActor
    func testRetinaOnItsSide() throws {
        let host = try host()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchAndAdd(host) { _ in }
        let value = connect(app, host, expecting: "High Performance")
        Thread.sleep(forTimeInterval: 4)
        print("LIVE RETINA VALUE: \(app.remoteDisplay.value as? String ?? value)")
        save(app, "live-retina-landscape")
        app.showControls()
        app.buttons["scale-to-fit"].waitToExist().tap()
        Thread.sleep(forTimeInterval: 2)
        print("LIVE RETINA FITTED: \(app.remoteDisplay.value as? String ?? "")")
        save(app, "live-retina-landscape-fitted")
        disconnectAndDelete(app, host)
    }

    /// Standard mode, which starts at Adaptive quality; Full can be chosen from the View menu.
    @MainActor
    func testStandardAdaptive() throws {
        let host = try host()
        let app = launchAndAdd(host) { app in
            app.staticTexts["Connection"].tap()
            self.choose(app, picker: "Mode", option: "Standard")
        }
        _ = connect(app, host, expecting: "Standard")
        Thread.sleep(forTimeInterval: 3)
        save(app, "live-standard-adaptive")
        app.showControls()
        app.buttons["more-menu"].waitToExist().tap()
        app.buttons["quality-menu"].waitToExist().tap()
        XCTAssertTrue(app.buttons["Adaptive Quality"].waitForExistence(timeout: 5), "Standard sessions offer a quality choice")
        app.buttons["Full Quality"].tap()
        Thread.sleep(forTimeInterval: 3)
        save(app, "live-standard-full")
        disconnectAndDelete(app, host)
    }

    /// Through an SSH tunnel: host-key question, SSH password, Standard without sound, and files over
    /// the same SSH connection.
    @MainActor
    func testSSHTunnelWithFiles() throws {
        let host = try host()
        let app = launchAndAdd(host) { app in
            app.staticTexts["SSH Tunnel"].tap()
            let toggle = app.switches["use-ssh-tunnel"].waitToExist()
            if (toggle.value as? String) != "1" { toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap() }
        }
        app.buttons["computer-\(host.address)"].waitToExist().tap()
        // First contact with this SSH server: its key has to be trusted.
        let trust = app.buttons["Trust"]
        if trust.waitForExistence(timeout: 30) { trust.tap() }
        // The SSH password is not the saved screen-sharing one unless the user says so.
        let sshPassword = app.secureTextFields["prompt-password"]
        if sshPassword.waitForExistence(timeout: 20) {
            sshPassword.tap()
            sshPassword.typeText(host.password)
            app.buttons["Connect"].tap()
        }
        _ = waitConnected(app, expecting: "Standard · SSH Tunnel")
        Thread.sleep(forTimeInterval: 3)
        save(app, "live-ssh-tunnel-standard")

        app.buttons["more-menu"].tap()
        app.buttons["open-files"].waitToExist().tap()
        // The Mac's home folder, listed over SFTP on the tunnel's own connection.
        let anyEntry = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "file-")).firstMatch
        XCTAssertTrue(anyEntry.waitForExistence(timeout: 30), "an SFTP listing should appear")
        print("LIVE SFTP FIRST ENTRY: \(anyEntry.identifier)")
        save(app, "live-ssh-tunnel-files")
        app.buttons["Done"].tap()
        disconnectAndDelete(app, host)
    }

    /// A VNC server that is not a Mac: there is no protocol to choose, it is found out on
    /// connecting, and its saved password is its own. Opt-in with `MARIONETTE_TEST_VNC_ADDRESS`
    /// (`host:port`) and `MARIONETTE_TEST_VNC_PASSWORD`.
    @MainActor
    func testVNC() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["MARIONETTE_TEST_VNC_ADDRESS"], let password = environment["MARIONETTE_TEST_VNC_PASSWORD"] else {
            throw XCTSkip("set MARIONETTE_TEST_VNC_ADDRESS and MARIONETTE_TEST_VNC_PASSWORD to run against a VNC server")
        }
        let name = "Live VNC Server"
        let app = XCUIApplication()
        app.launchArguments = ["-MarionetteDiagnostics"]
        app.launch()
        let card = app.buttons["computer-\(name)"]
        if card.waitForExistence(timeout: 5) { delete(app, card: card) }
        app.buttons["Add Computer"].firstMatch.waitToExist().tap()
        let field = app.textFields["address"].waitToExist()
        field.tap()
        field.typeText(address)
        let nameField = app.textFields["name"]
        nameField.tap()
        nameField.typeText(name)
        let secret = app.secureTextFields["password"]
        secret.tap()
        secret.typeText(password)
        app.buttons["Add"].tap()
        app.answerSavePasswordPrompt()
        card.waitToExist().tap()
        // Plain VNC encrypts nothing, and says so.
        _ = waitConnected(app, expecting: "Standard · VNC · Not Secure")
        save(app, "live-vnc")
        app.showControls()
        app.buttons["more-menu"].waitToExist().tap()
        app.buttons["quality-menu"].waitToExist().tap()
        XCTAssertTrue(app.buttons["Adaptive Quality"].waitForExistence(timeout: 5), "VNC sessions offer a quality choice")
        save(app, "live-vnc-quality-menu")
        app.buttons["Full Quality"].tap()
        Thread.sleep(forTimeInterval: 3)
        save(app, "live-vnc-full")
        app.buttons["close-session"].waitToExist().tap()
        delete(app, card: card)
    }

    /// Bonjour discovery in the live app: needs a Mac with Screen Sharing on, on a network this
    /// device can browse. Lists what it finds; connects to nothing.
    @MainActor
    func testBonjourDiscovery() throws {
        _ = try host()
        let app = XCUIApplication()
        app.launchArguments = ["-MarionetteDiagnostics"]
        app.launch()
        app.staticTexts["On This Network"].waitToExist(30)
        let found = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", ".local"))
        let appeared = found.firstMatch.waitForExistence(timeout: 20)
        print("LIVE BONJOUR: \(appeared ? found.allElementsBoundByIndex.map(\.label).joined(separator: " | ") : "nothing found in 20 s")")
        save(app, "live-bonjour")
        XCTAssertTrue(appeared, "expected at least one _rfb._tcp service on this network")
    }

    // MARK: Features that need the Mac's side checked too

    /// A second account while the first is at the Mac (`MARIONETTE_TEST_USER2`, `MARIONETTE_TEST_PASSWORD2`): the
    /// app asks how to connect, and "Log In as Yourself" opens a session of the account's own.
    @MainActor
    func testSessionSelectLogInAsSelf() throws {
        let base = try host()
        let environment = ProcessInfo.processInfo.environment
        guard let user = environment["MARIONETTE_TEST_USER2"] else { throw XCTSkip("set MARIONETTE_TEST_USER2 to a second account on the Mac") }
        let host = Host(address: base.address, user: user, password: environment["MARIONETTE_TEST_PASSWORD2"] ?? base.password)
        let app = launchAndAdd(host) { _ in }
        app.buttons["computer-\(host.address)"].waitToExist().tap()
        let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Log In as Yourself")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 60), "someone else is at the Mac, so the app should ask how to connect")
        save(app, "live-session-select")
        choice.tap()
        _ = waitConnected(app, expecting: "High Performance")
        save(app, "live-session-select-own-session")
        disconnectAndDelete(app, host)
    }

    /// The clipboard both ways in a direct session. The script that runs this
    /// (`Scripts/live-app-checks.sh`) reads and sets the Mac's clipboard over SSH when this test leaves
    /// a marker, and passes the texts in `MARIONETTE_CLIPBOARD_NONCE`.
    @MainActor
    func testClipboardBothWays() throws {
        let host = try host()
        let nonce = ProcessInfo.processInfo.environment["MARIONETTE_CLIPBOARD_NONCE"] ?? "manual"
        let app = launchAndAdd(host) { _ in }
        _ = connect(app, host, expecting: "High Performance")

        // Device → Mac with the paste control.
        UIPasteboard.general.string = "marionette-device-\(nonce)"
        app.element("clipboard-changed").waitToExist(15)
        app.buttons["toolbar-paste"].waitToExist().tap()
        app.allowPasteIfAsked()
        XCTAssertTrue(app.element("clipboard-changed").waitForNonExistence(timeout: 10))
        mark("pasted")

        // Mac → device: the script copies on the Mac once it sees the marker.
        // This runner may not read the clipboard itself; the script checks it from outside and says so.
        XCTAssertTrue(waitForMarker("mac-copy-arrived", timeout: 90), "what the Mac copied should be on this device's clipboard")
        XCTAssertFalse(app.element("clipboard-changed").exists, "a copy from the Mac is not a local change")

        // Device → Mac with a hardware ⌘V. For 1.5 s after writing the Mac's copy the app takes any
        // change of the clipboard to be its own write settling, so copy again after that.
        Thread.sleep(forTimeInterval: 2)
        // Escape first: a fresh simulator drops the first ⌘ combination.
        UIPasteboard.general.string = "marionette-device2-\(nonce)"
        app.element("clipboard-changed").waitToExist(15)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(app.element("clipboard-changed").waitForNonExistence(timeout: 10), "⌘V should send the clipboard")
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0, "no paste permission question")
        XCTAssertEqual(app.alerts.count, 0)
        mark("pasted-again")
        save(app, "live-clipboard")
        disconnectAndDelete(app, host)
    }

    /// Screen Sharing's own file transfer, without SSH: the Files sheet offers sending only, and a file
    /// picked from this app's folder lands in the Mac's Downloads. The script puts the file in place
    /// (`MARIONETTE_UPLOAD_NAME`) and checks the Mac afterwards.
    @MainActor
    func testNativeFileSend() throws {
        let host = try host()
        let name = ProcessInfo.processInfo.environment["MARIONETTE_UPLOAD_NAME"] ?? "marionette-live-upload.txt"
        let app = launchAndAdd(host) { _ in }
        _ = connect(app, host, expecting: "High Performance")
        app.buttons["more-menu"].waitToExist().tap()
        app.buttons["open-files"].waitToExist().tap()
        // Without SSH the Mac cannot be browsed: sending, and an offer to sign in for more.
        app.buttons["files-send"].waitToExist(30).tap()
        save(app, "live-files-send-only")
        pick(app, file: name)
        let row = app.element("transfer-\(name)")
        row.waitToExist(30)
        let sent = NSPredicate(format: "label CONTAINS %@", "Sent")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: sent, object: row)], timeout: 60), .completed, "the transfer should finish: \(row.label)")
        save(app, "live-files-sent")
        app.buttons["Done"].tap()
        disconnectAndDelete(app, host)
    }

    /// A file dragged off the Mac's desktop with the finger and let go over the drop well arrives
    /// on this device, and stays where it was on the Mac. The Mac needs the file on its desktop
    /// (`MARIONETTE_DRAG_NAME`, by default `wfh-drag-test.txt`) at a known place in the picture
    /// (`MARIONETTE_DRAG_POSITION`, fractions across and down, by default where the test Mac shows
    /// it: sorted by name in one column at the right edge). The script that runs this
    /// (`Scripts/live-app-checks.sh`) checks afterwards that the Mac still has the file and that
    /// what arrived here is the same.
    ///
    /// Standard mode, full screen: the picture is then the Mac's own display, fitted and centred
    /// in the screen, so a place on the desktop is a place on the screen that can be worked out.
    @MainActor
    func testDraggingAFileFromTheMacOntoTheWell() throws {
        let host = try host()
        let environment = ProcessInfo.processInfo.environment
        let name = environment["MARIONETTE_DRAG_NAME"] ?? "wfh-drag-test.txt"
        let fractions = (environment["MARIONETTE_DRAG_POSITION"] ?? "0.935,0.381").split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(fractions.count, 2, "MARIONETTE_DRAG_POSITION is two fractions: across,down")
        let app = launchAndAdd(host) { app in
            app.staticTexts["Connection"].tap()
            self.choose(app, picker: "Mode", option: "Standard")
        }
        let value = connect(app, host, expecting: "Standard")
        app.enterFullScreen()
        Thread.sleep(forTimeInterval: 2)
        let display = try XCTUnwrap(Self.displaySize(in: value), "no display size in “\(value)”")
        let screen = app.remoteDisplay.frame
        let scale = min(screen.width / CGFloat(display.width), screen.height / CGFloat(display.height))
        let picture = CGRect(
            x: screen.midX - CGFloat(display.width) * scale / 2,
            y: screen.midY - CGFloat(display.height) * scale / 2,
            width: CGFloat(display.width) * scale,
            height: CGFloat(display.height) * scale
        )
        print("LIVE DRAG PICTURE: \(picture) for display \(display)")
        save(app, "live-drag-before")
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let file = origin.withOffset(CGVector(dx: picture.minX + picture.width * fractions[0], dy: picture.minY + picture.height * fractions[1]))
        // The well is not there before the Mac has started its drag; it comes up at the top of
        // the picture, in the middle.
        let well = origin.withOffset(CGVector(dx: picture.midX, dy: picture.minY + 46))
        // A long press, then the finger moves: the button goes down as it starts to, which is
        // what makes the Finder pick the file up, and comes up over the well.
        file.press(forDuration: 0.8, thenDragTo: well, withVelocity: .slow, thenHoldForDuration: 2.5)
        Thread.sleep(forTimeInterval: 1)
        save(app, "live-drag-after")

        app.showControls()
        app.buttons["more-menu"].waitToExist().tap()
        app.buttons["open-files"].waitToExist().tap()
        let row = app.element("transfer-\(name)")
        XCTAssertTrue(row.waitForExistence(timeout: 30), "letting go over the well should start a download of \(name)")
        let saved = NSPredicate(format: "label CONTAINS %@", "Saved to Files")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: saved, object: row)], timeout: 120), .completed, "the download should finish: \(row.label)")
        save(app, "live-drag-saved")
        app.buttons["Done"].tap()
        app.exitFullScreen()
        disconnectAndDelete(app, host)
    }

    /// A file and a folder dragged from the Files app, beside this app on an iPad, onto the Mac's
    /// picture: the file let go over a folder on the Mac's desktop goes into it, and the folder let
    /// go on the desktop lands there with what is inside it. Then, with Files in Slide Over and this
    /// app in its own full screen, a drop on the menu bar, which takes nothing, copies nothing and
    /// says so in a banner inside the screen.
    ///
    /// The script that runs this (`Scripts/live-app-checks.sh`) puts `Drop Test` in On My iPad
    /// beforehand, with `wfh-drop-file.txt` and `wfh-drop-folder` (holding `a.txt` and
    /// `inner/b.txt`), and checks the Mac afterwards. `MARIONETTE_DROP_FOLDER_POSITION` is where the
    /// folder on the Mac's desktop shows (fractions across and down; by default where the test Mac
    /// shows `dnd`, first in a column sorted by name at the right edge).
    @MainActor
    func testDroppingFromTheFilesAppOntoTheMac() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("needs two apps side by side: iPad only") }
        let host = try host()
        let environment = ProcessInfo.processInfo.environment
        let folderAt = (environment["MARIONETTE_DROP_FOLDER_POSITION"] ?? "0.935,0.093").split(separator: ",").compactMap { Double($0) }
        XCTAssertEqual(folderAt.count, 2, "MARIONETTE_DROP_FOLDER_POSITION is two fractions: across,down")
        let app = launchAndAdd(host) { app in
            app.staticTexts["Connection"].tap()
            self.choose(app, picker: "Mode", option: "Standard")
        }
        let value = connect(app, host, expecting: "Standard")
        let display = try XCTUnwrap(Self.displaySize(in: value), "no display size in “\(value)”")
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let origin = springboard.coordinate(withNormalizedOffset: .zero)

        /// A place on the Mac's desktop, in fractions of its picture as it is fitted now.
        func place(_ across: CGFloat, _ down: CGFloat) -> XCUICoordinate {
            let stage = app.remoteDisplay.frame
            let scale = min(stage.width / CGFloat(display.width), stage.height / CGFloat(display.height))
            let size = CGSize(width: CGFloat(display.width) * scale, height: CGFloat(display.height) * scale)
            return origin.withOffset(CGVector(dx: stage.midX - size.width / 2 + size.width * across, dy: stage.midY - size.height / 2 + size.height * down))
        }
        func drag(_ name: String, to target: XCUICoordinate) {
            let item = files.cells.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch.waitToExist(15)
            item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 1.0, thenDragTo: target, withVelocity: .slow, thenHoldForDuration: 1.5)
        }
        func windowControls(_ bundle: String) -> XCUIElement {
            springboard.buttons["window-controls:\(bundle)"]
        }

        // This app and Files side by side. A window smaller than the screen shows the session
        // without bars already.
        files.activate()
        if !windowControls("com.apple.DocumentsApp").waitForExistence(timeout: 5) {
            // Full screen: a window first, by its resize grip.
            let grip = springboard.otherElements["resize-grabber"].firstMatch.waitToExist()
            let screen = springboard.windows.firstMatch.frame
            grip.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3))
                .press(forDuration: 0.3, thenDragTo: origin.withOffset(CGVector(dx: screen.width * 0.45, dy: screen.height * 0.9)))
        }
        windowControls("com.apple.DocumentsApp").waitToExist().press(forDuration: 1.2)
        springboard.buttons["Left and Right"].firstMatch.waitToExist().tap()
        Thread.sleep(forTimeInterval: 2)
        // Then this app on the left: the Mac's desktop icons are at its right edge, and a drag
        // held near the screen's edge crashes the iOS 27.0 simulator's backboardd.
        if app.windows.firstMatch.frame.minX > 10 {
            if !windowControls("llc.turing.Marionette").waitForExistence(timeout: 5) {
                save(app, "live-drop-tiled")
                print("LIVE DROP SPRINGBOARD: \(springboard.debugDescription.replacingOccurrences(of: "\n", with: " ⏎ "))")
                print("LIVE DROP WINDOWS: app \(app.windows.firstMatch.frame) files \(files.windows.firstMatch.frame)")
            }
            windowControls("llc.turing.Marionette").waitToExist().press(forDuration: 1.2)
            springboard.buttons["Left and Right"].firstMatch.waitToExist().tap()
            Thread.sleep(forTimeInterval: 2)
        }
        XCTAssertLessThan(app.windows.firstMatch.frame.minX, 10, "this app should be on the left")
        XCTAssertLessThan(app.windows.firstMatch.frame.width, springboard.windows.firstMatch.frame.width * 0.75, "this app should share the screen with Files")
        openDropTestFolder(in: files)
        Thread.sleep(forTimeInterval: 1)
        save(app, "live-drop-side-by-side")

        drag("wfh-drop-file", to: place(folderAt[0], folderAt[1]))
        Thread.sleep(forTimeInterval: 2)
        drag("wfh-drop-folder", to: place(0.35, 0.3))
        Thread.sleep(forTimeInterval: 2)
        save(app, "live-drop-after")
        XCTAssertFalse(app.staticTexts["Not Copied"].exists, "both drops should have been taken")

        // This app filling the screen in its own full screen, then Files in Slide Over above it
        // (in that order, with Files minimized meanwhile: either window of Files can cover the
        // full-screen button).
        windowControls("com.apple.DocumentsApp").waitToExist().press(forDuration: 1.2)
        springboard.buttons.matching(identifier: "Minimize-button").firstMatch.waitToExist().tap()
        Thread.sleep(forTimeInterval: 1)
        windowControls("llc.turing.Marionette").waitToExist().press(forDuration: 1.2)
        springboard.buttons["Fill"].firstMatch.waitToExist().tap()
        Thread.sleep(forTimeInterval: 2)
        // Filled, a window may still sit under the system's menu bar: smaller than the screen, it
        // shows the session without bars already and offers no full screen of its own.
        let ownFullScreen = app.buttons["enter-full-screen"].waitForExistence(timeout: 3)
        if ownFullScreen { app.enterFullScreen() }
        print("LIVE DROP FULL SCREEN: \(ownFullScreen ? "the app's own" : "a filled window under the menu bar"), window \(app.windows.firstMatch.frame)")
        files.activate()
        windowControls("com.apple.DocumentsApp").waitToExist().press(forDuration: 1.2)
        springboard.buttons["Enter Slide Over"].firstMatch.waitToExist().tap()
        Thread.sleep(forTimeInterval: 2)
        if !app.remoteDisplay.isHittable {
            app.activate()
            Thread.sleep(forTimeInterval: 2)
        }
        save(app, "live-drop-slide-over")
        XCTAssertTrue(files.cells.matching(NSPredicate(format: "label BEGINSWITH 'wfh-drop-file'")).firstMatch.isHittable, "Files should float over this app")

        // The menu bar takes no files: after the Mac's time to answer, a banner says nothing was copied.
        drag("wfh-drop-file", to: place(0.3, 0.012))
        let notCopied = app.staticTexts["Not Copied"]
        XCTAssertTrue(notCopied.waitForExistence(timeout: 10), "a drop the Mac does not take should say so")
        let banner = app.element("session-banner")
        save(app, "live-drop-refused-banner")
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(banner.frame), "the banner should be inside the window: \(banner.frame) in \(window)")
        XCTAssertGreaterThanOrEqual(banner.frame.minY, window.minY + 20, "the banner should clear the top edge: \(banner.frame)")
        print("LIVE DROP BANNER: \(banner.frame) in window \(window)")

        // Closed by its own button: a Slide Over whose app was quit stays as an empty frame.
        windowControls("com.apple.DocumentsApp").waitToExist().press(forDuration: 1.2)
        springboard.buttons.matching(identifier: "Close-button").firstMatch.waitToExist().tap()
        Thread.sleep(forTimeInterval: 2)
        if app.windows.firstMatch.frame.width < springboard.windows.firstMatch.frame.width || !app.buttons["more-menu"].isHittable {
            save(app, "live-drop-files-closed")
        }
        app.showControls()
        app.buttons["more-menu"].waitToExist().tap()
        app.buttons["open-files"].waitToExist().tap()
        let sent = NSPredicate(format: "label CONTAINS %@", "Sent")
        for name in ["wfh-drop-file.txt", "wfh-drop-folder"] {
            let row = app.element("transfer-\(name)")
            XCTAssertTrue(row.waitForExistence(timeout: 30), "\(name) should be on its way")
            XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: sent, object: row)], timeout: 120), .completed, "\(name): \(row.label)")
        }
        save(app, "live-drop-sent")
        app.buttons["Done"].tap()
        if ownFullScreen {
            app.exitFullScreen()
            disconnectAndDelete(app, host)
        } else {
            // A window has no title bar to leave from: the strip's More menu.
            app.showControls()
            app.buttons["more-menu"].waitToExist().tap()
            app.buttons["Disconnect"].waitToExist().tap()
            app.buttons["computer-\(host.address)"].waitToExist()
            delete(app, host)
        }
    }

    /// Opens On My iPad › Drop Test in the Files app, wherever it was left.
    @MainActor
    private func openDropTestFolder(in files: XCUIApplication) {
        if files.cells.matching(NSPredicate(format: "label BEGINSWITH 'wfh-drop-file'")).firstMatch.waitForExistence(timeout: 3) { return }
        let browse = files.buttons["Browse"]
        if browse.exists { browse.tap() }
        for _ in 0..<4 where !files.staticTexts["On My iPad"].exists && !files.cells.matching(NSPredicate(format: "label BEGINSWITH 'Drop Test'")).firstMatch.exists {
            let back = files.buttons["DOC.navBarButton.backInHistory"]
            guard back.exists, back.isEnabled else { break }
            back.tap()
        }
        let folder = files.cells.matching(NSPredicate(format: "label BEGINSWITH 'Drop Test'")).firstMatch
        if !folder.waitForExistence(timeout: 3) { files.staticTexts["On My iPad"].firstMatch.waitToExist().tap() }
        // The icon, not the name: tapping the name of a selected folder starts renaming it.
        folder.waitToExist().coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
    }

    /// High Performance across trips to the background, with something moving on the Mac (the
    /// script opens a Terminal window that prints the time):
    /// - away for 10 s, inside the grace period: the session resumes, with the picture moving
    ///   again and the display the size it was;
    /// - away for 45 s, past the grace period: the session ended cleanly while away and comes back
    ///   on its own;
    /// - away while the Mac drops the connection (the script ends the Mac's agent at the marker
    ///   `backgrounded`, and leaves `dropped`): it comes back on return too.
    @MainActor
    func testHighPerformanceAcrossTheBackground() throws {
        let host = try host()
        let app = launchAndAdd(host) { _ in }
        let first = connect(app, host, expecting: "High Performance")
        let display = Self.displaySize(in: first)
        XCTAssertTrue(pictureMoves(app), "the picture should move before leaving: is the Mac showing something that changes?")

        /// `sameDisplay`: a session that resumes keeps its display; one that reconnects sizes a new
        /// one to the space it has then.
        func away(for seconds: TimeInterval, step: String, sameDisplay: Bool) {
            XCUIDevice.shared.press(.home)
            Thread.sleep(forTimeInterval: seconds)
            app.activate()
            let value = waitConnected(app, expecting: "High Performance")
            XCTAssertTrue(pictureMoves(app), "\(step): the picture should move again")
            save(app, "live-background-\(step)")
            if sameDisplay, let display { XCTAssertEqual(Self.displaySize(in: value).map { [$0.width, $0.height] }, [display.width, display.height], "\(step): the display size changed") }
        }
        away(for: 10, step: "short", sameDisplay: true)
        away(for: 45, step: "long", sameDisplay: false)

        XCUIDevice.shared.press(.home)
        mark("backgrounded")
        XCTAssertTrue(waitForMarker("dropped", timeout: 60), "the script should drop the connection")
        Thread.sleep(forTimeInterval: 5)
        app.activate()
        _ = waitConnected(app, expecting: "High Performance")
        XCTAssertTrue(pictureMoves(app), "dropped: the picture should move again")
        save(app, "live-background-dropped")
        disconnectAndDelete(app, host)
    }

    /// On a device, where iOS suspends the app for real: away 10 s (inside the grace period) the
    /// session is there on return; away 45 s (past it) it was ended cleanly and comes back by
    /// itself. Needs nothing on the Mac, unlike testHighPerformanceAcrossTheBackground.
    @MainActor
    func testBackgroundOnADevice() throws {
        let host = try host()
        let app = launchAndAdd(host) { _ in }
        _ = connect(app, host, expecting: "High Performance")
        for seconds in [10.0, 45.0] {
            XCUIDevice.shared.press(.home)
            let left = Date()
            Thread.sleep(forTimeInterval: seconds)
            app.activate()
            let back = Date()
            let value = waitConnected(app, expecting: "High Performance")
            print("LIVE BACK AFTER \(Int(seconds)) s AWAY: connected again \(String(format: "%.1f", Date().timeIntervalSince(back) - 5)) s after returning; \(value)")
            save(app, "device-background-\(Int(seconds))")
            _ = left
        }
        disconnectAndDelete(app, host)
    }

    /// Whether two pictures of the remote display a second and a half apart differ.
    @MainActor
    private func pictureMoves(_ app: XCUIApplication) -> Bool {
        for _ in 0..<5 {
            let before = app.remoteDisplay.screenshot().pngRepresentation
            Thread.sleep(forTimeInterval: 1.5)
            if app.remoteDisplay.screenshot().pngRepresentation != before { return true }
        }
        return false
    }

    /// A fresh install on a device: the library looks for Macs nearby as soon as it appears, so iOS
    /// asks about the local network at launch. Once allowed, the library and the first connection
    /// work. Run with the app removed first.
    @MainActor
    func testFreshInstallAsksAboutTheLocalNetworkAtLaunch() throws {
        let host = try host()
        let app = XCUIApplication()
        app.launchArguments = ["-MarionetteDiagnostics"]
        app.launch()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // iOS 27 asks in a card of its own, not an alert.
        let allow = springboard.buttons["Allow"].firstMatch
        if allow.waitForExistence(timeout: 20) {
            print("LIVE LOCAL NETWORK QUESTION: asked when the library appeared")
            save(app, "device-local-network-question")
            allow.tap()
        } else {
            print("LIVE LOCAL NETWORK QUESTION: none seen (already answered?)")
        }
        let nearby = app.staticTexts["On This Network"]
        XCTAssertTrue(nearby.waitForExistence(timeout: 20), "the library should list Macs on this network")
        save(app, "device-library-nearby")
        app.terminate()
        let added = launchAndAdd(host) { _ in }
        let value = connect(added, host, expecting: "High Performance")
        print("LIVE SESSION VALUE AFTER ALLOWING: \(value)")
        save(added, "device-first-connection")
        disconnectAndDelete(added, host)
    }

    /// Picks a file from this app's own folder in the system document picker.
    @MainActor
    private func pick(_ app: XCUIApplication, file name: String) {
        let browse = app.buttons["Browse"]
        if browse.waitForExistence(timeout: 10) { browse.tap() }
        // Back out to the list of locations if the picker opened somewhere else.
        for _ in 0..<3 where !app.staticTexts["On My iPhone"].exists && !app.cells["On My iPhone"].exists {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            guard back.exists else { break }
            back.tap()
        }
        let onDevice = app.cells["On My iPhone"].exists ? app.cells["On My iPhone"] : app.staticTexts["On My iPhone"]
        onDevice.waitToExist(10).tap()
        let folder = app.cells["Marionette"].exists ? app.cells["Marionette"] : app.staticTexts["Marionette"]
        folder.waitToExist(10).tap()
        // The picker hides extensions.
        let stem = (name as NSString).deletingPathExtension
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", stem)).firstMatch
        if !item.waitForExistence(timeout: 15) {
            print("LIVE PICKER FOLDER: \(app.debugDescription.replacingOccurrences(of: "\n", with: " ⏎ "))")
        }
        item.waitToExist(1).tap()
        // With several files allowed, a pick is confirmed with Open.
        let open = app.buttons["Open"]
        if open.waitForExistence(timeout: 5) { open.tap() }
    }

    /// Waits for the script driving this test to leave a marker.
    private func waitForMarker(_ name: String, timeout: TimeInterval) -> Bool {
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "LiveMarkers/\(name)")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path) { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return false
    }

    /// Leaves a marker for the script driving this test.
    private func mark(_ name: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "LiveMarkers")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data().write(to: directory.appending(path: name))
    }

    // MARK: Steps

    /// Launches the live app and adds the test Mac through the editor, with `configure` making the
    /// changes a variant needs before saving.
    @MainActor
    private func launchAndAdd(_ host: Host, configure: (XCUIApplication) -> Void) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MarionetteDiagnostics"]
        app.launch()
        let card = app.buttons["computer-\(host.address)"]
        if card.waitForExistence(timeout: 5) { delete(app, host) }
        app.buttons["Add Computer"].firstMatch.waitToExist().tap()
        let address = app.textFields["address"].waitToExist()
        address.tap()
        address.typeText(host.address)
        let username = app.textFields["username"]
        username.tap()
        username.typeText(host.user)
        let secret = app.secureTextFields["password"]
        secret.tap()
        secret.typeText(host.password)
        configure(app)
        app.buttons["Add"].tap()
        // iOS may offer to save the password it just saw typed; the sheet takes the next tap.
        app.answerSavePasswordPrompt()
        card.waitToExist()
        return app
    }

    @MainActor
    private func choose(_ app: XCUIApplication, picker: String, option: String) {
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", picker)).firstMatch
        row.waitToExist().tap()
        app.buttons[option].waitToExist().tap()
    }

    @MainActor
    private func connect(_ app: XCUIApplication, _ host: Host, expecting status: String) -> String {
        app.buttons["computer-\(host.address)"].waitToExist().tap()
        return waitConnected(app, expecting: status)
    }

    /// Waits for the session to be up in the expected mode and returns the display's status text.
    @MainActor
    private func waitConnected(_ app: XCUIApplication, expecting status: String) -> String {
        app.remoteDisplay.waitToExist(90)
        let connected = NSPredicate(format: "value BEGINSWITH %@", status + ",")
        XCTAssertEqual(
            XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: connected, object: app.remoteDisplay)], timeout: 90),
            .completed,
            "expected “\(status)”, got “\(app.remoteDisplay.value as? String ?? "nil")”"
        )
        // Let real frames arrive, and a fitted display settle after its resize.
        Thread.sleep(forTimeInterval: 5)
        let value = app.remoteDisplay.value as? String ?? ""
        print("LIVE SESSION VALUE: \(value)")
        return value
    }

    @MainActor
    private func disconnectAndDelete(_ app: XCUIApplication, _ host: Host) {
        app.buttons["close-session"].waitToExist().tap()
        app.buttons["computer-\(host.address)"].waitToExist()
        delete(app, host)
    }

    @MainActor
    private func delete(_ app: XCUIApplication, _ host: Host) {
        delete(app, card: app.buttons["computer-\(host.address)"])
    }

    @MainActor
    private func delete(_ app: XCUIApplication, card: XCUIElement) {
        card.press(forDuration: 1.0)
        app.buttons["Delete"].waitToExist().tap()
        app.buttons["Delete Computer"].waitToExist().tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10))
    }

    @MainActor
    private func save(_ app: XCUIApplication, _ name: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Screenshots")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let screenshot = XCUIScreen.main.screenshot()
        try? screenshot.pngRepresentation.write(to: directory.appending(path: "\(name).png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// "display 804×1748" in the remote display's status text.
    private static func displaySize(in value: String) -> (width: Int, height: Int)? {
        guard let range = value.range(of: #"display (\d+)×(\d+)"#, options: .regularExpression) else { return nil }
        let numbers = value[range].dropFirst("display ".count).split(separator: "×").compactMap { Int($0) }
        return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
    }
}
