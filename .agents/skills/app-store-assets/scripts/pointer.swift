// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// Moves and clicks this Mac's pointer, for windows that offer no accessibility elements to click by
// (DeviceHub). Positions are in points from the top left of the main display.
//
//   swiftc -O pointer.swift -o <somewhere outside the repository>/pointer
//   pointer move X Y
//   pointer click X Y

import CoreGraphics
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3, ["move", "click"].contains(arguments[0]), let x = Double(arguments[1]), let y = Double(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: pointer move|click X Y\n".utf8))
    exit(2)
}
let position = CGPoint(x: x, y: y)
let source = CGEventSource(stateID: .hidSystemState)

func post(_ type: CGEventType) {
    CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: .left)?.post(tap: .cghidEventTap)
    // A window ignores a press that follows the pointer's arrival too closely.
    usleep(60_000)
}

post(.mouseMoved)
if arguments[0] == "click" {
    post(.leftMouseDown)
    post(.leftMouseUp)
}
