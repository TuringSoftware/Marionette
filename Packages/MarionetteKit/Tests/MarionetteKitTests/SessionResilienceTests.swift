// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopSimulated
import Testing
@testable import MarionetteKit

@MainActor
@Suite struct SessionResilienceTests {
    /// A reconnect that would have to wait this long is a counted, delayed one.
    private static let slow = ReconnectionPolicy(attempts: 2, initialDelay: .seconds(30), maximumDelay: .seconds(30), jitter: 0)

    private func dropping(after delay: Duration = .milliseconds(100), _ reason: DisconnectReason = .connectionLost(detail: "")) -> SimulationScenario {
        var scenario = fastScenario()
        scenario.disconnect = (delay, reason)
        return scenario
    }

    private func toBackground(_ model: SessionModel) {
        model.sceneDidResignActive()
        model.sceneDidEnterBackground()
    }

    private func toForeground(_ model: SessionModel) {
        model.sceneWillEnterForeground()
        model.sceneDidBecomeActive()
    }

    // MARK: What is retried

    @Test func aReconnectThatCannotSucceedStopsAtOnceWithTheRealFailure() async throws {
        var refused = fastScenario()
        refused.failure = (.negotiating, .permissionDenied(detail: "Not this account."))
        let fixture = try Fixture([dropping(), refused, fastScenario()])
        let model = try await fixture.startedModel { if case .failed = $0.phase { true } else { false } }
        #expect(model.phase == .failed(.permissionDenied(detail: "Not this account.")))
        #expect(fixture.backend.attempts == 2, "asking again would fail the same way")
        model.disconnect()
    }

    @Test func theDelaysGrowToACapAndAreJittered() {
        let policy = ReconnectionPolicy(attempts: 6, initialDelay: .seconds(1), maximumDelay: .seconds(8), jitter: 0.5)
        #expect((1...6).map { policy.delay(beforeAttempt: $0, random: 0) } == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8), .seconds(8)])
        #expect(policy.delay(beforeAttempt: 3, random: 1) == .seconds(2))
        #expect(policy.delay(beforeAttempt: 3, random: 0.5) == .seconds(3))
        #expect(policy.delay(beforeAttempt: 100, random: 0) == .seconds(8))
    }

    // MARK: Lossy and silent media

    @Test func aLossyStallReconnectsInStandardForOneConnectionAndASilentOneKeepsTheMode() async throws {
        let fixture = try Fixture(
            [dropping(.mediaStalled(.lossy)), dropping(.mediaStalled(.silent)), fastScenario()],
            claimedModes: [.highPerformance, .standard]
        )
        let model = try await fixture.startedModel { _ in fixture.backend.sessions.count == 3 }
        try await waitUntil { model.phase == .connected }
        #expect(fixture.backend.sessions.map(\.info.mode) == [.highPerformance, .standard, .highPerformance])
        model.disconnect()
    }

    // MARK: Session select

    @Test func aReconnectAnswersTheMacsFirstOfferWithTheChoiceItAccepted() async throws {
        var console = dropping(after: .milliseconds(300))
        console.consoleUser = "jamie"
        var again = fastScenario()
        again.consoleUser = "jamie"
        let fixture = try Fixture([console, again])
        let model = fixture.makeModel()
        model.start()
        try await waitUntil { if case .sessionSelect = model.prompts.pending?.prompt { true } else { false } }
        model.prompts.reply(.sessionChoice(.logInAsSelf))
        try await waitUntil { model.phase == .connected }
        try await waitUntil { fixture.backend.attempts == 2 && model.phase == .connected }
        #expect(model.prompts.pending == nil)
        model.disconnect()
    }

    // MARK: Background

    @Test func aDropInTheBackgroundWaitsForTheForegroundAndIsThenRedialledAtOnce() async throws {
        var fixture = try Fixture([fastScenario(), fastScenario()])
        fixture.reconnection = Self.slow
        let model = try await fixture.connectedModel()
        toBackground(model)
        // Dropped once in the background, not on a timer that a loaded machine can let fire first.
        fixture.backend.sessions[0].simulateDisconnect(.connectionLost(detail: ""))
        try await waitUntil { model.phase == .reconnecting(attempt: 1) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.backend.attempts == 1, "nothing dials in the background")
        toForeground(model)
        try await waitUntil { model.phase == .connected }
        #expect(fixture.backend.attempts == 2)
        model.disconnect()
    }

    @Test func aConnectionThatDidNotSurviveTheBackgroundIsRedialledAtOnce() async throws {
        var fixture = try Fixture([fastScenario(), fastScenario()])
        fixture.reconnection = Self.slow
        let model = try await fixture.connectedModel()
        toBackground(model)
        toForeground(model)
        // iOS reclaimed the socket meanwhile; it shows once the app is back.
        fixture.backend.sessions[0].simulateDisconnect(.connectionLost(detail: ""))
        try await waitUntil { fixture.backend.attempts == 2 && model.phase == .connected }
        model.disconnect()
    }

    @Test func aSessionThatReconnectsInTheBackgroundIsSuspendedAndDrawsNothing() async throws {
        var slow = fastScenario()
        slow.phaseDelay = .milliseconds(80)
        let fixture = try Fixture([dropping(), slow])
        let model = try await fixture.connectedModel()
        try await waitUntil { fixture.backend.attempts == 2 }
        toBackground(model)
        try await waitUntil { model.phase == .connected }
        try await waitUntil { fixture.backend.sessions[1].state == .suspended }
        #expect(model.renderer.isDrawingSuspended)
        toForeground(model)
        try await waitUntil { fixture.backend.sessions[1].state == .connected }
        #expect(!model.renderer.isDrawingSuspended)
        model.disconnect()
    }

    @Test func whenTheBackgroundTimeRunsOutTheSessionEndsCleanlyAndReturnsWithTheApp() async throws {
        var fixture = try Fixture([fastScenario(), fastScenario()])
        fixture.reconnection = Self.slow
        let model = try await fixture.connectedModel()
        await model.backgroundTimeExpired()
        #expect(model.phase == .connected, "only an app in the background gives its session up")
        toBackground(model)
        await model.backgroundTimeExpired()
        #expect(fixture.backend.sessions[0].state == .disconnected(.userInitiated))
        #expect(model.phase == .reconnecting(attempt: 1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.backend.attempts == 1)
        toForeground(model)
        try await waitUntil { model.phase == .connected }
        #expect(fixture.backend.attempts == 2)
        model.disconnect()
    }

    @Test func drawingStopsTheMomentTheAppResignsActive() async throws {
        let fixture = try Fixture()
        let model = try await fixture.connectedModel()
        model.sceneDidResignActive()
        #expect(model.renderer.isDrawingSuspended && model.externalRenderer.isDrawingSuspended)
        model.sceneDidBecomeActive()
        #expect(!model.renderer.isDrawingSuspended && !model.externalRenderer.isDrawingSuspended)
        model.disconnect()
    }

    @Test func thePaneChangingWhileInactiveResizesNothingUntilTheAppIsBack() async throws {
        var fixture = try Fixture()
        fixture.computer.display = .fitToDevice
        let model = fixture.makeModel()
        model.stageLayoutChanged(size: CGSize(width: 1376, height: 1032), safeArea: .zero, deviceScale: 2)
        model.start()
        try await waitUntil { model.phase == .connected && model.selectedDisplay?.kind == .virtual }
        // iPadOS takes its app-switcher snapshot in the other orientation.
        model.sceneDidResignActive()
        model.stageLayoutChanged(size: CGSize(width: 1032, height: 1376), safeArea: .zero, deviceScale: 2)
        try await Task.sleep(for: .milliseconds(700))
        let display = try #require(model.selectedDisplay)
        #expect(display.pixelSize.width > display.pixelSize.height, "the Mac was not reconfigured")
        // Back, in the orientation the device really has now: it is sized for once.
        model.sceneDidBecomeActive()
        try await waitUntil { (model.selectedDisplay?.pixelSize.height ?? 0) > (model.selectedDisplay?.pixelSize.width ?? 0) }
        model.disconnect()
    }
}

@MainActor
@Suite struct SessionSecurityTests {
    @Test func theVNCRungAsksInsteadOfSendingTheMacsPasswordAndSaysItIsNotEncrypted() async throws {
        var notAMac = fastScenario()
        notAMac.failure = (.negotiating, .unsupportedServer(detail: "The server speaks RFB 3.8."))
        var fixture = try Fixture([notAMac], claimedModes: [.highPerformance, .standard])
        fixture.vnc = RecordingBackend([fastScenario(.genericVNC)], id: BackendID.vnc)
        try fixture.secrets.setSecret("mac-secret", for: .remoteDesktopPassword(for: fixture.computer))
        var preferences = SessionPreferences(defaults: fixture.defaults)
        preferences.clipboardMode = .automatic
        preferences.save(to: fixture.defaults)
        let model = fixture.makeModel()
        model.start()
        try await waitUntil { model.prompts.pending != nil }
        #expect(model.prompts.pending?.isFromFallbackRung == true)
        model.prompts.reply(.credentials(username: "demo", password: "demo"), remember: true)
        try await waitUntil { model.phase == .connected }
        #expect(fixture.vnc?.attempts == 1)
        #expect(model.banner?.title == "Connected Without Encryption")
        #expect(model.clipboard.isAvailable && !model.clipboard.sendsAutomatically)
        #expect(try fixture.secrets.secret(for: .remoteDesktopPassword(for: fixture.computer)) == "mac-secret", "never saved")
        model.disconnect()
    }

    /// Which protocol a computer speaks is found out, not asked. A computer that says on first
    /// contact that it is not a Mac is a VNC server: straight to VNC, which is then its own
    /// protocol (the saved password is used), and it is remembered as one.
    @Test func aComputerThatIsNotAMacGoesStraightToVNCWithItsOwnPassword() async throws {
        var notAMac = fastScenario()
        notAMac.failure = (.negotiating, .otherProtocol(detail: "RFB 003.008"))
        var fixture = try Fixture([notAMac], claimedModes: [.highPerformance, .standard])
        fixture.vnc = RecordingBackend([fastScenario(.genericVNC)], id: BackendID.vnc)
        let model = fixture.makeModel()
        model.start()
        try await waitUntil { model.phase == .connected }
        #expect(fixture.backend.attempts == 1, "no Standard rung after the server said it is not a Mac")
        #expect(fixture.vnc?.attempts == 1)
        #expect(model.prompts.pending == nil, "the saved password answered")
        #expect(fixture.repository.record(id: fixture.computer.id)?.configuration.backendID == BackendID.vnc)
        #expect(fixture.repository.record(id: fixture.computer.id)?.configuration.isKnownVNCServer == true)
        model.disconnect()
    }

    /// Set to High Performance, a Mac that refuses it does not fall back to VNC; a computer that is
    /// not a Mac at all still gets there.
    @Test func aHighPerformanceComputerThatIsNotAMacStillReachesVNC() async throws {
        var notAMac = fastScenario()
        notAMac.failure = (.negotiating, .otherProtocol(detail: "RFB 003.008"))
        var fixture = try Fixture([notAMac], claimedModes: [.highPerformance, .standard])
        fixture.vnc = RecordingBackend([fastScenario(.genericVNC)], id: BackendID.vnc)
        fixture.computer.mode = .highPerformance
        fixture.repository.save(fixture.computer, now: Date(timeIntervalSince1970: 0))
        let model = fixture.makeModel()
        model.start()
        try await waitUntil { model.phase == .connected }
        #expect(fixture.vnc?.attempts == 1)
        model.disconnect()
    }

    /// A computer known as a Mac that answers as something else is not given the Mac's password,
    /// and stays a Mac.
    @Test func aKnownMacThatStopsAnsweringAsOneIsNotGivenItsPassword() async throws {
        var notAMac = fastScenario()
        notAMac.failure = (.negotiating, .otherProtocol(detail: "RFB 003.008"))
        var fixture = try Fixture([notAMac], claimedModes: [.highPerformance, .standard])
        fixture.vnc = RecordingBackend([fastScenario(.genericVNC)], id: BackendID.vnc)
        fixture.repository.recordConnection(id: fixture.computer.id, mode: .highPerformance, at: Date(timeIntervalSince1970: 10))
        let model = fixture.makeModel()
        model.start()
        try await waitUntil { model.prompts.pending != nil }
        #expect(model.prompts.pending?.isFromFallbackRung == true)
        model.prompts.reply(.credentials(username: "demo", password: "demo"), remember: false)
        try await waitUntil { model.phase == .connected }
        #expect(fixture.repository.record(id: fixture.computer.id)?.configuration.backendID == BackendID.appleScreenSharing)
        model.disconnect()
    }

    @Test func aMacThatProvedItsIdentityIsNotTakenForAnythingWeakerUnlessTheUserAgrees() async throws {
        var proving = fastScenario()
        proving.provesServerIdentity = true
        // Something answering at the same address, without SRP.
        let impostor = fastScenario()
        var fixture = try Fixture([proving, impostor], claimedModes: [.highPerformance, .standard])
        fixture.vnc = RecordingBackend([fastScenario(.genericVNC)], id: BackendID.vnc)
        let first = try await fixture.connectedModel()
        #expect(try fixture.secrets.secret(for: .provenIdentity(for: fixture.computer)) != nil)
        first.disconnect()

        let model = fixture.makeModel()
        model.start()
        try await waitUntil { if case .failed = model.phase { true } else { false } }
        guard case .failed(let failure) = model.phase, case .identityUnverifiable = failure else {
            Issue.record("expected the identity failure, got \(model.phase)")
            return
        }
        #expect(failure.recoveryActions.contains(.connectWithoutVerifying))
        #expect(fixture.vnc?.attempts == 0, "no fallback to a protocol that proves nothing")
        #expect(model.prompts.pending == nil, "nothing was asked, so nothing was sent")

        model.perform(.connectWithoutVerifying)
        try await waitUntil { model.phase == .connected }
        model.disconnect()
    }

    /// Once a saved computer's sessions were encrypted at its address, nothing answering there can
    /// talk it down to a session in clear: no fallback, no way to go ahead but adding it again.
    @Test func aComputerThatEncryptedBeforeIsNeverTalkedDownToASessionInClear() async throws {
        var inClear = fastScenario()
        inClear.encryptsSession = false
        var fixture = try Fixture([fastScenario(), inClear], claimedModes: [.highPerformance, .standard])
        fixture.vnc = RecordingBackend([fastScenario(.genericVNC)], id: BackendID.vnc)
        let first = try await fixture.connectedModel()
        #expect(try fixture.secrets.secret(for: .encryptedBefore(for: fixture.computer)) != nil)
        #expect(!first.statusLine.contains("Not Secure"))
        first.disconnect()

        let model = fixture.makeModel()
        model.start()
        try await waitUntil { if case .failed = model.phase { true } else { false } }
        guard case .failed(let failure) = model.phase, case .notEncrypted = failure else {
            Issue.record("expected the encryption failure, got \(model.phase)")
            return
        }
        #expect(!failure.recoveryActions.contains(.connectWithoutVerifying), "no way to go ahead in clear")
        #expect(fixture.vnc?.attempts == 0, "no fallback to plain VNC, which never encrypts")
    }

    /// A computer that never encrypted (a server that leaves sessions in clear) is the user's to
    /// use, and says plainly that it is not secure.
    @Test func aComputerThatNeverEncryptedConnectsMarkedNotSecure() async throws {
        var inClear = fastScenario()
        inClear.encryptsSession = false
        let fixture = try Fixture([inClear])
        let model = try await fixture.connectedModel()
        #expect(model.statusLine.contains("Not Secure"))
        #expect(model.banner?.title == "Not Secure")
        #expect(try fixture.secrets.secret(for: .encryptedBefore(for: fixture.computer)) == nil)
        model.disconnect()
    }

    @Test func aRejectedSavedPasswordGoesOnceTheTypedOneHasWorked() async throws {
        var fixture = try Fixture(savePassword: false)
        try fixture.secrets.setSecret("stale", for: .remoteDesktopPassword(for: fixture.computer))
        fixture.computer.username = "demo"
        let model = fixture.makeModel()
        model.start()
        try await waitUntil {
            if case .credentials(let request) = model.prompts.pending?.prompt { request.attempt == 2 } else { false }
        }
        #expect(try fixture.secrets.secret(for: .remoteDesktopPassword(for: fixture.computer)) == "stale")
        model.prompts.reply(.credentials(username: "demo", password: "demo"), remember: false)
        try await waitUntil { model.phase == .connected }
        #expect(try fixture.secrets.secret(for: .remoteDesktopPassword(for: fixture.computer)) == nil)
        model.disconnect()
    }

    @Test func editingCredentialsAndThenGivingUpLosesNothing() async throws {
        let computer = ComputerConfiguration(host: "studio.local", username: "me")
        let secrets = InMemorySecretStore()
        try secrets.setSecret("pw", for: .remoteDesktopPassword(for: computer))
        let broker = PromptBroker(computer: computer, secrets: secrets)
        broker.forgetCredentials()
        let asking = Task { await broker.resolve(.credentials(CredentialRequest(context: .remoteDesktop(host: "studio.local")))) }
        try await waitUntil { broker.pending != nil }
        broker.cancelPending()
        #expect(await asking.value == .cancel)
        #expect(try secrets.secret(for: .remoteDesktopPassword(for: computer)) == "pw")
    }

    @Test func passwordsAreFiledByAddressAndOldOnesMoveToTheCurrentOne() async throws {
        let secrets = InMemorySecretStore()
        let computer = ComputerConfiguration(host: "Studio.local", username: "me")
        // Saved by an earlier version, under the computer alone.
        try secrets.setSecret("pw", for: SecretKey(computerID: computer.id, kind: .remoteDesktopPassword))
        try secrets.setSecret("ssh", for: SecretKey(computerID: computer.id, kind: .tunnelPassword))
        let broker = PromptBroker(computer: computer, secrets: secrets)
        #expect(try secrets.secret(for: SecretKey(computerID: computer.id, kind: .remoteDesktopPassword)) == nil)
        #expect(try secrets.secret(for: .remoteDesktopPassword(for: computer)) == "pw")
        #expect(try secrets.secret(for: .sshPassword(for: computer, server: computer.tunnelServer)) == "ssh")
        #expect(await broker.resolve(.credentials(CredentialRequest(context: .remoteDesktop(host: "")))) == .credentials(username: "me", password: "pw"))

        // The same computer at another address, or through a tunnel, is asked.
        var moved = computer
        moved.host = "elsewhere.example"
        var tunnelled = computer
        tunnelled.tunnel.isEnabled = true
        #expect(SecretKey.remoteDesktopPassword(for: tunnelled) != .remoteDesktopPassword(for: computer))
        let elsewhere = PromptBroker(computer: moved, secrets: secrets)
        let asking = Task { await elsewhere.resolve(.credentials(CredentialRequest(context: .remoteDesktop(host: "")))) }
        try await waitUntil { elsewhere.pending != nil }
        elsewhere.cancelPending()
        _ = await asking.value
        // Case does not make another address.
        var lowercase = computer
        lowercase.host = "studio.local"
        #expect(SecretKey.remoteDesktopPassword(for: lowercase) == .remoteDesktopPassword(for: computer))
    }
}
