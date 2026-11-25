// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopSimulated
import RemoteDesktopTransport
import Synchronization
import Testing
@testable import MarionetteKit

private struct StubFiles: FileTransfer {
    struct Denied: Error, CustomStringConvertible {
        var description: String { "denied" }
    }

    var uploads = "/home/sam"
    var listings: [String: [RemoteFileEntry]] = [:]

    var canBrowse = true
    func defaultUploadDirectory() async throws -> String { uploads }
    func list(directory: String) async throws -> [RemoteFileEntry] {
        guard let entries = listings[directory] else { throw Denied() }
        return entries
    }
    func upload(from localFile: URL, toDirectory remoteDirectory: String) -> AsyncThrowingStream<TransferProgress, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func download(_ remotePath: String, to localFile: URL) -> AsyncThrowingStream<TransferProgress, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

/// Takes a moment to connect and cannot be hurried by cancellation, like a handshake in flight.
private final class Unhurried: SSHConnecting {
    let inner: ScriptedSSHConnector
    let entered = Mutex(0)

    init(inner: ScriptedSSHConnector) {
        self.inner = inner
    }

    func connect(_ login: SSHLogin, prompts: any PromptHandler, hostKeys: any HostKeyStore) async throws(SSHConnectionError) -> any SSHSessionHandle {
        entered.withLock { $0 += 1 }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) { continuation.resume() }
        }
        return try await inner.connect(login, prompts: prompts, hostKeys: hostKeys)
    }
}

@MainActor
@Suite struct FileAccessModelTests {
    @MainActor
    private final class Rig {
        let connector: ScriptedSSHConnector
        let hostKeys = InMemoryKnownHostsStore()
        var computer = ComputerConfiguration(name: "Studio", host: "studio-mac.local", username: "alex")
        var transfers: [Bool] = []
        var signedIn = 0
        var known: (username: String, password: String)?

        init(_ server: ScriptedSSHConnector.Server = TunnelFixture.accepting(password: "right")) {
            connector = ScriptedSSHConnector(server)
        }

        var services: SSHServices {
            SSHServices(connector: connector, hostKeys: hostKeys, keys: SSHKeyStore(secrets: InMemorySecretStore()))
        }

        func model(_ prompts: any PromptHandler, ssh: Bool = true) -> FileAccessModel {
            let model = FileAccessModel(
                ssh: ssh ? services : nil, prompts: prompts,
                accountCredentials: { [unowned self] in self.known }, onSignedIn: { [unowned self] in self.signedIn += 1 }
            )
            model.onTransferChanged = { [unowned self] in self.transfers.append($0 != nil) }
            return model
        }
    }

    @Test func aTunnelsConnectionMakesFilesReadyAtOnceAndIsNeverClosedHere() async throws {
        let rig = Rig()
        let model = rig.model(ScriptedPrompts())
        #expect(model.state == .unavailable("Not connected."))
        #expect(model.transfer == nil && !model.canSignIn)
        model.signIn()
        #expect(model.state == .unavailable("Not connected."))

        let tunnel = try await rig.connector.connect(
            SSHLogin(server: Endpoint(host: "studio-mac.local", port: 22), username: "alex"),
            prompts: ScriptedPrompts([.trustHostKey(remember: false), .credentials(username: "", password: "right")]), hostKeys: rig.hostKeys
        )
        model.sessionConnected(computer: rig.computer, tunnel: tunnel, builtIn: nil)
        #expect(model.state == .ready)
        #expect(model.transfer != nil)
        #expect(rig.transfers == [true])
        #expect(!model.canSignIn && !model.isSignedIn)

        // Signing out is about a connection signing in opened; there is none.
        model.signOut()
        #expect(model.state == .ready && rig.transfers == [true])

        model.sessionEnded()
        #expect(model.state == .unavailable("Not connected."))
        #expect(model.transfer == nil && rig.transfers == [true, false])
        await Task.yield()
        #expect(rig.connector.handles.map(\.isClosed) == [false])
    }

    @Test func aBackEndsOwnFileTransferIsUsedAndFollowedWhenItChanges() {
        let rig = Rig()
        let model = rig.model(ScriptedPrompts())
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: StubFiles())
        #expect(model.state == .ready && model.transfer is StubFiles)
        model.setBuiltIn(nil)
        #expect(model.state == .signedOut && model.transfer == nil)
        model.setBuiltIn(StubFiles())
        #expect(model.state == .ready)
        #expect(rig.transfers == [true, false, true])
    }

    /// Screen Sharing's own transfer sends but cannot list folders: it is used until SSH is signed
    /// in, SFTP takes over for everything while it is, and signing out goes back to it.
    @Test func aTransferThatCannotBrowseLeavesSigningInOnOffer() async throws {
        let rig = Rig()
        let model = rig.model(ScriptedPrompts([.trustHostKey(remember: false), .credentials(username: "", password: "right")]))
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: StubFiles(canBrowse: false))
        #expect(model.state == .ready && !model.canBrowse)
        #expect(model.canSignIn && !model.isSigningIn)

        model.signIn()
        #expect(model.state == .ready && model.isSigningIn && !model.canSignIn)
        await model.waitUntilSettled()
        #expect(model.state == .ready && model.canBrowse && model.isSignedIn)
        #expect(!(model.transfer is StubFiles))
        #expect(!model.canSignIn)

        model.signOut()
        #expect(model.transfer is StubFiles && !model.canBrowse && model.canSignIn)
        #expect(rig.transfers == [true, true, true])

        // A failed sign-in is reported without taking the working transfer away.
        let locked = Rig(TunnelFixture.accepting(password: "other"))
        let second = locked.model(ScriptedPrompts([.trustHostKey(remember: false), .credentials(username: "", password: "wrong"), .cancel]))
        second.sessionConnected(computer: locked.computer, tunnel: nil, builtIn: StubFiles(canBrowse: false))
        second.signIn()
        await second.waitUntilSettled()
        #expect(second.state == .ready && second.transfer is StubFiles)
        #expect(second.canSignIn)
    }

    @Test func withoutSSHATransferThatCannotBrowseIsAllThereIs() {
        let rig = Rig()
        let model = rig.model(ScriptedPrompts(), ssh: false)
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: StubFiles(canBrowse: false))
        #expect(model.state == .ready && !model.canBrowse && !model.canSignIn)
    }

    @Test func withoutSSHThereIsNothingToSignInTo() {
        let rig = Rig()
        let model = rig.model(ScriptedPrompts(), ssh: false)
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: nil)
        #expect(model.state == .unavailable("File transfer isn’t available with this computer."))
        #expect(!model.canSignIn)
        model.signIn()
        #expect(model.state == .unavailable("File transfer isn’t available with this computer."))
        #expect(rig.transfers == [false])
    }

    @Test func signingInAsksThroughThePromptsAndSigningOutClosesTheConnection() async throws {
        let rig = Rig()
        let prompts = ScriptedPrompts([.trustHostKey(remember: true), .credentials(username: "", password: "right")])
        let model = rig.model(prompts)
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: nil)
        #expect(model.state == .signedOut && model.canSignIn)

        model.signIn()
        #expect(model.state == .connecting && !model.canSignIn)
        model.signIn()
        await model.waitUntilSettled()
        #expect(model.state == .ready && model.isSignedIn)
        #expect(model.transfer != nil)
        #expect(rig.signedIn == 1)
        #expect(rig.transfers == [false, true])
        // One connection, to the computer itself, as the session's account; the host key was checked
        // against the same store the tunnel uses and remembered there.
        #expect(rig.connector.logins.map(\.server) == [Endpoint(host: "studio-mac.local", port: 22)])
        #expect(rig.connector.logins.map(\.username) == ["alex"])
        #expect(prompts.hostKeyChallenges.count == 1)
        #expect(prompts.credentialRequests.map(\.context) == [.fileAccess(host: "studio-mac.local")])
        #expect(await rig.hostKeys.all().map(\.host) == ["studio-mac.local"])

        model.signOut()
        #expect(model.state == .signedOut && model.transfer == nil && !model.isSignedIn)
        #expect(rig.transfers == [false, true, false])
        try await waitUntil { rig.connector.handles.map(\.isClosed) == [true] }
    }

    @Test func thePasswordAlreadyUsedForTheSameAccountSignsInWithoutAsking() async throws {
        let rig = Rig()
        rig.known = ("alex", "right")
        let prompts = ScriptedPrompts([.trustHostKey(remember: false)])
        let model = rig.model(prompts)
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: nil)
        model.signIn()
        await model.waitUntilSettled()
        #expect(model.state == .ready)
        #expect(prompts.credentialRequests.isEmpty)

        // Another account's password is not offered to this one.
        let other = Rig()
        other.known = ("someone-else", "right")
        let asked = ScriptedPrompts([.trustHostKey(remember: false), .credentials(username: "", password: "right")])
        let second = other.model(asked)
        second.sessionConnected(computer: other.computer, tunnel: nil, builtIn: nil)
        second.signIn()
        await second.waitUntilSettled()
        #expect(second.state == .ready)
        #expect(asked.credentialRequests.map(\.attempt) == [1])

        // A computer saved without an account borrows the one typed for remote desktop.
        let nameless = Rig()
        nameless.computer.username = ""
        nameless.known = ("sam", "right")
        let third = nameless.model(ScriptedPrompts([.trustHostKey(remember: false)]))
        third.sessionConnected(computer: nameless.computer, tunnel: nil, builtIn: nil)
        third.signIn()
        await third.waitUntilSettled()
        #expect(third.state == .ready)
        #expect(nameless.connector.logins.map(\.username) == ["sam"])
    }

    @Test func aFailedSignInSaysWhyAndCanBeTriedAgain() async throws {
        var server = ScriptedSSHConnector.Server()
        server.failure = .unreachable(.unreachable(detail: "connection refused"))
        let rig = Rig(server)
        let model = rig.model(ScriptedPrompts())
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: nil)
        model.signIn()
        await model.waitUntilSettled()
        #expect(model.state == .failed("“studio-mac.local” didn’t answer over SSH. Check that Remote Login is turned on."))
        #expect(model.canSignIn && model.transfer == nil && rig.signedIn == 0)
        model.signIn()
        #expect(model.state == .connecting)
        await model.waitUntilSettled()
        if case .failed = model.state {} else { Issue.record("expected the second attempt to fail too") }
        model.signOut()
        #expect(model.state == .signedOut)
        #expect(rig.transfers == [false])

        let wrong = PromptResponse.credentials(username: "", password: "wrong")
        let locked = Rig()
        let second = locked.model(ScriptedPrompts([.trustHostKey(remember: false), wrong, wrong, wrong]))
        second.sessionConnected(computer: locked.computer, tunnel: nil, builtIn: nil)
        second.signIn()
        await second.waitUntilSettled()
        #expect(second.state == .failed("“studio-mac.local” didn’t accept the sign-in."))
        let third = locked.model(ScriptedPrompts([.cancel]))
        third.sessionConnected(computer: locked.computer, tunnel: nil, builtIn: nil)
        third.signIn()
        await third.waitUntilSettled()
        #expect(third.state == .failed("Sign-in was stopped because the identity of “studio-mac.local” wasn’t trusted."))
    }

    @Test func dismissingThePasswordPromptGoesBackToSignedOut() async throws {
        let rig = Rig()
        let model = rig.model(ScriptedPrompts([.trustHostKey(remember: false)]))
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: nil)
        model.signIn()
        await model.waitUntilSettled()
        #expect(model.state == .signedOut)
        #expect(rig.connector.handles.isEmpty)
    }

    @Test func signingOutOrDisconnectingWhileSigningInAbandonsTheConnection() async throws {
        let rig = Rig()
        rig.known = ("alex", "right")
        // The connection comes up although, by then, nobody wants it.
        let unhurried = Unhurried(inner: rig.connector)
        let services = SSHServices(connector: unhurried, hostKeys: rig.hostKeys, keys: SSHKeyStore(secrets: InMemorySecretStore()))
        let prompts = ScriptedPrompts([.trustHostKey(remember: false), .trustHostKey(remember: false)])
        let model = FileAccessModel(ssh: services, prompts: prompts, accountCredentials: { rig.known }, onSignedIn: { rig.signedIn += 1 })
        model.onTransferChanged = { rig.transfers.append($0 != nil) }
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: nil)
        model.signIn()
        #expect(model.state == .connecting)
        try await waitUntil { unhurried.entered.withLock { $0 } == 1 }
        model.signOut()
        #expect(model.state == .signedOut)

        model.signIn()
        try await waitUntil { unhurried.entered.withLock { $0 } == 2 }
        model.sessionEnded()
        #expect(model.state == .unavailable("Not connected."))
        try await waitUntil { rig.connector.handles.count == 2 && rig.connector.handles.allSatisfy(\.isClosed) }
        #expect(model.transfer == nil && rig.signedIn == 0)
        #expect(model.state == .unavailable("Not connected."))
        #expect(rig.transfers == [false, false])
    }

    @Test func disconnectingClosesTheConnectionSigningInOpened() async throws {
        let rig = Rig()
        rig.known = ("alex", "right")
        let model = rig.model(ScriptedPrompts([.trustHostKey(remember: true)]))
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: nil)
        model.signIn()
        await model.waitUntilSettled()
        #expect(model.state == .ready)
        model.sessionEnded()
        #expect(model.state == .unavailable("Not connected.") && model.transfer == nil)
        try await waitUntil { rig.connector.handles.map(\.isClosed) == [true] }

        // After a reconnect the user signs in again; the remembered host key asks nothing.
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: nil)
        #expect(model.state == .signedOut)
        model.signIn()
        await model.waitUntilSettled()
        #expect(model.state == .ready)
        #expect(rig.connector.handles.map(\.isClosed) == [true, false])
    }

    @Test func aReconnectKeepsTheConnectionSigningInOpened() async throws {
        let rig = Rig()
        rig.known = ("alex", "right")
        let model = rig.model(ScriptedPrompts([.trustHostKey(remember: true)]))
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: StubFiles(canBrowse: false))
        model.signIn()
        await model.waitUntilSettled()
        #expect(model.isSignedIn && model.canBrowse)
        rig.transfers.removeAll()

        // The session drops: the SFTP connection does not depend on it, and keeps working.
        model.sessionInterrupted()
        #expect(model.state == .ready && model.isSignedIn && model.canBrowse)
        #expect(rig.transfers == [true])
        #expect(!model.canSignIn)
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: StubFiles(canBrowse: false))
        #expect(model.isSignedIn)
        await Task.yield()
        #expect(rig.connector.handles.map(\.isClosed) == [false])

        // Another computer's session, or the end of this one, closes it.
        model.sessionEnded()
        #expect(model.state == .unavailable("Not connected.") && model.transfer == nil)
        try await waitUntil { rig.connector.handles.map(\.isClosed) == [true] }
    }

    @Test func aSessionsBrokerLendsTheRemoteDesktopPasswordAndKeepsWhatWasAsked() async throws {
        let rig = Rig()
        let secrets = InMemorySecretStore()
        try secrets.setSecret("right", for: .remoteDesktopPassword(for: rig.computer))
        let broker = PromptBroker(computer: rig.computer, secrets: secrets)
        // The remote-desktop back end asked for the account while connecting.
        #expect(await broker.resolve(.credentials(CredentialRequest(context: .remoteDesktop(host: "studio-mac.local")))) == .credentials(username: "alex", password: "right"))

        let model = FileAccessModel(ssh: rig.services, broker: broker)
        model.sessionConnected(computer: rig.computer, tunnel: nil, builtIn: nil)
        model.signIn()
        try await waitUntil { broker.pending != nil }
        guard case .hostKey = broker.pending?.prompt else {
            Issue.record("expected the host key to be asked about first")
            return
        }
        broker.reply(.trustHostKey(remember: true))
        await model.waitUntilSettled()
        // No password prompt: the one used for remote desktop was right for SSH too.
        #expect(model.state == .ready)
        #expect(broker.pending == nil)
    }
}

@MainActor
@Suite struct RemoteFileBrowserModelTests {
    private func simulatedFiles() async throws -> (session: any RemoteSession, files: any FileTransfer) {
        var scenario = fastScenario()
        scenario.transferRate = 1 << 30
        let session = try await SimulatedBackend(scenario: scenario).connect(
            ConnectionRequest(transport: SimulatedTransport(), prompts: StaticPromptHandler(username: "demo", password: "demo"))
        )
        return (session, try #require(session.capabilities.fileTransfer.value))
    }

    @Test func browsingStartsAtHomeAndMovesThroughFolders() async throws {
        let (session, files) = try await simulatedFiles()
        let browser = RemoteFileBrowserModel(transfer: files)
        #expect(browser.isLoading && browser.path.isEmpty && browser.breadcrumbs.isEmpty && !browser.canGoUp)
        await browser.waitUntilLoaded()
        // Uploads go to ~/Downloads; browsing starts one level up, at home.
        #expect(browser.path == "/Users/demo")
        #expect(!browser.isLoading && browser.errorMessage == nil)
        #expect(browser.entries.map(\.name) == ["Documents", "Pictures"])
        #expect(browser.entries.allSatisfy { $0.isDirectory })
        #expect(browser.breadcrumbs.map(\.name) == ["/", "Users", "demo"])
        #expect(browser.breadcrumbs.map(\.path) == ["/", "/Users", "/Users/demo"])

        browser.open(browser.entries[0])
        #expect(browser.path == "/Users/demo/Documents" && browser.isLoading && browser.entries.isEmpty)
        await browser.waitUntilLoaded()
        #expect(browser.entries.map(\.name) == ["Notes.txt", "Readme.txt"])
        #expect(browser.entries.map(\.size) == [21, 25])

        // A file is not a place to go.
        browser.open(browser.entries[0])
        #expect(browser.path == "/Users/demo/Documents" && !browser.isLoading)

        browser.goUp()
        await browser.waitUntilLoaded()
        #expect(browser.path == "/Users/demo")
        browser.go(to: "/Users/demo/Pictures/")
        await browser.waitUntilLoaded()
        #expect(browser.path == "/Users/demo/Pictures")
        #expect(browser.entries.map(\.name) == ["Empty.png"])
        browser.go(to: "/")
        await browser.waitUntilLoaded()
        #expect(browser.path == "/" && !browser.canGoUp)
        #expect(browser.entries.map(\.name) == ["Users"])
        browser.goUp()
        #expect(browser.path == "/" && !browser.isLoading)
        await session.disconnect()
    }

    @Test func reloadingShowsWhatChangedAndKeepsTheListingMeanwhile() async throws {
        let (session, files) = try await simulatedFiles()
        let browser = RemoteFileBrowserModel(transfer: files, startDirectory: "/Users/demo/Documents")
        #expect(browser.path == "/Users/demo/Documents")
        await browser.waitUntilLoaded()
        #expect(browser.entries.count == 2)

        let folder = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = folder.appending(path: "Agenda.txt")
        try Data("agenda".utf8).write(to: local)
        for try await _ in files.upload(from: local, toDirectory: "/Users/demo/Documents") {}

        browser.reload()
        #expect(browser.isLoading && browser.entries.count == 2)
        await browser.waitUntilLoaded()
        #expect(browser.entries.map(\.name) == ["Agenda.txt", "Notes.txt", "Readme.txt"])
        await session.disconnect()
    }

    @Test func foldersComeFirstThenNamesAsTheFinderOrdersThemAndNothingIsHidden() async throws {
        func entry(_ name: String, directory: Bool = false) -> RemoteFileEntry {
            RemoteFileEntry(path: "/home/sam/" + name, name: name, isDirectory: directory)
        }
        var files = StubFiles()
        files.listings["/home/sam"] = [
            entry("notes 10.txt"), entry("Zebra", directory: true), entry(".profile"), entry("notes 2.txt"),
            entry("apple", directory: true), entry("Banana.txt"), entry(".ssh", directory: true), entry("archive.zip"),
        ]
        let browser = RemoteFileBrowserModel(transfer: files)
        await browser.waitUntilLoaded()
        // No "Downloads" at the end of the upload folder: that folder is where browsing starts.
        #expect(browser.path == "/home/sam")
        #expect(browser.entries.map(\.name) == [".ssh", "apple", "Zebra", ".profile", "archive.zip", "Banana.txt", "notes 2.txt", "notes 10.txt"])
    }

    @Test func aFolderThatCannotBeReadShowsWhyAndCanBeLeft() async throws {
        var files = StubFiles()
        files.listings["/home/sam"] = [RemoteFileEntry(path: "/home/sam/private", name: "private", isDirectory: true)]
        let browser = RemoteFileBrowserModel(transfer: files)
        await browser.waitUntilLoaded()
        browser.open(browser.entries[0])
        await browser.waitUntilLoaded()
        #expect(browser.path == "/home/sam/private")
        #expect(browser.entries.isEmpty && browser.errorMessage == "denied" && !browser.isLoading)
        #expect(browser.canGoUp)
        browser.goUp()
        #expect(browser.errorMessage == nil)
        await browser.waitUntilLoaded()
        #expect(browser.entries.map(\.name) == ["private"])

        // Only the last place asked for counts.
        browser.go(to: "/home/sam/private")
        browser.go(to: "/home/sam")
        await browser.waitUntilLoaded()
        #expect(browser.path == "/home/sam" && browser.errorMessage == nil && browser.entries.count == 1)
    }

    @Test func pathsAreKeptTidy() {
        #expect(RemoteFileBrowserModel.normalized("/Users//demo/") == "/Users/demo")
        #expect(RemoteFileBrowserModel.normalized("") == "/")
        #expect(RemoteFileBrowserModel.parent(of: "/Users/demo") == "/Users")
        #expect(RemoteFileBrowserModel.parent(of: "/Users") == "/")
        #expect(RemoteFileBrowserModel.home(forUploadDirectory: "/Users/demo/Downloads") == "/Users/demo")
        #expect(RemoteFileBrowserModel.home(forUploadDirectory: "/home/sam") == "/home/sam")
    }
}

@MainActor
@Suite struct TransferQueueDestinationTests {
    @Test func downloadsLandInTheDestinationFolderUnderNamesThatDoNotCollide() async throws {
        var scenario = fastScenario()
        scenario.transferRate = 1 << 30
        let session = try await SimulatedBackend(scenario: scenario).connect(
            ConnectionRequest(transport: SimulatedTransport(), prompts: StaticPromptHandler(username: "demo", password: "demo"))
        )
        let files = try #require(session.capabilities.fileTransfer.value)
        let root = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        // The folder does not exist yet: the first finished download creates it.
        let documents = root.appending(path: "Documents")
        let queue = TransferQueue(destinationDirectory: { documents })
        queue.setTransfer(files)

        let readme = RemoteFileEntry(path: "/Users/demo/Documents/Readme.txt", name: "Readme.txt", isDirectory: false)
        let first = queue.download(readme)
        let second = queue.download(readme)
        let missing = queue.download(RemoteFileEntry(path: "/nope", name: "nope.txt", isDirectory: false))
        let third = queue.download(readme)
        #expect(queue.items.allSatisfy { $0.localURL == nil })
        await queue.waitUntilIdle()

        func item(_ id: UUID) -> TransferQueue.Item? { queue.items.first { $0.id == id } }
        #expect(item(first)?.state == .finished)
        #expect(item(first)?.localURL?.standardizedFileURL == documents.appending(path: "Readme.txt").standardizedFileURL)
        #expect(item(second)?.localURL?.lastPathComponent == "Readme 2.txt")
        #expect(item(third)?.localURL?.lastPathComponent == "Readme 3.txt")
        #expect(item(missing)?.state == .failed(message: "The item no longer exists on the remote computer."))
        #expect(item(missing)?.localURL == nil)
        // Only whole files, and nothing for the one that failed.
        #expect(try FileManager.default.contentsOfDirectory(atPath: documents.path).sorted() == ["Readme 2.txt", "Readme 3.txt", "Readme.txt"])
        #expect(try String(contentsOf: documents.appending(path: "Readme 3.txt"), encoding: .utf8) == "Hello from the demo Mac.\n")
        // Nothing is left where downloads are received.
        let staged = try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
        for id in [first, second, missing, third] {
            #expect(!staged.contains("Marionette-Transfer-\(id.uuidString)"))
        }

        let chosen = root.appending(path: "chosen.txt")
        let explicit = queue.download(readme, to: chosen)
        let local = root.appending(path: "up.txt")
        try Data("up".utf8).write(to: local)
        let upload = queue.upload(local)
        await queue.waitUntilIdle()
        #expect(item(explicit)?.localURL == chosen)
        #expect(item(upload)?.state == .finished && item(upload)?.localURL == nil)

        // The destination is asked for when a download finishes, so it can change.
        let elsewhere = root.appending(path: "Elsewhere")
        queue.destinationDirectory = { elsewhere }
        let moved = queue.download(readme)
        await queue.waitUntilIdle()
        #expect(item(moved)?.localURL?.standardizedFileURL == elsewhere.appending(path: "Readme.txt").standardizedFileURL)
        await session.disconnect()
    }

    @Test func aReceivedFileCanBeDeletedFromTheList() async throws {
        var scenario = fastScenario()
        scenario.transferRate = 1 << 30
        let session = try await SimulatedBackend(scenario: scenario).connect(
            ConnectionRequest(transport: SimulatedTransport(), prompts: StaticPromptHandler(username: "demo", password: "demo"))
        )
        let root = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = TransferQueue(destinationDirectory: { root })
        queue.setTransfer(session.capabilities.fileTransfer.value)
        let readme = RemoteFileEntry(path: "/Users/demo/Documents/Readme.txt", name: "Readme.txt", isDirectory: false)
        let kept = queue.download(readme)
        let deleted = queue.download(readme)
        let local = root.appending(path: "up.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("up".utf8).write(to: local)
        let upload = queue.upload(local)
        await queue.waitUntilIdle()
        let file = try #require(queue.items.first { $0.id == deleted }?.localURL)

        try queue.deleteReceivedFile(deleted)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(queue.items.map(\.id) == [kept, upload])
        // A file already deleted elsewhere just leaves the list.
        let other = try #require(queue.items.first?.localURL)
        try FileManager.default.removeItem(at: other)
        try queue.deleteReceivedFile(kept)
        #expect(queue.items.map(\.id) == [upload])
        // What was sent is the person's own file: it is never deleted this way.
        try queue.deleteReceivedFile(upload)
        #expect(FileManager.default.fileExists(atPath: local.path))
        await session.disconnect()
    }

    @Test func aCancelledDownloadLeavesNothingBehind() async throws {
        var scenario = fastScenario()
        scenario.transferRate = 4
        let session = try await SimulatedBackend(scenario: scenario).connect(
            ConnectionRequest(transport: SimulatedTransport(), prompts: StaticPromptHandler(username: "demo", password: "demo"))
        )
        let root = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = TransferQueue(destinationDirectory: { root })
        queue.setTransfer(session.capabilities.fileTransfer.value)
        let id = queue.download(RemoteFileEntry(path: "/Users/demo/Documents/Readme.txt", name: "Readme.txt", isDirectory: false))
        try await waitUntil { queue.items.first?.state == .running }
        queue.cancel(id)
        await queue.waitUntilIdle()
        #expect(queue.items.first?.state == .cancelled && queue.items.first?.localURL == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "Readme.txt").path))
        #expect(!FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appending(path: "Marionette-Transfer-\(id.uuidString)").path))
        await session.disconnect()
    }

    @Test func aDownloadCutOffWithItsConnectionFailsSayingSoAndLeavesNoPartialFile() async throws {
        var scenario = fastScenario()
        scenario.transferRate = 4
        let session = try await SimulatedBackend(scenario: scenario).connect(
            ConnectionRequest(transport: SimulatedTransport(), prompts: StaticPromptHandler(username: "demo", password: "demo"))
        )
        let root = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = TransferQueue(destinationDirectory: { root })
        queue.setTransfer(session.capabilities.fileTransfer.value)
        let chosen = root.appending(path: "Readme.txt")
        let readme = RemoteFileEntry(path: "/Users/demo/Documents/Readme.txt", name: "Readme.txt", isDirectory: false)
        queue.download(readme, to: chosen)
        let waiting = queue.download(readme)
        try await waitUntil { queue.items.first?.state == .running }
        queue.setTransfer(nil)
        await queue.waitUntilIdle()
        #expect(queue.items.first?.state == .failed(message: TransferQueue.interruptedMessage))
        #expect(queue.items.first { $0.id == waiting }?.state == .failed(message: "The session ended."))
        #expect(!FileManager.default.fileExists(atPath: chosen.path))
        await session.disconnect()
    }

    @Test func namesAreMadeUniqueAndKeptInsideTheFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func name(_ wanted: String) -> String { TransferQueue.uniqueURL(forFileNamed: wanted, in: folder).lastPathComponent }
        func create(_ name: String) throws { try Data().write(to: folder.appending(path: name)) }

        #expect(name("Report.pdf") == "Report.pdf")
        try create("Report.pdf")
        #expect(name("Report.pdf") == "Report 2.pdf")
        try create("Report 2.pdf")
        #expect(name("Report.pdf") == "Report 3.pdf")
        try create("Makefile")
        #expect(name("Makefile") == "Makefile 2")
        try create("archive.tar.gz")
        #expect(name("archive.tar.gz") == "archive.tar 2.gz")
        try create(".profile")
        #expect(name(".profile") == ".profile 2")

        // A remote name cannot choose another folder.
        for hostile in ["../escape.txt", "/etc/passwd", "..", ".", ""] {
            let url = TransferQueue.uniqueURL(forFileNamed: hostile, in: folder)
            #expect(url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        }
        #expect(name("..") == "Download")
        #expect(name("../escape.txt") == ".._escape.txt")
    }
}
