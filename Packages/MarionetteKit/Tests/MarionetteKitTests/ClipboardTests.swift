// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import ImageIO
import RemoteDesktopCore
import RemoteDesktopInteraction
import RemoteDesktopSimulated
import Testing
@testable import MarionetteKit

@MainActor
@Suite struct ClipboardTests {
    private func fixture(mode: ClipboardMode, remoteText: String? = nil) throws -> Fixture {
        var scenario = fastScenario()
        scenario.initialRemoteClipboard = remoteText
        let fixture = try Fixture([scenario])
        var preferences = SessionPreferences(defaults: fixture.defaults)
        preferences.clipboardMode = mode
        preferences.save(to: fixture.defaults)
        return fixture
    }

    private func connected(_ fixture: Fixture) async throws -> SessionModel {
        var fixture = fixture
        fixture.clipboardPollInterval = .milliseconds(10)
        return try await fixture.connectedModel()
    }

    private func copyLocally(_ fixture: Fixture, _ items: [ClipboardItem]) async {
        await fixture.pasteboard.write(items, localOnly: false)
    }

    /// Lets a few polls of the local change count go by.
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    // MARK: Preferences

    @Test func theModeIsExplicitByDefaultAndPersists() throws {
        let fixture = try Fixture()
        #expect(SessionPreferences(defaults: fixture.defaults).clipboardMode == .explicit)
        var preferences = SessionPreferences(defaults: fixture.defaults)
        preferences.clipboardMode = .automatic
        preferences.save(to: fixture.defaults)
        #expect(SessionPreferences(defaults: fixture.defaults).clipboardMode == .automatic)
        fixture.defaults.set("nonsense", forKey: "clipboard.mode")
        #expect(SessionPreferences(defaults: fixture.defaults).clipboardMode == .explicit)
        #expect(ClipboardMode.allCases.map(\.title) == ["When You Paste", "Automatically", "Off"])
    }

    // MARK: Remote to local

    @Test(arguments: [ClipboardMode.explicit, .automatic])
    func remoteCopiesArriveLocallyKeptOffUniversalClipboard(mode: ClipboardMode) async throws {
        let fixture = try fixture(mode: mode, remoteText: "from the Mac")
        let model = try await connected(fixture)
        #expect(model.clipboard.isAvailable)
        try await waitUntil { await fixture.pasteboard.items.first?.text == "from the Mac" }
        #expect(await fixture.pasteboard.lastWriteWasLocalOnly)
        try await settle()
        // Our own write is not a local change: no dot, and nothing goes back.
        #expect(!model.clipboard.hasUnsentChange)
        #expect(await fixture.pasteboard.readCount == 0)
        model.disconnect()
    }

    @Test func offSharesNothingInEitherDirection() async throws {
        let fixture = try fixture(mode: .off, remoteText: "from the Mac")
        let model = try await connected(fixture)
        #expect(!model.clipboard.isAvailable)
        #expect(!model.features.clipboard.isAvailable, "the session is not even asked for the clipboard")
        #expect(!model.routesHardwarePaste)
        await copyLocally(fixture, [ClipboardItem(text: "secret")])
        try await settle()
        #expect(await fixture.pasteboard.items.first?.text == "secret")
        #expect(!model.clipboard.hasUnsentChange)
        #expect(fixture.backend.sessions[0].remoteClipboard.first?.text == "from the Mac")
        model.disconnect()
    }

    /// A copy made here straight after the Mac's arrived is the user's, and is flagged at once: a
    /// write of Marionette's own moves the count once, before it returns, and never again.
    @Test func aLocalCopyRightAfterARemoteOneIsNews() async throws {
        let fixture = try fixture(mode: .explicit)
        let model = try await connected(fixture)
        let session = fixture.backend.sessions[0]
        session.simulateRemoteCopy("from the Mac")
        try await waitUntil { await fixture.pasteboard.items.first?.text == "from the Mac" }
        try await settle()
        #expect(!model.clipboard.hasUnsentChange)
        await copyLocally(fixture, [ClipboardItem(text: "copied here at once")])
        try await waitUntil { model.clipboard.hasUnsentChange }
        model.disconnect()
    }

    @Test func aRepeatedRemoteDeliveryDoesNotReplaceANewerLocalCopy() async throws {
        let fixture = try fixture(mode: .explicit)
        let model = try await connected(fixture)
        let session = fixture.backend.sessions[0]
        session.simulateRemoteCopy("from the Mac")
        try await waitUntil { await fixture.pasteboard.items.first?.text == "from the Mac" }
        await copyLocally(fixture, [ClipboardItem(text: "newer, from the phone")])
        try await waitUntil { model.clipboard.hasUnsentChange }
        // The Mac announces its unchanged clipboard again after a click.
        session.simulateRemoteCopy("from the Mac")
        try await settle()
        #expect(await fixture.pasteboard.items.first?.text == "newer, from the phone")
        #expect(model.clipboard.hasUnsentChange)

        // Once something has been pasted there, the Mac's earlier contents are a change again.
        model.paste("newer, from the phone")
        try await waitUntil { session.remoteClipboard.first?.text == "newer, from the phone" }
        session.simulateRemoteCopy("from the Mac")
        try await waitUntil { await fixture.pasteboard.items.first?.text == "from the Mac" }
        model.disconnect()
    }

    @Test func aRepeatedDeliveryOfWhatIsAlreadyHereIsNotWrittenAgain() async throws {
        let fixture = try fixture(mode: .explicit, remoteText: "from the Mac")
        let model = try await connected(fixture)
        try await waitUntil { await fixture.pasteboard.items.first?.text == "from the Mac" }
        let count = await fixture.pasteboard.changeCount
        fixture.backend.sessions[0].simulateRemoteCopy("from the Mac")
        try await settle()
        #expect(await fixture.pasteboard.changeCount == count)
        model.disconnect()
    }

    // MARK: Local to remote, explicit

    @Test func explicitFlagsALocalChangeButSendsNothingUntilPasted() async throws {
        let fixture = try fixture(mode: .explicit)
        let model = try await connected(fixture)
        let session = fixture.backend.sessions[0]
        try await settle()
        #expect(!model.clipboard.hasUnsentChange, "what was there before the session is not news")

        await copyLocally(fixture, [ClipboardItem(text: "from the phone")])
        try await waitUntil { model.clipboard.hasUnsentChange }
        try await settle()
        #expect(session.remoteClipboard.isEmpty)
        #expect(await fixture.pasteboard.readCount == 0, "explicit mode never reads the clipboard by itself")

        model.paste("from the phone")
        try await waitUntil { session.receivedInput.compactMap(\.key).contains { $0.key == .v && $0.phase == .up } }
        #expect(session.remoteClipboard.first?.text == "from the phone")
        #expect(!model.clipboard.hasUnsentChange)
        model.disconnect()
    }

    @Test func aRemoteCopyClearsTheDot() async throws {
        let fixture = try fixture(mode: .explicit)
        let model = try await connected(fixture)
        let session = fixture.backend.sessions[0]
        await copyLocally(fixture, [ClipboardItem(text: "local")])
        try await waitUntil { model.clipboard.hasUnsentChange }
        session.simulateRemoteCopy("remote")
        try await waitUntil { !model.clipboard.hasUnsentChange }
        #expect(await fixture.pasteboard.items.first?.text == "remote")
        model.disconnect()
    }

    // MARK: Local to remote, automatic

    @Test func automaticSendsALocalChangeOnceAndDoesNotEchoIt() async throws {
        let fixture = try fixture(mode: .automatic)
        let model = try await connected(fixture)
        let session = fixture.backend.sessions[0]
        await copyLocally(fixture, [ClipboardItem(text: "from the phone")])
        try await waitUntil { session.remoteClipboard.first?.text == "from the phone" }
        try await settle()
        #expect(await fixture.pasteboard.readCount == 1, "one change, one read (one paste prompt at most)")
        #expect(!model.clipboard.hasUnsentChange)
        #expect(session.receivedInput.compactMap(\.key).isEmpty, "sending is not pasting")

        session.simulateRemoteCopy("from the Mac")
        try await waitUntil { await fixture.pasteboard.items.first?.text == "from the Mac" }
        try await settle()
        #expect(await fixture.pasteboard.readCount == 1)
        model.disconnect()
    }

    @Test func automaticWaitsForAPasteOnAConnectionThatIsNotEncrypted() async throws {
        var scenario = fastScenario()
        scenario.encryptsSession = false
        let fixture = try Fixture([scenario])
        var preferences = SessionPreferences(defaults: fixture.defaults)
        preferences.clipboardMode = .automatic
        preferences.save(to: fixture.defaults)
        let model = try await connected(fixture)
        #expect(model.clipboard.isAvailable && !model.clipboard.sendsAutomatically)
        await copyLocally(fixture, [ClipboardItem(text: "a password")])
        try await waitUntil { model.clipboard.hasUnsentChange }
        try await settle()
        #expect(fixture.backend.sessions[0].remoteClipboard.isEmpty)
        #expect(await fixture.pasteboard.readCount == 0)
        model.disconnect()
    }

    @Test func automaticNeverSendsConcealedContents() async throws {
        let fixture = try fixture(mode: .automatic)
        let model = try await connected(fixture)
        let session = fixture.backend.sessions[0]
        let password = ClipboardItem(representations: [
            "public.utf8-plain-text": Data("hunter2".utf8),
            PasteboardType.concealed: Data(),
        ])
        await copyLocally(fixture, [password])
        try await waitUntil { model.clipboard.hasUnsentChange }
        try await settle()
        #expect(session.remoteClipboard.isEmpty)
        #expect(await fixture.pasteboard.readCount == 0, "concealed contents are not even read")
        model.paste("hunter2")
        // The Mac holds it before the send returns, so the dot can go out a moment later.
        try await waitUntil { session.remoteClipboard.first?.text == "hunter2" && !model.clipboard.hasUnsentChange }
        model.disconnect()
    }

    @Test func automaticAsksOnlyOncePerChangeEvenWhenRefused() async throws {
        let fixture = try fixture(mode: .automatic)
        let model = try await connected(fixture)
        // A refused paste prompt reads as an empty clipboard.
        await copyLocally(fixture, [])
        try await waitUntil { await fixture.pasteboard.readCount == 1 }
        try await settle()
        #expect(await fixture.pasteboard.readCount == 1)
        #expect(fixture.backend.sessions[0].remoteClipboard.isEmpty)
        model.disconnect()
    }

    @Test func nothingIsReadInTheBackground() async throws {
        let fixture = try fixture(mode: .automatic)
        let model = try await connected(fixture)
        model.sceneDidEnterBackground()
        await copyLocally(fixture, [ClipboardItem(text: "later")])
        try await settle()
        #expect(await fixture.pasteboard.readCount == 0)
        model.sceneWillEnterForeground()
        try await waitUntil { fixture.backend.sessions[0].remoteClipboard.first?.text == "later" }
        model.disconnect()
    }

    // MARK: Hardware ⌘V

    @Test func hardwareCommandVPushesTheClipboardThenPressesOnlyV() async throws {
        let fixture = try fixture(mode: .explicit)
        let model = try await connected(fixture)
        let session = fixture.backend.sessions[0]
        #expect(model.routesHardwarePaste)
        model.keyDown(.leftCommand, source: .hardware)
        model.pasteFromHardwareKeyboard("from the phone")
        try await waitUntil { session.receivedInput.compactMap(\.key).contains { $0.key == .v && $0.phase == .up } }
        #expect(session.remoteClipboard.first?.text == "from the phone")
        model.keyUp(.leftCommand, source: .hardware)
        let keys = session.receivedInput.compactMap(\.key)
        // ⌘ down (hardware), V down and up with ⌘, ⌘ up (hardware): ⌘ is never let go early.
        #expect(keys.map(\.key) == [.leftCommand, .v, .v, .leftCommand])
        #expect(keys.map(\.phase) == [.down, .down, .up, .up])
        #expect(keys[1].modifiers.contains(.leftCommand) && keys[2].modifiers.contains(.leftCommand))
        model.disconnect()
    }

    @Test func keysTypedStraightAfterAPasteFollowIt() async throws {
        let fixture = try fixture(mode: .explicit)
        let model = try await connected(fixture)
        let session = fixture.backend.sessions[0]
        model.keyDown(.leftCommand, source: .hardware)
        model.pasteFromHardwareKeyboard("from the phone")
        // Before the clipboard has arrived: ⌘ is let go of and X is typed.
        model.keyUp(.leftCommand, source: .hardware)
        model.keyDown(.x, characters: "x", charactersIgnoringModifiers: "x", source: .hardware)
        model.keyUp(.x, source: .hardware)
        try await waitUntil { session.receivedInput.compactMap(\.key).count == 6 }
        let keys = session.receivedInput.compactMap(\.key)
        #expect(keys.map(\.key) == [.leftCommand, .v, .v, .leftCommand, .x, .x])
        #expect(keys.map(\.phase) == [.down, .down, .up, .up, .down, .up])
        // V went with ⌘, as it was held when ⌘V was pressed.
        #expect(keys[1].modifiers.contains(.leftCommand))
        #expect(session.remoteClipboard.first?.text == "from the phone")
        model.disconnect()
    }

    @Test func hardwarePasteWithAnEmptyClipboardPastesWhatTheRemoteHas() async throws {
        let fixture = try fixture(mode: .explicit, remoteText: "already there")
        let model = try await connected(fixture)
        let session = fixture.backend.sessions[0]
        model.pasteFromHardwareKeyboard(nil)
        let keys = session.receivedInput.compactMap(\.key)
        #expect(keys.map(\.key) == [.leftCommand, .v, .v, .leftCommand])
        #expect(session.remoteClipboard.first?.text == "already there")
        model.disconnect()
    }

    @Test func pastingWithALatchedCommandDoesNotReleaseIt() async throws {
        let fixture = try fixture(mode: .explicit)
        let model = try await connected(fixture)
        let session = fixture.backend.sessions[0]
        model.tapModifier(.command)
        model.tapModifier(.command)   // locked
        model.paste("text")
        try await waitUntil { session.receivedInput.compactMap(\.key).contains { $0.key == .v && $0.phase == .up } }
        let keys = session.receivedInput.compactMap(\.key)
        #expect(keys.map(\.key) == [.leftCommand, .v, .v])
        #expect(model.uiState.modifiers.state(of: .command) == .locked)
        model.disconnect()
    }

    @Test func withoutClipboardSharingThePasteControlTypes() async throws {
        let fixture = try fixture(mode: .off)
        let model = try await connected(fixture)
        let session = fixture.backend.sessions[0]
        model.paste("hi")
        #expect(session.receivedInput == [.text("hi")])
        model.disconnect()
    }
}

@Suite struct ClipboardConversionTests {
    private func image(_ type: String) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func aMacsLegacyAndPrivateNamesBecomeStandardTypes() {
        let item = ClipboardItem(representations: [
            "NSStringPboardType": Data("legacy".utf8),
            "Apple HTML pasteboard type": Data("<b>x</b>".utf8),
            "dyn.ah62d4rv4gu8yc6durvwwaznwmuuha2pxsvw0e55bsmwca7d3sbwu": Data([1, 2]),
            "com.apple.webarchive": Data([3]),
        ])
        let converted = ClipboardConversion.incoming([item])
        #expect(converted == [ClipboardItem(representations: [
            ClipboardConversion.utf8Text: Data("legacy".utf8),
            ClipboardConversion.html: Data("<b>x</b>".utf8),
        ])])
        // A standard name beats its legacy twin.
        let both = ClipboardItem(representations: ["public.utf8-plain-text": Data("new".utf8), "NSStringPboardType": Data("old".utf8)])
        #expect(ClipboardConversion.incoming([both]).first?.text == "new")
        #expect(ClipboardConversion.incoming([ClipboardItem(representations: ["dyn.x": Data([1])])]).isEmpty)
    }

    @Test func utf16TextBecomesUTF8() throws {
        let text = "Grüße ❤️"
        var littleEndian = try #require(text.data(using: .utf16LittleEndian))
        #expect(ClipboardConversion.incoming([ClipboardItem(representations: [ClipboardConversion.utf16Text: littleEndian])]).first?.text == text)
        littleEndian.insert(contentsOf: [0xFF, 0xFE], at: 0)
        #expect(ClipboardConversion.incoming([ClipboardItem(representations: ["public.utf16-external-plain-text": littleEndian])]).first?.text == text)
        let bigEndian = Data([0xFE, 0xFF]) + (try #require(text.data(using: .utf16BigEndian)))
        #expect(ClipboardConversion.incoming([ClipboardItem(representations: [ClipboardConversion.utf16Text: bigEndian])]).first?.text == text)
        // Real UTF-8 wins over a converted copy.
        let both = ClipboardItem(representations: [ClipboardConversion.utf16Text: littleEndian, ClipboardConversion.utf8Text: Data("utf8".utf8)])
        #expect(ClipboardConversion.incoming([both]).first?.text == "utf8")
    }

    @Test func anImageOfferedOnlyAsTIFFGetsAPNG() throws {
        let tiff = try image("public.tiff")
        let converted = try #require(ClipboardConversion.incoming([
            ClipboardItem(representations: ["NeXT TIFF v4.0 pasteboard type": tiff]),
        ]).first)
        #expect(converted.representations[ClipboardConversion.tiff] == tiff)
        let png = try #require(converted.representations[ClipboardConversion.png])
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 2)

        // An item that already has an image every app reads is left alone.
        let jpeg = try image("public.jpeg")
        let withJPEG = try #require(ClipboardConversion.incoming([ClipboardItem(representations: ["public.tiff": tiff, "public.jpeg": jpeg])]).first)
        #expect(withJPEG.representations[ClipboardConversion.png] == nil)
        // Data that is not an image is not converted, and BMP is never written.
        let broken = ClipboardConversion.incoming([ClipboardItem(representations: ["com.microsoft.bmp": Data([1, 2, 3]), "public.utf8-plain-text": Data("x".utf8)])])
        #expect(broken == [ClipboardItem(text: "x")])
    }

    @Test func whatIsCopiedHereTravelsWithItsRichForms() throws {
        let link = try #require(URL(string: "https://example.com/a"))
        let page = try #require(ClipboardConversion.outgoing([
            "public.url": link,
            "public.html": "<a>link</a>",
            "public.rtf": Data("{\\rtf1}".utf8),
            "com.apple.uikit.attributedstring": Data([1]),
        ]))
        #expect(page.representations[ClipboardConversion.url] == Data("https://example.com/a".utf8))
        #expect(page.text == "https://example.com/a", "a link travels as text too")
        #expect(page.representations[ClipboardConversion.html] == Data("<a>link</a>".utf8))
        #expect(page.representations[ClipboardConversion.rtf] != nil)
        #expect(page.representations.count == 4)

        let png = try image("public.png")
        #expect(ClipboardConversion.outgoing(["public.png": png, "public.plain-text": "caption"]) == ClipboardItem(representations: [
            ClipboardConversion.png: png, ClipboardConversion.utf8Text: Data("caption".utf8),
        ]))
        #expect(ClipboardConversion.outgoing(["com.example.private": Data([1])]) == nil)
    }
}
