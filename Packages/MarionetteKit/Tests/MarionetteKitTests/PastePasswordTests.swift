// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopSimulated
import Synchronization
import Testing
@testable import MarionetteKit

@MainActor
@Suite struct PastePasswordTests {
    /// What the remote machine was sent as text.
    private func text(sentTo session: SimulatedSession) -> String {
        session.receivedInput.map { if case .text(let text) = $0 { text } else { "" } }.joined()
    }

    @Test func aPasswordIsTypedAndGoesOnNoClipboardAndIntoNoTally() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        let remoteClipboard = session.remoteClipboard
        model.typePassword("correct horse-1")
        #expect(text(sentTo: session) == "correct horse-1")
        #expect(session.receivedInput.compactMap(\.key).isEmpty, "no ⌘V, and no keys the tally would spell out")
        #expect(model.clipboard.sendCount == 0)
        #expect(session.remoteClipboard == remoteClipboard)
        #expect(model.inputTally.typed.isEmpty)
        #expect(model.inputTally.passwords == 1)
        model.disconnect()
    }

    /// A modifier latched on screen is down on the remote machine, where it would make a shortcut
    /// of every character.
    @Test func modifiersAreLetGoOfBeforeAPasswordIsTyped() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.tapModifier(.command)
        model.keyDown(.leftShift, source: .hardware)
        model.typePassword("ab")
        #expect(model.uiState.modifiers.isEmpty)
        #expect(!model.hasHeldKeys)
        let received = session.receivedInput
        let typed = try #require(received.firstIndex(of: .text("ab")))
        let ups = received[..<typed].compactMap(\.key).filter { $0.phase == .up }.map(\.key)
        #expect(Set(ups) == [.leftCommand, .leftShift])
        #expect(received[typed...].compactMap(\.key).isEmpty)
        model.disconnect()
    }

    @Test func theLoginPasswordIsTheSavedOne() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        #expect(model.hasLoginPassword)
        model.pasteLoginPassword()
        try await waitUntil { text(sentTo: session) == "demo" }
        #expect(model.clipboard.sendCount == 0)
        model.disconnect()
    }

    @Test func aPasswordTypedAtSignInAndNotSavedIsTheLoginPassword() async throws {
        let fixture = try Fixture(savePassword: false)
        let model = fixture.makeModel()
        model.start()
        try await waitUntil { model.prompts.pending != nil }
        #expect(!model.hasLoginPassword)
        model.prompts.reply(.credentials(username: "demo", password: "demo"), remember: false)
        try await waitUntil { model.phase == .connected }
        #expect(model.hasLoginPassword)
        model.pasteLoginPassword()
        try await waitUntil { text(sentTo: fixture.backend.sessions[0]) == "demo" }
        #expect(!fixture.secrets.hasSecret(for: .remoteDesktopPassword(for: fixture.computer)))
        model.disconnect()
    }

    @Test func aProtectedLoginPasswordNeedsTheOwnerAgainOnceTheAppHasLeftTheScreen() async throws {
        var fixture = try Fixture(savePassword: false)
        fixture.computer.passwordProtection.requiresUserPresence = true
        try fixture.secrets.setSecret("demo", for: .remoteDesktopPassword(for: fixture.computer), protection: fixture.computer.passwordProtection)
        let owner = Mutex((asked: 0, agrees: true))
        fixture.owner = OwnerAuthentication(check: { .faceID }, makeAccess: {
            SecretAccess { _ in
                owner.withLock { state in
                    state.asked += 1
                    return state.agrees
                }
            }
        })
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        #expect(owner.withLock { $0.asked } == 1)
        model.pasteLoginPassword()
        try await waitUntil { text(sentTo: session) == "demo" }
        #expect(owner.withLock { $0.asked } == 1, "unlocked when signing in")

        model.sceneDidEnterBackground()
        model.sceneWillEnterForeground()
        try await waitUntil { model.acceptsInput }
        #expect(model.hasLoginPassword, "known to be there without asking")
        owner.withLock { $0.agrees = false }
        model.pasteLoginPassword()
        try await waitUntil { owner.withLock { $0.asked } == 2 }
        owner.withLock { $0.agrees = true }
        model.pasteLoginPassword()
        try await waitUntil { owner.withLock { $0.asked } == 3 }
        // Twice in all: the paste the owner refused typed nothing.
        try await waitUntil { fixture.backend.sessions.map { text(sentTo: $0) }.joined() == "demodemo" }
        model.disconnect()
    }

    /// A password typed at sign-in was never read from behind the owner check, but the computer
    /// asks for that check all the same.
    @Test func aProtectedComputersTypedPasswordIsNotPastedWithoutTheOwner() async throws {
        var computer = ComputerConfiguration(name: "Studio", host: "studio-mac.local", username: "alex")
        computer.passwordProtection.requiresUserPresence = true
        let owner = Mutex((asked: 0, agrees: false))
        let broker = PromptBroker(computer: computer, secrets: InMemorySecretStore(), access: SecretAccess { _ in
            owner.withLock { state in
                state.asked += 1
                return state.agrees
            }
        })
        let request = CredentialRequest(context: .remoteDesktop(host: computer.host), kind: .passwordOnly)
        async let answer = broker.resolve(.credentials(request))
        try await waitUntil { broker.pending != nil }
        broker.reply(.credentials(username: "alex", password: "typed"), remember: false)
        _ = await answer
        #expect(broker.hasLoginPassword)
        #expect(owner.withLock { $0.asked } == 0, "typing it took no owner check")
        #expect(await broker.loginPassword() == nil)
        #expect(owner.withLock { $0.asked } == 1)
        owner.withLock { $0.agrees = true }
        #expect(await broker.loginPassword() == "typed")
    }

    /// Plain VNC for a Mac proves nothing about what answers and encrypts nothing: its sign-in is
    /// never given the Mac's saved password, and neither is what is typed over it.
    @Test func theSavedPasswordIsNotPastedOverARungThatSpeaksAnotherProtocol() async throws {
        var notAMac = fastScenario()
        notAMac.failure = (.negotiating, .unsupportedServer(detail: "The server speaks RFB 3.8."))
        var fixture = try Fixture([notAMac], claimedModes: [.highPerformance, .standard])
        fixture.vnc = RecordingBackend([fastScenario(.genericVNC)], id: BackendID.vnc)
        let model = fixture.makeModel()
        model.start()
        try await waitUntil { model.prompts.pending != nil }
        model.prompts.reply(.credentials(username: "demo", password: "demo"), remember: false)
        try await waitUntil { model.phase == .connected }
        #expect(model.prompts.hasLoginPassword, "the Mac's own is saved")
        #expect(!model.hasLoginPassword)
        model.pasteLoginPassword()
        model.typePassword("x")
        let session = try #require(fixture.vnc?.sessions.first)
        try await waitUntil { text(sentTo: session) == "x" }
        model.disconnect()
    }

    /// Behind a paste on its way, a password waits its turn, and is counted when it has gone.
    @Test func aPasswordBehindAPasteOnItsWayFollowsItAndIsCountedThen() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.paste("from the phone")
        model.typePassword("hunter2")
        #expect(model.inputTally.passwords == 0)
        try await waitUntil { text(sentTo: session) == "hunter2" }
        #expect(model.inputTally.passwords == 1)
        let received = session.receivedInput
        let typed = try #require(received.firstIndex(of: .text("hunter2")))
        #expect(received[..<typed].contains { $0.key?.key == .v }, "after the paste's ⌘V")
        model.disconnect()
    }

    @Test func aComputerWithoutAPasswordHasNoneToPasteAndAsksNoOne() async throws {
        let computer = ComputerConfiguration(name: "Studio", host: "studio-mac.local", username: "alex")
        let asked = Mutex(0)
        let broker = PromptBroker(computer: computer, secrets: InMemorySecretStore(), access: SecretAccess { _ in
            asked.withLock { $0 += 1 }
            return true
        })
        #expect(!broker.hasLoginPassword)
        #expect(await broker.loginPassword() == nil)
        #expect(asked.withLock { $0 } == 0)
    }

    @Test func thePasswordFieldTakesOverFromTheKeyboardAndGoesWhenItsPasswordIsSent() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        let session = fixture.backend.sessions[0]
        model.keyDown(.leftShift, source: .hardware)
        model.setPasswordEntryPresented(true)
        #expect(model.uiState.isPasswordEntryPresented)
        #expect(!model.hasHeldKeys, "its key-up would go to the field")
        model.submitPasswordEntry("from a manager")
        #expect(!model.uiState.isPasswordEntryPresented)
        #expect(text(sentTo: session) == "from a manager")
        model.submitPasswordEntry("again")
        #expect(text(sentTo: session) == "from a manager", "nothing is sent for a field that is not there")
        model.disconnect()
    }

    @Test func aPasswordThatArrivesWholeIsSentAndOneBeingTypedWaitsForReturn() {
        #expect(PasswordEntry.isWholePassword(from: "", to: "hunter2"))
        #expect(!PasswordEntry.isWholePassword(from: "", to: "h"))
        #expect(!PasswordEntry.isWholePassword(from: "h", to: "hunter2"))
        #expect(!PasswordEntry.isWholePassword(from: "hunter2", to: ""))
    }

    /// The field brings the system keyboard up; a deck left showing would be pushed up on top of it.
    @Test func theDeckMakesWayForThePasswordFieldAndComesBack() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        model.setInputPanel(.trackpad)
        model.setDeckOverlap(240)
        model.setPasswordEntryPresented(true)
        #expect(model.uiState.deckSurface == nil)
        #expect(model.uiState.bottomObstruction == 0)
        #expect(model.uiState.inputPanel == .trackpad, "the user's choice is not changed")
        model.setPasswordEntryPresented(false)
        #expect(model.uiState.deckSurface == .trackpad)
        model.disconnect()
    }

    @Test func foldedLikeALaptopTheDeckKeepsItsPaneUnderThePasswordFieldsKeyboard() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        model.setDeckDocked(true)
        model.setPasswordEntryPresented(true)
        #expect(model.uiState.deckSurface != nil)
        model.disconnect()
    }

    @Test func thePasswordFieldGoesWithTheConnection() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        model.setPasswordEntryPresented(true)
        fixture.backend.sessions[0].simulateDisconnect(.connectionLost(detail: ""))
        try await waitUntil { !model.uiState.isPasswordEntryPresented }
        try await waitUntil { model.phase == .connected }
        #expect(!model.uiState.isPasswordEntryPresented, "it does not come back with the connection")
        model.disconnect()
        model.setPasswordEntryPresented(true)
        #expect(!model.uiState.isPasswordEntryPresented)
    }
}
