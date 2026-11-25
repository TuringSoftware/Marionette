// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

#if DEBUG
import MarionetteKit
import RemoteDesktopCore
import UIKit
import UniformTypeIdentifiers

/// Debug builds, launched with `-MarionetteMeasurePasteboard`: writes to the general pasteboard as
/// ClipboardBridge does (through SystemPasteboard, this device only) and records how the change
/// count moves for 3 s after each write, in Documents/pasteboard-measurement.txt. Answers whether
/// ClipboardBridge.ownWriteGrace is needed on a device; a test runner cannot measure this, since
/// iOS hides the pasteboard from apps that are not in front.
enum PasteboardMeasurement {
    @MainActor
    static func run() async {
        let pasteboard = SystemPasteboard()
        let text = UTType.utf8PlainText.identifier
        let png = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let cases: [(String, [ClipboardItem])] = [
            ("text", [ClipboardItem(representations: [text: Data("hello".utf8)])]),
            ("text+rtf+html", [ClipboardItem(representations: [text: Data("hi".utf8), UTType.rtf.identifier: Data("{\\rtf1 hi}".utf8), UTType.html.identifier: Data("<b>hi</b>".utf8)])]),
            ("url", [ClipboardItem(representations: [ClipboardConversion.url: Data("https://example.com".utf8), text: Data("https://example.com".utf8)])]),
            ("png", [ClipboardItem(representations: [UTType.png.identifier: png])]),
            ("two items", [ClipboardItem(representations: [text: Data("one".utf8)]), ClipboardItem(representations: [text: Data("two".utf8)])]),
            ("same text again", [ClipboardItem(representations: [text: Data("hello".utf8)])]),
        ]
        var lines = ["\(UIDevice.current.model) iOS \(UIDevice.current.systemVersion)"]
        for (name, items) in cases {
            let before = await pasteboard.changeCount
            let start = ContinuousClock.now
            await pasteboard.write(items, localOnly: true)
            let atReturn = await pasteboard.changeCount
            var later: [String] = []
            var last = atReturn
            while start.duration(to: .now) < .seconds(3) {
                try? await Task.sleep(for: .milliseconds(5))
                let count = await pasteboard.changeCount
                if count != last {
                    later.append("\(count) at \(start.duration(to: .now).formatted(.units(allowed: [.milliseconds])))")
                    last = count
                }
            }
            lines.append("\(name): before=\(before) after write=\(atReturn) later=\(later)")
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "pasteboard-measurement.txt")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
