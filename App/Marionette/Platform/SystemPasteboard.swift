// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import UIKit
import UniformTypeIdentifiers
import MarionetteKit

/// The general pasteboard, as MarionetteKit sees it. ``ClipboardConversion`` decides which types
/// travel; this only turns the values UIKit hands out into data and back.
struct SystemPasteboard: LocalPasteboard {
    var changeCount: Int {
        get async { await MainActor.run { UIPasteboard.general.changeCount } }
    }

    /// Asking which types are present does not trigger the paste prompt; reading them would.
    var isConcealed: Bool {
        get async { await MainActor.run { UIPasteboard.general.contains(pasteboardTypes: [PasteboardType.concealed]) } }
    }

    /// Everything copied here that a Mac can use: text, rich text, web content, links and images.
    func read() async -> [ClipboardItem] {
        await MainActor.run {
            UIPasteboard.general.items.compactMap { item in
                var values: [String: Any] = [:]
                for (type, value) in item {
                    guard let image = value as? UIImage else {
                        values[type] = value
                        continue
                    }
                    // UIKit hands some images out as images rather than data: they go as JPEG if
                    // that is what they were, and as PNG otherwise.
                    if type == UTType.jpeg.identifier {
                        values[type] = image.jpegData(compressionQuality: 0.9)
                    } else if values[UTType.png.identifier] == nil {
                        values[UTType.png.identifier] = image.pngData()
                    }
                }
                return ClipboardConversion.outgoing(values)
            }
        }
    }

    func write(_ items: [ClipboardItem], localOnly: Bool) async {
        await MainActor.run {
            let pasteboardItems: [[String: Any]] = items.map { item in
                var representations: [String: Any] = [:]
                for (type, data) in item.representations {
                    // Apps read a link as a URL object; every other type is taken as it is.
                    if type == ClipboardConversion.url, let url = URL(string: String(decoding: data, as: UTF8.self)) {
                        representations[type] = url
                    } else {
                        representations[type] = data
                    }
                }
                return representations
            }
            UIPasteboard.general.setItems(pasteboardItems, options: [.localOnly: localOnly])
        }
    }
}
