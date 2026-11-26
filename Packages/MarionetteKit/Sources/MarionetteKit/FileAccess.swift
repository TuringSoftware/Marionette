// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
public import RemoteDesktopCore
import RemoteDesktopSimulated
import RemoteDesktopTransport
import SwiftSSH2

/// Puts what went wrong with a remote file into words.
enum FileTransferFailure {
    static func message(for error: any Error) -> String {
        if isMissingFile(error) { return String(localized: "The item no longer exists on the remote computer.", bundle: #bundle) }
        return switch error {
        case SSHError.sftp(.permissionDenied):
            String(localized: "You don’t have permission to do this on the remote computer.", bundle: #bundle)
        case SSHError.transportClosed, SSHError.disconnected, TransportError.closed:
            String(localized: "The connection to the remote computer was lost.", bundle: #bundle)
        case let error as CocoaError:
            error.localizedDescription
        case let error as any LocalizedError where error.errorDescription != nil:
            error.errorDescription ?? ""
        default:
            String(describing: error)
        }
    }

    static func isMissingFile(_ error: any Error) -> Bool {
        if case SSHError.sftp(.noSuchFile) = error { return true }
        if case SimulationError.noSuchFile = error { return true }
        return false
    }
}

// MARK: - File access

/// Where a session's file transfer comes from, and the way to get one when it has none.
///
/// A session has file transfer from the start when its back end brings its own or when it runs
/// through an SSH tunnel (SFTP rides on the tunnel's connection). Otherwise the user can sign in to
/// the computer over SSH, which opens a separate connection just for files.
///
/// A back end's own transfer may send and fetch without being able to list folders (Screen
/// Sharing's). Then SFTP, where there is any, is preferred for everything, and signing in over SSH
/// stays on offer as the way to browse.
@MainActor
@Observable
public final class FileAccessModel {
    public enum State: Sendable, Hashable {
        /// Files cannot be moved, and why, in words for the user.
        case unavailable(String)
        /// No file transfer yet; "Sign In over SSH" can be offered.
        case signedOut
        /// Signing in. Questions arrive through the session's prompt handler meanwhile.
        case connecting
        case ready
        /// Signing in failed, and why. Signing in can be tried again.
        case failed(String)
    }

    public private(set) var state: State = .unavailable(FileAccessModel.notConnected)
    /// The file transfer to use; non-nil exactly when ``state`` is `.ready`.
    public private(set) var transfer: (any FileTransfer)?
    /// Whether ``transfer`` can list folders. Without that, files can be sent (to the transfer's
    /// default folder) but not browsed.
    public var canBrowse: Bool { transfer?.canBrowse ?? false }
    /// Signing in over SSH is under way. While a transfer that cannot browse is ready, ``state``
    /// stays `.ready` and this says so instead.
    public private(set) var isSigningIn = false
    /// Why the last sign-in failed, while a transfer that cannot browse is ready.
    public private(set) var signInFailure: String?
    /// Called whenever ``transfer`` changes, with the new value. The session hands it to its
    /// ``TransferQueue``.
    @ObservationIgnored public var onTransferChanged: (((any FileTransfer)?) -> Void)?

    private static let notConnected = String(localized: "Not connected.", bundle: #bundle)

    @ObservationIgnored private let ssh: SSHServices?
    @ObservationIgnored private let prompts: any PromptHandler
    @ObservationIgnored private let access: SecretAccess
    @ObservationIgnored private let accountCredentials: () -> (username: String, password: String)?
    @ObservationIgnored private let onSignedIn: () -> Void

    @ObservationIgnored private var computer: ComputerConfiguration?
    /// The session is connected. A connection of this model's own can outlive it (see
    /// ``sessionInterrupted()``).
    @ObservationIgnored private var isSessionConnected = false
    @ObservationIgnored private var builtIn: (any FileTransfer)?
    @ObservationIgnored private var tunnelFiles: (any FileTransfer)?
    /// The connection this model opened by signing in. Never the tunnel's.
    @ObservationIgnored private var own: (handle: any SSHSessionHandle, files: any FileTransfer)?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var failure: String?
    /// Bumped whenever a sign-in in flight stops mattering.
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - ssh: What signing in connects with; `nil` where there is no SSH.
    ///   - prompts: Asked about host keys, passwords and passphrases while signing in.
    ///   - accountCredentials: The account and password already used for remote desktop this
    ///     session, if known. Tried first, so that signing in to the same account asks nothing.
    ///   - access: Unlocks an SSH key that requires the device owner.
    ///   - onSignedIn: Called when signing in succeeded: what was typed on the way was right.
    public init(
        ssh: SSHServices?,
        prompts: any PromptHandler,
        access: SecretAccess = .denied,
        accountCredentials: @escaping () -> (username: String, password: String)? = { nil },
        onSignedIn: @escaping () -> Void = {}
    ) {
        self.ssh = ssh
        self.prompts = prompts
        self.access = access
        self.accountCredentials = accountCredentials
        self.onSignedIn = onSignedIn
    }

    /// File access for a session whose questions `broker` answers: the remote-desktop password the
    /// broker knows is tried first, and what the user asks to remember is kept on success.
    public convenience init(ssh: SSHServices?, broker: PromptBroker) {
        self.init(
            ssh: ssh,
            prompts: broker,
            access: broker.secretAccess,
            accountCredentials: { [weak broker] in broker?.knownCredentials(for: .remoteDesktop(host: "")) },
            onSignedIn: { [weak broker] in broker?.connectionSucceeded() }
        )
    }

    // MARK: Session life cycle

    /// The session is connected. `tunnel` is the SSH connection it runs through, if any
    /// (``ConnectionLadder/Outcome/ssh``); `builtIn` is the back end's own file transfer, if it has one.
    /// Either makes files ready at once.
    public func sessionConnected(computer: ComputerConfiguration, tunnel: (any SSHSessionHandle)?, builtIn: (any FileTransfer)?) {
        abandonSignIn()
        // A connection opened by signing in belongs to the computer, not to one session of it: a
        // reconnect keeps it, with whatever it is transferring.
        if self.computer?.id != computer.id { closeOwn() }
        self.computer = computer
        isSessionConnected = true
        self.builtIn = builtIn
        tunnelFiles = tunnel?.makeFileTransfer()
        failure = nil
        refresh(transferChanged: true)
    }

    /// The back end's own file transfer appeared or went away while connected.
    public func setBuiltIn(_ transfer: (any FileTransfer)?) {
        guard isSessionConnected else { return }
        builtIn = transfer
        refresh(transferChanged: true)
    }

    /// The session dropped and may come back: reconnecting, or ended with Retry on offer. File
    /// transfer that came with it (the back end's, the tunnel's) goes; a connection this model
    /// opened by signing in does not depend on the session, so it stays, transfers and all.
    public func sessionInterrupted() {
        abandonSignIn()
        isSessionConnected = false
        builtIn = nil
        tunnelFiles = nil
        failure = nil
        refresh(transferChanged: true)
    }

    /// The session is over for good. Closes a connection this model opened; the tunnel's
    /// connection is the session's to close.
    public func sessionEnded() {
        sessionInterrupted()
        computer = nil
        if own != nil {
            closeOwn()
            refresh(transferChanged: true)
        }
    }

    // MARK: Signing in

    /// Whether ``signIn()`` would do anything: connected, SSH exists, and there is no file transfer
    /// or only one that cannot browse.
    public var canSignIn: Bool {
        switch state {
        case .signedOut, .failed: true
        case .ready: ssh != nil && !canBrowse && own == nil && tunnelFiles == nil && signInTask == nil
        case .unavailable, .connecting: false
        }
    }

    /// Whether files come from a connection ``signIn()`` opened, which ``signOut()`` would close.
    public var isSignedIn: Bool { own != nil }

    /// Opens an SSH connection to the computer itself, with the session's account, for files.
    public func signIn() {
        guard canSignIn, let ssh, let computer else { return }
        var target = computer.fileAccessTarget
        let known = accountCredentials()
        if target.username.trimmingCharacters(in: .whitespaces).isEmpty, let known, !known.username.isEmpty {
            target.username = known.username
        }
        // The remote-desktop password is the SSH password only if it is the same account.
        let preset = known.flatMap { $0.username == target.username && !$0.password.isEmpty ? $0.password : nil }
        failure = nil
        generation += 1
        let token = generation
        let prompts = prompts
        let access = access
        signInTask = Task { [weak self] in
            let result: Result<any SSHSessionHandle, SSHConnectionError>
            do throws(SSHConnectionError) {
                result = .success(try await ssh.open(target, prompts: prompts, access: access, presetPassword: preset, purpose: .fileAccess(host: target.server.host)))
            } catch {
                result = .failure(error)
            }
            guard let self, self.generation == token else {
                // Signed out or disconnected meanwhile: nobody wants this connection any more.
                if case .success(let handle) = result { await handle.close() }
                return
            }
            self.signInTask = nil
            switch result {
            case .success(let handle):
                self.own = (handle, handle.makeFileTransfer())
                self.onSignedIn()
            case .failure(.cancelled):
                break
            case .failure(let error):
                self.failure = error.fileAccessMessage(server: target.server)
            }
            self.refresh(transferChanged: self.own != nil)
        }
        refresh(transferChanged: false)
    }

    /// Stops signing in, or closes the connection ``signIn()`` opened. Does nothing to file transfer
    /// that comes from the tunnel or the back end.
    public func signOut() {
        guard signInTask != nil || own != nil || failure != nil else { return }
        abandonSignIn()
        let hadOwn = own != nil
        closeOwn()
        failure = nil
        refresh(transferChanged: hadOwn)
    }

    /// Suspends until a sign-in in flight has finished. For tests.
    public func waitUntilSettled() async {
        while let signInTask {
            await signInTask.value
        }
    }

    private func abandonSignIn() {
        generation += 1
        signInTask?.cancel()
        signInTask = nil
    }

    private func closeOwn() {
        guard let handle = own?.handle else { return }
        own = nil
        Task { await handle.close() }
    }

    /// Derives ``state`` and ``transfer`` from what there is.
    private func refresh(transferChanged: Bool) {
        let candidates = [builtIn, tunnelFiles, own?.files].compactMap { $0 }
        let files = candidates.first { $0.canBrowse } ?? candidates.first
        isSigningIn = signInTask != nil
        signInFailure = failure
        if files != nil {
            state = .ready
        } else if !isSessionConnected {
            state = .unavailable(Self.notConnected)
        } else if signInTask != nil {
            state = .connecting
        } else if let failure {
            state = .failed(failure)
        } else if ssh == nil {
            state = .unavailable(String(localized: "File transfer isn’t available with this computer.", bundle: #bundle))
        } else {
            state = .signedOut
        }
        if transferChanged {
            transfer = files
            onTransferChanged?(files)
        }
    }
}

// MARK: - Browsing

/// One remote folder's contents, with the means to move around.
@MainActor
@Observable
public final class RemoteFileBrowserModel {
    /// One step of the path from the root to the folder shown.
    public struct Crumb: Sendable, Hashable, Identifiable {
        public var name: String
        public var path: String
        public var id: String { path }
    }

    /// The folder shown, as an absolute path. Empty until the starting folder is known.
    public private(set) var path = ""
    /// The folder's contents: folders first, then by name as the Finder orders them. Nothing is hidden.
    public private(set) var entries: [RemoteFileEntry] = []
    public private(set) var isLoading = false
    /// Why the folder could not be read, if it could not.
    public private(set) var errorMessage: String?

    @ObservationIgnored private let transfer: any FileTransfer
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// Starts loading at once. Without `startDirectory`, browsing starts in the home folder: the
    /// folder that holds the back end's upload folder ("Downloads"), or that folder itself.
    public init(transfer: any FileTransfer, startDirectory: String? = nil) {
        self.transfer = transfer
        load(startDirectory.map(Self.normalized), keepingEntries: false)
    }

    public var canGoUp: Bool { !path.isEmpty && path != "/" }

    /// The path from the root to the folder shown, for a path bar. The root is called "/".
    public var breadcrumbs: [Crumb] {
        guard !path.isEmpty else { return [] }
        var crumbs = [Crumb(name: "/", path: "/")]
        var current = ""
        for component in path.split(separator: "/") {
            current += "/" + component
            crumbs.append(Crumb(name: String(component), path: current))
        }
        return crumbs
    }

    /// Shows a folder's contents. Does nothing for a file.
    public func open(_ entry: RemoteFileEntry) {
        guard entry.isDirectory else { return }
        go(to: entry.path)
    }

    /// Shows the folder at `path`: a breadcrumb, or somewhere typed.
    public func go(to path: String) {
        load(Self.normalized(path), keepingEntries: false)
    }

    public func goUp() {
        guard canGoUp else { return }
        go(to: Self.parent(of: path))
    }

    /// Reads the folder shown again.
    public func reload() {
        load(path.isEmpty ? nil : path, keepingEntries: true)
    }

    /// Suspends until nothing is loading. For tests.
    public func waitUntilLoaded() async {
        while let loadTask {
            await loadTask.value
            if self.loadTask == loadTask { break }
        }
    }

    private func load(_ target: String?, keepingEntries: Bool) {
        generation += 1
        let token = generation
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        if let target, target != path || !keepingEntries {
            path = target
            entries = []
        }
        let transfer = transfer
        loadTask = Task { [weak self] in
            var directory = target
            let outcome: Result<[RemoteFileEntry], any Error>
            do {
                if directory == nil {
                    directory = Self.home(forUploadDirectory: try await transfer.defaultUploadDirectory())
                }
                outcome = .success(Self.sorted(try await transfer.list(directory: directory ?? "/")))
            } catch {
                outcome = .failure(error)
            }
            guard let self, self.generation == token else { return }
            self.loadTask = nil
            self.isLoading = false
            self.path = directory ?? "/"
            switch outcome {
            case .success(let entries):
                self.entries = entries
            case .failure(let error):
                self.entries = []
                self.errorMessage = FileTransferFailure.isMissingFile(error)
                    ? String(localized: "This folder no longer exists.", bundle: #bundle)
                    : FileTransferFailure.message(for: error)
            }
        }
    }

    // MARK: Pure helpers

    /// Folders first, then by name with numbers in numeric order and case ignored.
    nonisolated static func sorted(_ entries: [RemoteFileEntry]) -> [RemoteFileEntry] {
        entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
    }

    /// An absolute path without doubled or trailing slashes.
    nonisolated static func normalized(_ path: String) -> String {
        "/" + path.split(separator: "/").joined(separator: "/")
    }

    nonisolated static func parent(of path: String) -> String {
        "/" + path.split(separator: "/").dropLast().joined(separator: "/")
    }

    /// Where browsing starts, given where uploads go: above "Downloads", or in the folder itself.
    nonisolated static func home(forUploadDirectory directory: String) -> String {
        let path = normalized(directory)
        return path.split(separator: "/").last == "Downloads" ? parent(of: path) : path
    }
}
