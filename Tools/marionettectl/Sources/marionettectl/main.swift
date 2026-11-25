// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0
//
// marionettectl — a headless client for exercising the back ends against real machines.

import AppleScreenSharing
import ARDProtocol
import CoreGraphics
import Foundation
import ImageIO
import RemoteDesktopCore
import RemoteDesktopTransport
import UniformTypeIdentifiers

struct Arguments {
    var command: String
    var host: String
    var port: UInt16 = 5900
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: [String]) throws {
        var positional: [String] = []
        var index = 0
        while index < raw.count {
            let argument = raw[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if index + 1 < raw.count, !raw[index + 1].hasPrefix("--") {
                    options[name] = raw[index + 1]
                    index += 1
                } else {
                    flags.insert(name)
                }
            } else {
                positional.append(argument)
            }
            index += 1
        }
        guard positional.count >= 2 else { throw UsageError() }
        command = positional[0]
        let target = positional[1]
        if let colon = target.lastIndex(of: ":"), let parsed = UInt16(target[target.index(after: colon)...]) {
            host = String(target[..<colon])
            port = parsed
        } else {
            host = target
        }
    }

    func option(_ name: String, environment: String? = nil) -> String? {
        options[name] ?? environment.flatMap { ProcessInfo.processInfo.environment[$0] }
    }
}

struct UsageError: Error {}
struct Failure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

let usage = """
usage: marionettectl <command> <host[:port]> [options]

commands:
  probe        log in and print what the Mac says about itself
  screenshot   capture the Mac's screen in Standard mode (Full quality) to a PNG
  hp           run a High Performance session and write its video to a file
  session      run a session through the back end the app uses; reports frames, cursor, sound
  proxy        stand between Screen Sharing.app and the Mac, recording what they say in plaintext
  transfer     send a file to the Mac or fetch one, with Screen Sharing's own file transfer

options:
  --user NAME        account name        (or MARIONETTE_TEST_USER)
  --password TEXT    account password    (or MARIONETTE_TEST_PASSWORD)
  --output FILE      where to write the PNG (screenshot)
  --display ID       share only this display (screenshot)
  --timeout SECONDS  give up after this long (default 20)
  --size WxH         virtual display size in points (hp; default 1440x900)
  --no-clamp         ask for exactly --size, beyond the limits a Mac VM accepts (hp)
  --scale N          1 or 2 (hp; default 2)
  --seconds N        how long to stream once pictures arrive (hp; default 5)
  --tiles N          pictures per frame to ask for (hp; default 1)
  --with-cursor      have the Mac draw the pointer into the video (hp)
  --decode           decode picture and sound with the system codecs, and save the last picture (hp)
  --backend B        apple (Screen Sharing's own protocol) or vnc (plain VNC) (session; default apple)
  --mode M           auto, hp or standard (session; default auto)
  --codec C          auto, hevc or h264: the picture codec High Performance asks for (session; default auto)
  --quality Q        adaptive or full, for Standard mode (session; default adaptive)
  --displays N       number of virtual displays (session; default 1)
  --physical WHICH   Standard mode on the Mac's own displays: all, or a display id (session)
  --resize WxH       resize the virtual displays after a second (session)
  --type TEXT        type text into the Mac (session)
  --copy TEXT        put text on the Mac's clipboard (session)
  --clipboard-dump   print every type and size of each clipboard the Mac announces (session)
  --loss PERCENT     drop this share of media datagrams, each way (session)
  --loss-after SECS  leave each media flow alone for this long first, so the session starts cleanly (session)
  --reorder PERCENT  deliver this share of media datagrams one place late (session)
  --burst N          a lost datagram takes up to N following ones with it (session)
  --seed N           which datagrams are affected; the same seed repeats a run (session)
  --bandwidth KBIT   media downlink rate in kbit/s, shared by every media flow (session)
  --uplink KBIT      media uplink rate in kbit/s (session)
  --queue MS         how long a datagram may queue in front of a rate limit before it is dropped
                     (session; default 100)
  --delay MS         one-way delay added to media datagrams, each way (session)
  --jitter MS        extra one-way delay of up to this much per datagram, which reorders (session)
  --tcp-bandwidth KBIT  control-channel rate in kbit/s, each way (session)
  --tcp-delay MS     one-way delay on the control channel (session)
  --tcp-stall PERCENT   share of control-channel segments that stall as if lost and resent (session)
  --change STEPS     change the conditions mid-session, e.g. "10:bandwidth=2000; 30:bandwidth=0,loss=2";
                     names are the options above without "--", 0 lifts a rate limit (session)
  --session-choice C when someone else is at the Mac's display: ask (them to share) or self (log in to
                     your own session) (session; default ask)
  --audio FILE       write the sound the Mac sends to a WAV file (session)
  --trace            print each step of the session's set-up and each media event (session, hp)
  --stats            print picture rate and bit rate every second (session)
  --ssh              run the session through an SSH tunnel to the same machine (session)
  --files            with --ssh, also list the home directory over SFTP (session)
  --listen PORT      local port Screen Sharing.app connects to (proxy; default 55900)
  --send FILE        file to send (transfer)
  --to DIR           folder on the Mac to send it to; ~ allowed (transfer; default ~/Downloads)
  --fetch PATH       absolute path on the Mac to fetch (transfer)
  --wait SECONDS     how long to listen for the Mac's answers (transfer; default 8)
  --short N          stop after N bytes, as a cancelled upload would (transfer)
  --again            then send the file again, whole (transfer)
  --plain-input      send keys and pointer events as plain RFB messages, not encrypted ones (session)
  --script STEPS     play input, e.g. "key:cmd+space; text:Terminal; key:return; wait:1500" (session)
"""

func connect(_ arguments: Arguments) async throws -> (ARDConnection, ARDConnection.Established) {
    guard let user = arguments.option("user", environment: "MARIONETTE_TEST_USER"),
          let password = arguments.option("password", environment: "MARIONETTE_TEST_PASSWORD")
    else { throw Failure("a user name and password are required (--user/--password or MARIONETTE_TEST_USER/MARIONETTE_TEST_PASSWORD)") }
    let provider = DirectTransportProvider(peer: Endpoint(host: arguments.host, port: arguments.port))
    let stream = try await provider.openStream(port: arguments.port)
    var configuration = ARDConnection.Configuration()
    // Experiment switches for protocol investigation.
    if arguments.flags.contains("clear") { configuration.encryptsSession = false }
    if arguments.flags.contains("no-viewer-info") { configuration.sendsViewerInfo = false }
    let connection = ARDConnection(stream: stream, configuration: configuration)
    let established = try await connection.handshake(username: user, password: password)
    return (connection, established)
}

func describe(_ established: ARDConnection.Established) {
    let serverInit = established.serverInit
    print("name:                  \(serverInit.name)")
    print("security types:        \(established.offeredSecurityTypes.map(\.description).joined(separator: ", "))")
    print("logged in with:        \(established.usedSecurityType)")
    print("framebuffer:           \(serverInit.framebufferWidth) × \(serverInit.framebufferHeight)")
    if let flags = serverInit.flags {
        var names: [String] = []
        if flags.contains(.observeOnly) { names.append("observe only") }
        if flags.contains(.mayControl) { names.append("may control") }
        if flags.contains(.sessionSelectFollows) { names.append("session select follows") }
        if flags.contains(.captureNotPermitted) { names.append("capture not permitted") }
        print(String(format: "flags:                 0x%x (%@)", flags.rawValue, names.joined(separator: ", ")))
        print("max virtual displays:  \(flags.maximumVirtualDisplays)")
    }
    if let accepted = serverInit.acceptedMessages {
        print("accepted messages:     \(accepted.types.map { String(format: "0x%02x", $0) }.joined(separator: " "))")
    }
    print("high performance:      \(serverInit.supportsHighPerformance ? "offered" : "not offered")")
    print("record layer:          established")
}

func writePNG(pixels: Data, size: PixelSize, to url: URL) throws {
    guard let provider = CGDataProvider(data: pixels as CFData),
          let image = CGImage(
              width: size.width, height: size.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.width * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
          ),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw Failure("could not create the image") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("could not write \(url.path)") }
}

func screenshot(_ arguments: Arguments) async throws {
    guard let output = arguments.option("output") else { throw Failure("--output is required") }
    let (connection, established) = try await connect(arguments)
    await connection.setPixelFormat(.bgrx)
    connection.send(ClientMessage.setEncodings(Encoding.standardFull))
    if let display = arguments.option("display").flatMap(UInt32.init) {
        connection.send(ClientMessage.setDisplay(display))
    }

    var framebuffer: Framebuffer?
    var covered = DamageRegion()
    var rectangles = 0
    var compressedBytes = 0
    var poked = false
    var pokedAt: ContinuousClock.Instant?
    let started = ContinuousClock.now

    events: while let event = try await connection.nextEvent() {
        if case .status(let status) = event, arguments.flags.contains("poke") { print("status \(status.rawValue)") }
        guard case .rectangle(let rectangle) = event else { continue }
        let header = rectangle.header
        if arguments.flags.contains("poke") {
            switch rectangle.body {
            case .cursorPosition: print("cursor position \(header.x),\(header.y)")
            case .zlib, .raw: break
            default: print("rectangle \(header.encoding)")
            }
        }
        let rect = PixelRect(x: Int(header.x), y: Int(header.y), width: Int(header.width), height: Int(header.height))
        switch rectangle.body {
        case .displayLayout(let layout):
            let size = PixelSize(width: layout.framebufferWidth, height: layout.framebufferHeight)
            print("layout: \(size.width) × \(size.height), \(layout.screens.count) screen(s), current \(layout.currentScreen.map(String.init) ?? "all"), flags 0x\(String(layout.flags.rawValue, radix: 16))")
            for screen in layout.screens {
                print("  screen \(screen.id): \(screen.pointWidth) × \(screen.pointHeight) pt at \(screen.density)x, pixels \(screen.pixelWidth) × \(screen.pixelHeight) at (\(screen.pixelLeft), \(screen.pixelTop))")
            }
            if framebuffer == nil { framebuffer = Framebuffer(size: size) } else { framebuffer?.resize(to: size) }
            covered = DamageRegion()
            // A layout drops the Mac's update arming; arm again, then ask for everything once.
            connection.send(ClientMessage.autoFramebufferUpdate(interval: .zero, width: UInt16(size.width), height: UInt16(size.height)))
            connection.send(ClientMessage.framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: UInt16(size.width), height: UInt16(size.height)))
        case .zlib(let chunk):
            guard let framebuffer else { throw Failure("pixels arrived before a layout") }
            try framebuffer.writeZlib(chunk, to: rect)
            covered.add(rect)
            rectangles += 1
            compressedBytes += chunk.count
        case .raw(let pixels):
            guard let framebuffer else { throw Failure("pixels arrived before a layout") }
            try framebuffer.write(pixels, to: rect)
            covered.add(rect)
            rectangles += 1
        case .zrle, .adaptive:
            throw Failure("the Mac sent \(header.encoding), which Full quality does not ask for")
        default:
            break
        }
        if let framebuffer, covered.bounds == PixelRect(size: framebuffer.size), covered.rectangles.count == 1 {
            if arguments.flags.contains("poke"), !poked {
                // Diagnostic: raw input straight onto the connection, then keep reading for a while.
                poked = true
                // Moves at several delays, each to its own position, to see which ones the Mac applies.
                let plan = (arguments.option("poke-plan") ?? "0:300,300;1000:500,500;3000:700,700").split(separator: ";")
                var elapsed = 0
                for step in plan {
                    let parts = step.split(separator: ":")
                    let at = Int(parts[0]) ?? 0
                    let xy = parts[1].split(separator: ",").compactMap { UInt16($0) }
                    try await Task.sleep(for: .milliseconds(max(0, at - elapsed)))
                    elapsed = at
                    if parts.count > 2, parts[2] == "arm" {
                        // Re-arm updates and ask for the whole screen again, as after a layout.
                        connection.send(ClientMessage.autoFramebufferUpdate(interval: .zero, width: 2048, height: 1536))
                        connection.send(ClientMessage.framebufferUpdateRequest(incremental: false, x: 0, y: 0, width: 2048, height: 1536))
                    } else if parts.count > 2, parts[2] == "encodings" {
                        connection.send(ClientMessage.setEncodings(Encoding.standardFull))
                    } else if parts.count > 2, parts[2] == "key" {
                        // ms:0,0:key:<keysym hex>:<1 down, 0 up>
                        let keysym = parts.count > 3 ? (UInt32(parts[3], radix: 16) ?? Keysym.shiftLeft) : Keysym.shiftLeft
                        connection.send(ClientMessage.keyEvent(keysym: keysym, isDown: parts.count > 4 && parts[4] == "1"))
                    } else {
                        connection.send(ClientMessage.pointerEvent(buttonMask: parts.count > 2 ? (UInt8(parts[2]) ?? 0) : 0, x: xy[0], y: xy[1]))
                    }
                }
                pokedAt = .now
                print("poked the Dock at 1728,1475")
                continue events
            }
            if let pokedAt, ContinuousClock.now - pokedAt < .seconds(3) { continue events }
            break events
        }
    }

    guard let framebuffer, covered.bounds == PixelRect(size: framebuffer.size) else {
        throw Failure("the connection ended before a whole frame arrived")
    }
    let elapsed = ContinuousClock.now - started
    try writePNG(pixels: framebuffer.copyPixels(), size: framebuffer.size, to: URL(fileURLWithPath: output))
    print("\(established.serverInit.name): \(framebuffer.size.width) × \(framebuffer.size.height), \(rectangles) rectangle(s), \(compressedBytes) compressed bytes, \(elapsed)")
    print("wrote \(output)")
    await connection.close()
}

func run() async -> Int32 {
    do {
        let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
        if arguments.command == "proxy" {
            // Runs until the viewer or the Mac hangs up: no watchdog.
            try runProxy(arguments)
            return 0
        }
        let timeout = Duration.seconds(Double(arguments.option("timeout") ?? "") ?? 20)
        let work = Task {
            switch arguments.command {
            case "probe":
                let (connection, established) = try await connect(arguments)
                describe(established)
                await connection.close()
            case "screenshot":
                try await screenshot(arguments)
            case "hp":
                try await highPerformance(arguments)
            case "session":
                try await runSession(arguments)
            case "transfer":
                try await runTransfer(arguments)
            default:
                throw UsageError()
            }
        }
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            FileHandle.standardError.write(Data("marionettectl: timed out after \(timeout)\n".utf8))
            exit(2)
        }
        defer { watchdog.cancel() }
        try await work.value
        return 0
    } catch is UsageError {
        FileHandle.standardError.write(Data((usage + "\n").utf8))
        return 64
    } catch {
        FileHandle.standardError.write(Data("marionettectl: \(error)\n".utf8))
        return 1
    }
}

exit(await run())
