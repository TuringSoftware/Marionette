// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import XCTest

/// Not a test: brings the app to each state the App Store's pictures show, for
/// `Scripts/store-assets.sh capture`, which takes the pictures. The two talk through a folder on
/// the Mac that runs the simulator: a file `<name>.request` appears there, the script captures the
/// simulator's display, and the test goes on when `<name>.done` answers. The script captures the
/// framebuffer itself, so a picture has the display's exact pixels on every device, the inner
/// display of an open iPhone Duo included.
///
/// Opt-in, from environment variables passed to the runner (`TEST_RUNNER_` prefix):
///
/// - `MARIONETTE_STORE_CAPTURES`: the folder. Without it every method skips itself.
/// - `MARIONETTE_STORE_THUMBNAILS`: the folder of `-MarionetteThumbnails`, for the library.
/// - `MARIONETTE_STORE_COMPUTER`: the library name of the real computer the session pictures open
///   (default "Mac VM", as `ManualTestSetup` names it).
/// - `MARIONETTE_STORE_TURNS`: "0" where the simulator ignores rotation (an iPhone Duo), so that
///   the session pictures take the device as it stands.
/// - `MARIONETTE_STORE_LIBRARY_LANDSCAPE`: "1" turns the library on its side.
/// - `MARIONETTE_STORE_HOLD`: seconds for which `testDocked` keeps its state on screen.
final class StoreScreenshots: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var computer: String { environment["MARIONETTE_STORE_COMPUTER"] ?? "Mac VM" }
    private var turns: Bool { environment["MARIONETTE_STORE_TURNS"] != "0" }

    override func setUpWithError() throws {
        try XCTSkipIf(environment["MARIONETTE_STORE_CAPTURES"] == nil, "run through Scripts/store-assets.sh capture")
        continueAfterFailure = true
        // A session must not be left holding the Mac, nor the simulator on its side.
        addTeardownBlock { @MainActor in
            XCUIDevice.shared.orientation = .portrait
            XCUIApplication().terminate()
        }
    }

    // MARK: Talking to the script

    /// Writes `<name>.request` and waits for `<name>.done`. Returns whether the answer came.
    @discardableResult
    private func ask(_ name: String, timeout: TimeInterval = 60, required: Bool = true) -> Bool {
        let folder = URL(fileURLWithPath: environment["MARIONETTE_STORE_CAPTURES"] ?? "")
        let request = folder.appending(path: "\(name).request"), done = folder.appending(path: "\(name).done")
        try? FileManager.default.removeItem(at: done)
        XCTAssertTrue(FileManager.default.createFile(atPath: request.path, contents: Data()), "could not write \(request.path)")
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: done.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let answered = FileManager.default.fileExists(atPath: done.path)
        if required { XCTAssertTrue(answered, "the script did not answer \(name)") }
        return answered
    }

    /// Asks for a picture, once the last layout pass and a fresh remote frame have reached the screen.
    private func capture(_ name: String, settle: TimeInterval = 1.0) {
        Thread.sleep(forTimeInterval: settle)
        ask(name)
    }

    // MARK: The library

    @MainActor
    func testLibrary() {
        let app = XCUIApplication()
        app.launchArguments = ["-MarionetteUITestMode", "-MarionetteScenario", "showcase", "-MarionetteAppearance", "light"]
        if let thumbnails = environment["MARIONETTE_STORE_THUMBNAILS"] { app.launchArguments += ["-MarionetteThumbnails", thumbnails] }
        if environment["MARIONETTE_STORE_LIBRARY_LANDSCAPE"] == "1" { XCUIDevice.shared.orientation = .landscapeLeft }
        app.launch()
        app.buttons["computer-Studio Mac"].waitToExist()
        app.staticTexts["On This Network"].waitToExist()
        capture("library", settle: 2.0)
    }

    // MARK: A session with a real computer

    /// Opens the computer, and with `tidy` goes full screen without an input panel: the app
    /// remembers both from the last session.
    @MainActor
    private func openSession(tidy: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-MarionetteDiagnostics", "-MarionetteAppearance", "light"]
        app.launch()
        app.buttons["computer-\(computer)"].waitToExist(30).tap()
        app.remoteDisplay.waitToExist(90)
        if !app.waitForRemoteDisplay(containing: "High Performance", timeout: 60) {
            print("STORE not High Performance: \(app.remoteDisplay.value as? String ?? "")")
        }
        if tidy {
            if app.buttons["enter-full-screen"].waitForExistence(timeout: 8) { app.enterFullScreen() }
            app.showInputPanel("Hidden")
        }
        return app
    }

    /// The part of the remote display's value that names the Mac's display, "display 2624×1208".
    @MainActor
    private func displayShape(_ app: XCUIApplication) -> String {
        let value = app.remoteDisplay.value as? String ?? ""
        return value.range(of: #"display \d+×\d+"#, options: .regularExpression).map { String(value[$0]) } ?? value
    }

    /// Turns the device, and waits for the display the Mac makes for the new shape. The Mac ignores
    /// input for a moment afterwards.
    @MainActor
    private func turn(_ app: XCUIApplication, to orientation: UIDeviceOrientation) {
        guard turns, XCUIDevice.shared.orientation != orientation else { return }
        let before = displayShape(app)
        XCUIDevice.shared.orientation = orientation
        let deadline = Date().addingTimeInterval(20)
        while displayShape(app) == before, Date() < deadline { Thread.sleep(forTimeInterval: 0.5) }
        Thread.sleep(forTimeInterval: 3)
    }

    /// Brings the Mac's document window forward and takes the Mac's pointer off the edge where its
    /// Dock hides. The script does the first from its side ("activate" asks for no picture),
    /// because a touch does not always: it has been seen to leave the window behind on an
    /// iPhone Duo held upright. The touch is on the window's title bar, which is a tenth of the way
    /// down every display the window opens on; in the text it would move the insertion point or
    /// select a line.
    @MainActor
    private func pointAtDocument(_ app: XCUIApplication) {
        ask("activate", timeout: 15)
        app.remoteDisplay.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.1)).tap()
        Thread.sleep(forTimeInterval: 1.2)
    }

    /// Takes the three pictures of the control strip: open, folded to its handle, and after the
    /// handle has faded.
    @MainActor
    private func captureStrip(_ app: XCUIApplication, as name: String) {
        app.showControls()
        pointAtDocument(app)
        capture("\(name)-toolbar", settle: 0.8)
        app.buttons["collapse-controls"].waitToExist().tap()
        app.buttons["expand-controls"].waitToExist()
        // The handle fades a few seconds after the last touch, so this picture cannot wait long.
        pointAtDocument(app)
        capture("\(name)-chevron", settle: 0.3)
        _ = app.buttons["expand-controls"].waitForNonExistence(timeout: 20)
        capture("\(name)-clean", settle: 1.0)
    }

    @MainActor
    func testSessionLandscape() {
        let app = openSession()
        turn(app, to: .landscapeLeft)
        print("STORE \(displayShape(app))")
        captureStrip(app, as: "session-landscape")
    }

    @MainActor
    func testSessionKeyboard() {
        let app = openSession()
        turn(app, to: .portrait)
        app.showInputPanel("System Keyboard")
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 10)
        print("STORE \(displayShape(app))")
        // The picture moves to stay clear of the keyboard.
        Thread.sleep(forTimeInterval: 3)
        captureStrip(app, as: "session-keyboard")
    }

    /// The laptop pose of a half-open iPhone Duo, which is set in DeviceHub before this runs: the
    /// picture above the fold and the input deck below it. Touches from here miss their controls in
    /// that pose, so the session is only opened, and held for a person to finish in DeviceHub, who
    /// then answers `hold`.
    @MainActor
    func testDocked() {
        let app = openSession(tidy: false)
        print("STORE \(displayShape(app))")
        capture("docked", settle: 3.0)
        if let hold = environment["MARIONETTE_STORE_HOLD"].flatMap(TimeInterval.init) {
            ask("hold", timeout: hold, required: false)
        }
    }
}
