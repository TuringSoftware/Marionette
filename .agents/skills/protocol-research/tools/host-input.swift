// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// Posts mouse and key events on this Mac, to drive Screen Sharing.app's window while a capture
// runs. Coordinates are global screen points. The terminal running it needs Accessibility
// permission. It moves the real pointer: nobody can use this Mac's mouse meanwhile.
//
//   swiftc -O -o host-input host-input.swift
//   host-input click X Y
//   host-input drag X1 Y1 X2 Y2
//   host-input key KEYCODE [cmd]         one event pair, flags set on it
//   host-input combo KEYCODE             ⌘ pressed and released as its own events, as a keyboard does
//   host-input wander X Y W H SECONDS    plain moves inside a rectangle, like a hand on a mouse
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments

func fail() -> Never {
    FileHandle.standardError.write(Data("usage: host-input click|drag|key|combo|wander …  (see the file's header)\n".utf8))
    exit(64)
}

func number(_ index: Int) -> Double {
    guard index < arguments.count, let value = Double(arguments[index]) else { fail() }
    return value
}

func point(_ index: Int) -> CGPoint { CGPoint(x: number(index), y: number(index + 1)) }

func mouse(_ type: CGEventType, _ location: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
    let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
    usleep(60000)
}

guard arguments.count > 1 else { fail() }
switch arguments[1] {
case "click":
    mouse(.mouseMoved, point(2))
    usleep(100_000)
    mouse(.leftMouseDown, point(2))
    usleep(80000)
    mouse(.leftMouseUp, point(2))
case "drag":
    let from = point(2), to = point(4)
    mouse(.mouseMoved, from)
    usleep(150_000)
    mouse(.leftMouseDown, from)
    // A Finder drag starts only if the pointer moves within about 0.5 s of the press.
    usleep(400_000)
    for step in 1...40 {
        let progress = Double(step) / 40
        mouse(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * progress, y: from.y + (to.y - from.y) * progress))
        usleep(30000)
    }
    usleep(500_000)
    mouse(.leftMouseUp, to)
case "key":
    let code = CGKeyCode(number(2))
    let flags: CGEventFlags = arguments.count > 3 && arguments[3] == "cmd" ? .maskCommand : []
    key(code, down: true, flags: flags)
    key(code, down: false, flags: flags)
case "combo":
    let code = CGKeyCode(number(2))
    let command: CGKeyCode = 55
    key(command, down: true, flags: .maskCommand)
    key(code, down: true, flags: .maskCommand)
    key(code, down: false, flags: .maskCommand)
    key(command, down: false, flags: [])
case "wander":
    let origin = point(2), width = number(4), height = number(5), seconds = number(6)
    let start = Date()
    while Date().timeIntervalSince(start) < seconds {
        let time = Date().timeIntervalSince(start)
        mouse(.mouseMoved, CGPoint(x: origin.x + width / 2 + cos(time * 1.3) * width * 0.4,
                                   y: origin.y + height / 2 + sin(time * 0.9) * height * 0.4))
        usleep(16000)
    }
default:
    fail()
}
