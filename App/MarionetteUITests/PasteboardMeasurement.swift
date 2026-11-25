// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import UIKit
import UniformTypeIdentifiers
import XCTest

/// Measures how the general pasteboard's change count moves after one write, the question behind
/// ClipboardBridge.ownWriteGrace. Runs only when asked (MARIONETTE_MEASURE_PASTEBOARD=1): it
/// overwrites the clipboard, and in a simulator with Simulator.app open, the Mac's clipboard too.
final class PasteboardMeasurement: XCTestCase {
    @MainActor
    func testChangeCountAfterOneWrite() async throws {
        guard ProcessInfo.processInfo.environment["MARIONETTE_MEASURE_PASTEBOARD"] == "1" else {
            throw XCTSkip("set MARIONETTE_MEASURE_PASTEBOARD=1 to measure (it overwrites the clipboard)")
        }
        let text = UTType.utf8PlainText.identifier
        let png = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let cases: [(String, [[String: Any]])] = [
            ("text", [[text: Data("hello".utf8)]]),
            ("text+rtf+html", [[text: Data("hi".utf8), UTType.rtf.identifier: Data("{\\rtf1 hi}".utf8), UTType.html.identifier: Data("<b>hi</b>".utf8)]]),
            ("url", [[UTType.url.identifier: URL(string: "https://example.com")!, text: Data("https://example.com".utf8)]]),
            ("png", [[UTType.png.identifier: png]]),
            ("two items", [[text: Data("one".utf8)], [text: Data("two".utf8)]]),
            ("same text again", [[text: Data("hello".utf8)]]),
        ]
        for localOnly in [true] {
            for (name, items) in cases {
                let before = UIPasteboard.general.changeCount
                let start = ContinuousClock.now
                UIPasteboard.general.setItems(items, options: [.localOnly: localOnly])
                let atReturn = UIPasteboard.general.changeCount
                var later: [String] = []
                var last = atReturn
                while start.duration(to: .now) < .seconds(3) {
                    try await Task.sleep(for: .milliseconds(5))
                    let count = UIPasteboard.general.changeCount
                    if count != last {
                        later.append("\(count) at \(start.duration(to: .now).formatted(.units(allowed: [.milliseconds])))")
                        last = count
                    }
                }
                print("MEASURE \(UIDevice.current.systemVersion) \(name) localOnly=\(localOnly): before=\(before) atReturn=\(atReturn) later=\(later)")
            }
        }
    }
}
