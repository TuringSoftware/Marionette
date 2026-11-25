// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import ARDProtocol
import ARDTestSupport
import Foundation
import Testing

/// Bytes marked "captured" were sent by Screen Sharing on macOS 27.0.
@Suite struct HandshakeTests {
    @Test func versionRoundTrip() throws {
        #expect(ProtocolVersion.apple.encoded == Data("RFB 003.889\n".utf8))
        var reader = WireReader(Data("RFB 003.889\n".utf8))
        #expect(try ProtocolVersion.parse(&reader) == .apple)
        var plain = WireReader(Data("RFB 003.008\n".utf8))
        #expect(try ProtocolVersion.parse(&plain) == ProtocolVersion(major: 3, minor: 8))
    }

    @Test(arguments: ["RFB 003.889 ", "HTTP/1.1 200", "RFB 3.889\n\n\n", "RFB 00a.889\n"])
    func versionRejectsGarbage(_ line: String) {
        var reader = WireReader(Data(line.utf8))
        #expect(throws: WireError.self) { try ProtocolVersion.parse(&reader) }
    }

    @Test func capturedSecurityOffer() throws {
        var reader = WireReader(Data(hex: "04 1e 21 24 23"))
        #expect(try SecurityOffer.parse(&reader) == .types([.diffieHellman, .rsa, .srp, .kerberos]))
    }

    @Test func securityRefusalCarriesReason() throws {
        var reader = WireReader(Data(hex: "00 00000004") + Data("busy".utf8))
        #expect(try SecurityOffer.parse(&reader) == .refused(reason: "busy"))
        var huge = WireReader(Data(hex: "00 7fffffff"))
        #expect(throws: WireError.malformed("refusal reason of 2147483647 bytes")) { try SecurityOffer.parse(&huge) }
    }

    static let capturedServerInit = Data(hex: """
        0800 0600 2018000100ff00ff00ff100800000000 00000020
        000000000052bff6e72fec000000000000000000000053747564696f204d6163
        """)

    @Test func capturedExtendedServerInit() throws {
        var reader = WireReader(Self.capturedServerInit)
        let initMessage = try ServerInit.parse(&reader, extended: true)
        #expect(reader.isAtEnd)
        #expect(initMessage.framebufferWidth == 2048)
        #expect(initMessage.framebufferHeight == 1536)
        #expect(initMessage.pixelFormat == .bgrx)
        #expect(initMessage.name == "Studio Mac")
        let flags = try #require(initMessage.flags)
        #expect(flags.contains(.mayControl))
        #expect(flags.contains(.extended))
        #expect(!flags.contains(.observeOnly))
        #expect(!flags.contains(.sessionSelectFollows))
        #expect(flags.maximumVirtualDisplays == 2)
        let accepted = try #require(initMessage.acceptedMessages)
        #expect(accepted.contains(ClientMessageType.setDisplayConfiguration))
        #expect(accepted.contains(ClientMessageType.mediaOffer))
        #expect(accepted.contains(ClientMessageType.event2))
        #expect(accepted.contains(ClientMessageType.setEncryption))
        #expect(accepted.contains(ClientMessageType.viewerInfo))
        #expect(!accepted.contains(0x01))
        #expect(accepted.types.count == 29)
        #expect(initMessage.supportsHighPerformance)
    }

    @Test func plainServerInitKeepsWholeName() throws {
        var writer = WireWriter()
        writer.u16(1024)
        writer.u16(768)
        PixelFormat.bgrx.write(to: &writer)
        writer.u32(9)
        writer.bytes("Linux box".utf8)
        var reader = WireReader(writer.data)
        let initMessage = try ServerInit.parse(&reader, extended: true)
        #expect(initMessage.name == "Linux box")
        #expect(initMessage.flags == nil)
        #expect(!initMessage.supportsHighPerformance)
    }

    /// wayshare's extended form: the zero word and the bitmap, but a flags word that is only the
    /// display count, without the bit a Mac sets.
    @Test func wayshareServerInitIsTheExtendedForm() throws {
        var writer = WireWriter()
        writer.u16(1920)
        writer.u16(1080)
        PixelFormat.bgrx.write(to: &writer)
        var field = WireWriter()
        field.u16(0)
        field.u32(1 << 5)
        field.bytes(Data(MessageBitmap(types: [0, 2, 3, 4, 5, 6, 9, 33], byteCount: 16).bytes))
        field.bytes("ubuntu".utf8)
        writer.u32(UInt32(field.data.count))
        writer.bytes(field.data)
        var reader = WireReader(writer.data)
        let initMessage = try ServerInit.parse(&reader, extended: true)
        #expect(initMessage.name == "ubuntu")
        #expect(initMessage.flags?.maximumVirtualDisplays == 1)
        #expect(initMessage.acceptedMessages?.contains(33) == true)
        #expect(initMessage.acceptedMessages?.contains(ClientMessageType.setEncryption) == false)
        #expect(!initMessage.supportsHighPerformance)
    }

    @Test func serverInitRejectsAbsurdName() {
        var writer = WireWriter()
        writer.u16(1)
        writer.u16(1)
        PixelFormat.bgrx.write(to: &writer)
        writer.u32(0x4000_0000)
        var reader = WireReader(writer.data)
        #expect(throws: WireError.malformed("ServerInit name of 1073741824 bytes")) {
            try ServerInit.parse(&reader, extended: true)
        }
    }

    @Test func messageBitmapIsMostSignificantBitFirst() {
        var bitmap = MessageBitmap(types: [0, 9, 0x1d], byteCount: 16)
        #expect(bitmap.bytes[0] == 0x80)
        #expect(bitmap.bytes[1] == 0x40)
        #expect(bitmap.bytes[3] == 0x04)
        #expect(bitmap.contains(0x1d))
        #expect(!bitmap.contains(0x1c))
        #expect(!bitmap.contains(200))
        bitmap.insert(200)
        #expect(bitmap.types == [0, 9, 0x1d])
    }
}

@Suite struct ClientMessageTests {
    @Test func viewerInfoMatchesAppleViewer() {
        let message = ClientMessage.viewerInfo()
        #expect(message.count == 66)
        #expect(message.hex == "2100003e" + "0001" + "00000002" + "00000006" + "00000001" + "00000000"
            + "0000001a" + "00000006" + "00000002"
            + "b0000c0390000000000040000000000000000000000000000000000000000000")
    }

    @Test func fixedControlMessages() {
        #expect(ClientMessage.startEncryption().hex == "120000010001000100000001")
        #expect(ClientMessage.enableInboundDecryption().hex == "1200000200010000")
        #expect(ClientMessage.setMode(.control).hex == "0a000001")
        #expect(ClientMessage.autoPasteboard(true).hex == "1500000100000000")
        #expect(ClientMessage.autoPasteboard(false).hex == "1500000200000000")
        #expect(ClientMessage.pasteboardFetch(token: 0xDEAD_BEEF).hex == "0b000000deadbeef")
        #expect(ClientMessage.setDisplay(nil).hex == "0d01000000000000")
        #expect(ClientMessage.setDisplay(4).hex == "0d00000000000004")
        #expect(ClientMessage.setServerScaling(0.5).hex == "08003fe0000000000000")
        #expect(ClientMessage.clientInit([.shared, .extended]).hex == "81")
    }

    @Test func standardRFBMessages() {
        #expect(ClientMessage.setPixelFormat(.bgrx).hex == "00000000" + "2018000100ff00ff00ff100800000000")
        #expect(ClientMessage.setEncodings([.zlib, .appleDisplayLayout, .lastRect]).hex == "02000003" + "00000006" + "00000451" + "ffffff20")
        #expect(ClientMessage.framebufferUpdateRequest(incremental: true, x: 1, y: 2, width: 3, height: 4).hex == "03010001000200030004")
        #expect(ClientMessage.keyEvent(keysym: 0xFF0D, isDown: true).hex == "040100000000ff0d")
        #expect(ClientMessage.pointerEvent(buttonMask: 0x02, x: 300, y: 5).hex == "0502012c0005")
    }

    @Test func autoFramebufferUpdateIntervals() {
        #expect(ClientMessage.autoFramebufferUpdate(interval: .zero, width: 2048, height: 1536).hex == "09000001" + "00000000" + "00000000" + "08000600")
        #expect(ClientMessage.autoFramebufferUpdate(interval: .seconds(1), width: 1, height: 1).hex == "09000001" + "000f4240" + "00000000" + "00010001")
        #expect(ClientMessage.autoFramebufferUpdate(interval: nil, width: 1, height: 1).hex == "09000001" + "ffffffff" + "00000000" + "00010001")
    }

    @Test func scrollCarriesDistanceInEveryForm() throws {
        let message = ClientMessage.scroll(deltaX: 40, deltaY: -25, x: 640, y: 480)
        #expect(message.count == 58)
        var reader = WireReader(message)
        #expect(try reader.u8() == 0x17)
        #expect(try reader.u8() == 0)
        #expect(try reader.u16() == 54)
        #expect(try reader.u16() == 1)
        #expect(try reader.u16() == 11)
        #expect(try [reader.i16(), reader.i16(), reader.i16()] == [4, -2, 0])
        #expect(try [reader.i32(), reader.i32(), reader.i32()] == [4 * 65536, -25 * 65536 / 10, 0])
        #expect(try [reader.i32(), reader.i32(), reader.i32()] == [40, -25, 0])
        #expect(try [reader.u32(), reader.u32(), reader.u32()] == [0, 0, 0])
        #expect(try reader.u32() == 2)
        #expect(try [reader.u16(), reader.u16()] == [640, 480])
        #expect(reader.isAtEnd)
    }

    @Test func displayConfigurationLayout() throws {
        let mode = VirtualDisplayMode.fitting(pointWidth: 1440, pointHeight: 900, scale: 2)
        let message = ClientMessage.setDisplayConfiguration([mode, mode], dynamic: true)
        let descriptor = 0x9c + 5 * 0x1c
        #expect(message.count == 4 + 8 + 2 * descriptor)
        var reader = WireReader(message)
        #expect(try reader.u8() == 0x1d)
        #expect(try reader.u8() == 0)
        #expect(try reader.u16() == UInt16(8 + 2 * descriptor))
        #expect(try reader.u16() == 1)
        #expect(try reader.u16() == 2)
        #expect(try reader.u32() == 0)
        for index in 0..<2 {
            var entry = try reader.sub(descriptor)
            #expect(try entry.u16() == UInt16(descriptor))
            let name = try entry.take(120)
            let expected = index == 0 ? "Screen Sharing Virtual Display" : "Screen Sharing Virtual Display #2"
            #expect(String(decoding: name.prefix { $0 != 0 }, as: UTF8.self) == expected)
            #expect(try entry.u32() == 1) // dynamic
            #expect(try entry.u32() == 0)
            let widthMM = Float(bitPattern: try entry.u32())
            let heightMM = Float(bitPattern: try entry.u32())
            #expect(abs(widthMM - 369.45) < 0.01)
            #expect(abs(heightMM - 207.82) < 0.01)
            #expect(try [entry.u32(), entry.u32()] == [3840, 2160])
            #expect(try [entry.u16(), entry.u16()] == [0, 0])
            #expect(try entry.u32() == 7)
            #expect(try entry.u16() == 5)
            #expect(try [entry.u32(), entry.u32(), entry.u32(), entry.u32()] == [2880, 1800, 1440, 900])
            #expect(try entry.f64() == 60)
            #expect(try entry.u32() == 0)
            #expect(entry.remaining == 4 * 0x1c)
        }
        #expect(reader.isAtEnd)
    }

    @Test func virtualModeIsHeldWithinWhatAMacAccepts() {
        // Too small for a 2x display: the same pixels at 1x, which a Mac does make.
        let small = VirtualDisplayMode.fitting(pointWidth: 320, pointHeight: 200, scale: 2)
        #expect([small.pointWidth, small.pointHeight, small.pixelWidth, small.pixelHeight] == [640, 400, 640, 400])
        let phone = VirtualDisplayMode.fitting(pointWidth: 402, pointHeight: 874, scale: 2)
        #expect([phone.pointWidth, phone.pointHeight, phone.pixelWidth, phone.pixelHeight] == [804, 1748, 804, 1748])
        let upright = VirtualDisplayMode.fitting(pointWidth: 800, pointHeight: 1000, scale: 2)
        #expect([upright.pointWidth, upright.pointHeight, upright.pixelWidth, upright.pixelHeight] == [800, 1000, 1600, 2000])
        // At 1x small sizes pass as they are, down to the least a Mac was seen to make.
        let tiny = VirtualDisplayMode.fitting(pointWidth: 393, pointHeight: 852, scale: 1)
        #expect([tiny.pixelWidth, tiny.pixelHeight] == [392, 852], "sides are even")
        let speck = VirtualDisplayMode.fitting(pointWidth: 10, pointHeight: 10, scale: 1)
        #expect([speck.pixelWidth, speck.pixelHeight] == [200, 200])
        // Over the pixel limit a Mac does not answer at all, so the limit holds at either scale.
        let tall = VirtualDisplayMode.fitting(pointWidth: 1206, pointHeight: 2622, scale: 1)
        #expect([tall.pixelWidth, tall.pixelHeight] == [1206, 2160])
        let large = VirtualDisplayMode.fitting(pointWidth: 2560, pointHeight: 1600, scale: 2)
        #expect([large.pixelWidth, large.pixelHeight, large.pointWidth, large.pointHeight] == [3840, 2160, 1920, 1080])
        let fractional = VirtualDisplayMode.fitting(pointWidth: 1000, pointHeight: 700, scale: 3)
        #expect(fractional.pixelWidth == 2 * fractional.pointWidth)
        let oneX = VirtualDisplayMode.fitting(pointWidth: 1000, pointHeight: 700, scale: 0)
        #expect(oneX.pixelWidth == oneX.pointWidth)
    }
}
