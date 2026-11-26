// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RemoteDesktopCore
import RemoteDesktopTransport
import SwiftSSH2TestSupport
import Synchronization
import Testing
@testable import MarionetteKit

@Suite struct SecretProtectionTests {
    @Test func theOptionsAdjustEachOtherAsTheKeychainRequires() {
        var protection = SecretProtection.standard
        // In backups, out of iCloud Keychain, until chosen.
        #expect(!protection.requiresUserPresence && protection.includedInBackups && !protection.synchronizes)
        protection.synchronizes = true

        // iCloud Keychain carries no item behind an access control.
        protection.requiresUserPresence = true
        #expect(protection.requiresUserPresence && protection.includedInBackups && !protection.synchronizes)
        protection.synchronizes = true
        #expect(!protection.requiresUserPresence && protection.includedInBackups && protection.synchronizes)

        // What stays on this device is not synchronised either.
        protection.includedInBackups = false
        #expect(!protection.includedInBackups && !protection.synchronizes)
        protection.synchronizes = true
        #expect(protection.includedInBackups && protection.synchronizes)

        // The initialiser applies the same rules.
        #expect(SecretProtection(requiresUserPresence: true, includedInBackups: true, synchronizes: true).synchronizes == false)
        #expect(SecretProtection(includedInBackups: false, synchronizes: true).synchronizes == false)
        #expect(SecretProtection(requiresUserPresence: true).withoutUserPresence == SecretProtection(synchronizes: false))
    }

    @Test func theSecureEnclaveKeepsAKeyOutOfBackupsAndICloud() {
        var storage = SSHKeyStorage()
        #expect(!storage.isInSecureEnclave && storage.protection == .standard)
        storage.protection.requiresUserPresence = true
        storage.isInSecureEnclave = true
        #expect(storage.protection == SecretProtection(requiresUserPresence: true, includedInBackups: false, synchronizes: false))
        // Owner check and Secure Enclave go together.
        storage.protection.requiresUserPresence = false
        #expect(storage.isInSecureEnclave)
        storage.protection.includedInBackups = true
        #expect(!storage.isInSecureEnclave)
        storage.isInSecureEnclave = true
        storage.protection.synchronizes = true
        #expect(!storage.isInSecureEnclave && storage.protection.includedInBackups)
    }

    @Test func aKeysStorageIsSummedUpInAFewWords() {
        #expect(SSHKeyStorage().summary(ownerCheck: .faceID) == "Backed Up")
        #expect(SSHKeyStorage(protection: SecretProtection(synchronizes: true)).summary(ownerCheck: .faceID) == "iCloud Keychain")
        #expect(SSHKeyStorage(protection: SecretProtection(requiresUserPresence: true)).summary(ownerCheck: .touchID) == "Backed Up · Touch ID")
        #expect(SSHKeyStorage(protection: .thisDeviceOnly).summary(ownerCheck: .faceID) == nil)
        #expect(SSHKeyStorage(protection: SecretProtection(requiresUserPresence: true, includedInBackups: false)).summary(ownerCheck: .faceID) == "Face ID")
        #expect(SSHKeyStorage(isInSecureEnclave: true, protection: SecretProtection(requiresUserPresence: true)).summary(ownerCheck: .faceID) == "Secure Enclave · Face ID")
    }

    @Test func storedProtectionDecodesAndComputersWithoutOneGetTheStandard() throws {
        let protection = SecretProtection(requiresUserPresence: true)
        #expect(try JSONDecoder().decode(SecretProtection.self, from: JSONEncoder().encode(protection)) == protection)
        var computer = ComputerConfiguration(host: "studio-mac.local")
        #expect(computer.passwordProtection == .standard)
        #expect(!SecretProtection.standard.synchronizes && SecretProtection.standard.includedInBackups)
        computer.passwordProtection = protection
        #expect(try JSONDecoder().decode(ComputerConfiguration.self, from: JSONEncoder().encode(computer)).passwordProtection == protection)
        // Passwords never go to iCloud Keychain.
        computer.passwordProtection.synchronizes = true
        #expect(!computer.passwordProtection.synchronizes)
    }

    @Test func peopleAskedAtOnceAreAskedOnce() async {
        let asked = Mutex(0)
        let access = SecretAccess { _ in
            asked.withLock { $0 += 1 }
            try? await Task.sleep(for: .milliseconds(50))
            return true
        }
        async let first = access.authenticate(reason: "a")
        async let second = access.authenticate(reason: "b")
        #expect(await [first, second] == [true, true])
        #expect(await access.authenticate(reason: "c"))
        #expect(asked.withLock { $0 } == 1)
        access.invalidate()
        #expect(!access.isGranted)

        let declining = SecretAccess { _ in
            asked.withLock { $0 += 1 }
            return false
        }
        #expect(await !declining.authenticate(reason: "a"))
        // A refusal is not remembered: the next secret asks again.
        #expect(await !declining.authenticate(reason: "b"))
        #expect(asked.withLock { $0 } == 3)
    }

    @Test func aProtectedSecretIsReadOnlyWithTheOwnersAgreement() async throws {
        let secrets = InMemorySecretStore()
        let key = SecretKey(appWide: .keyPassphrase, name: "Work")
        try secrets.setSecret("open sesame", for: key, protection: SecretProtection(requiresUserPresence: true))
        #expect(throws: SecretStoreError.authenticationRequired) { try secrets.secret(for: key) }
        #expect(secrets.hasSecret(for: key))
        #expect(try await secrets.unlockedSecret(for: key, access: .denied, reason: "") == nil)
        let access = SecretAccess { _ in true }
        #expect(try await secrets.unlockedSecret(for: key, access: access, reason: "") == "open sesame")
        #expect(try secrets.secret(for: key, access: access) == "open sesame")
        // Unprotected secrets need nothing.
        try secrets.setSecret("plain", for: key)
        #expect(try secrets.secret(for: key) == "plain" && secrets.protection(for: key) == .thisDeviceOnly)
    }
}

/// Serialised: making a large RSA key and running OpenSSH's tool block a thread each, and several at
/// once starve the timing-sensitive tests running beside them.
@Suite(.serialized) struct SSHKeyGenerationTests {
    /// Every kind and size a key can be made in, checked by OpenSSH itself.
    @Test(arguments: SSHKeyType.allCases.flatMap { type in type.sizes.map { SSHKeyAlgorithm(type: type, bits: $0) } })
    func eachKindOfKeyIsOneOpenSSHAccepts(_ algorithm: SSHKeyAlgorithm) throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SSHKeyStore(secrets: InMemorySecretStore())
        let info = try store.generate(algorithm: algorithm)
        #expect(info.name == "\(algorithm.title) Key")
        #expect(info.typeName == algorithm.title)

        let path = folder.appending(path: "key").path
        try String(decoding: try #require(try store.privateKey(named: info.name)), as: UTF8.self).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let derived = try runTool("/usr/bin/ssh-keygen", ["-y", "-f", path]).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(derived == (try #require(info.authorizedKeysLine)))
        // "3072 SHA256:… comment (RSA)"
        let listed = try runTool("/usr/bin/ssh-keygen", ["-lf", path]).split(separator: " ")
        #expect(listed[0] == "\(algorithm.bits)" && String(listed[1]) == info.fingerprint)
    }

    @Test func onlyShortRSAKeysAreNotRecommended() {
        let cautioned = SSHKeyType.allCases.flatMap { type in type.sizes.map { SSHKeyAlgorithm(type: type, bits: $0) } }.filter { !$0.isRecommended }
        #expect(cautioned == [SSHKeyAlgorithm(type: .rsa, bits: 1024)])
        #expect(cautioned.first?.caution?.hasPrefix("A 1024-bit RSA key can be broken.") == true)
        #expect(SSHKeyAlgorithm.ed25519.caution == nil)
        // A size the type does not come in becomes its default.
        #expect(SSHKeyAlgorithm(type: .ecdsa, bits: 3072) == SSHKeyAlgorithm(type: .ecdsa, bits: 256))
        #expect(SSHKeyAlgorithm(type: .rsa).bits == 3072)
    }

    @Test func unnamedKeysGetUnusedGenericNames() throws {
        let store = SSHKeyStore(secrets: InMemorySecretStore(), hardware: SimulatedHardwareKeys())
        #expect(try store.generate().name == "Ed25519 Key")
        #expect(try store.generate(named: "  ").name == "Ed25519 Key 2")
        #expect(try store.generate(algorithm: SSHKeyAlgorithm(type: .rsa, bits: 2048)).name == "RSA 2048 Key")
        #expect(try store.generate(storage: SSHKeyStorage(isInSecureEnclave: true)).name == "Secure Enclave Key")
        #expect(try store.generate(storage: SSHKeyStorage(isInSecureEnclave: true)).name == "Secure Enclave Key 2")
        let text = try SSHPrivateKeyFile.generate(.ed25519).text
        #expect(try store.importKey(text: text).name == "Imported Key")
        #expect(try store.importKey(named: "", text: text).name == "Imported Key 2")
        #expect(throws: SSHKeyError.nameInUse("Imported Key")) { try store.importKey(named: "Imported Key", text: text) }
    }

    @Test func eachKeyIsKeptAsChosenAndItsDescriptionNeverAsksTheOwner() throws {
        let secrets = InMemorySecretStore()
        let store = SSHKeyStore(secrets: secrets, hardware: SimulatedHardwareKeys())
        let guarded = SecretProtection(requiresUserPresence: true)
        try store.generate(named: "Guarded", storage: SSHKeyStorage(protection: guarded))
        try store.importKey(named: "Imported", text: try SSHPrivateKeyFile.generate(.ed25519).text)
        try store.generate(named: "Enclave", storage: SSHKeyStorage(isInSecureEnclave: true))

        #expect(secrets.protection(for: SecretKey(appWide: .sshPrivateKey, name: "Guarded")) == guarded)
        #expect(secrets.protection(for: SecretKey(appWide: .sshKeyInfo, name: "Guarded")) == guarded.withoutUserPresence)
        #expect(secrets.protection(for: SecretKey(appWide: .sshPrivateKey, name: "Imported")) == .standard)
        #expect(secrets.protection(for: SecretKey(appWide: .sshPrivateKey, name: "Enclave")) == .thisDeviceOnly)
        // Listing reads descriptions only.
        #expect(try store.all().map(\.name) == ["Enclave", "Guarded", "Imported"])
        #expect(try store.privateKey(named: "Guarded") == nil)
        // A passphrase is kept as its key is.
        #expect(store.passphraseProtection(for: "Guarded") == guarded)

        let enclave = try #require(store.key(named: "Enclave"))
        #expect(enclave.type == "ecdsa-sha2-nistp256" && enclave.typeName == "ECDSA P-256" && enclave.storage.isInSecureEnclave)
        #expect(enclave.authorizedKeysLine?.hasPrefix("ecdsa-sha2-nistp256 ") == true)
    }

    @Test func aProtectedKeyIsUnlockedOnlyWithTheOwnersAgreement() async throws {
        let store = SSHKeyStore(secrets: InMemorySecretStore(), hardware: SimulatedHardwareKeys())
        let guarded = SSHKeyStorage(protection: SecretProtection(requiresUserPresence: true))
        try store.generate(named: "Guarded", storage: guarded)
        var enclave = guarded
        enclave.isInSecureEnclave = true
        try store.generate(named: "Enclave", storage: enclave)

        #expect(await store.loginKey(named: "Guarded", access: .denied, reason: "") == nil)
        #expect(await store.loginKey(named: "Enclave", access: .denied, reason: "") == nil)
        #expect(await store.loginKey(named: "Missing", access: SecretAccess { _ in true }, reason: "") == nil)
        guard case .file(let file) = await store.loginKey(named: "Guarded", access: SecretAccess { _ in true }, reason: "") else {
            Issue.record("expected the key file")
            return
        }
        #expect(try SSHPrivateKeyFile(text: String(decoding: file, as: UTF8.self)).type == "ssh-ed25519")
        guard case .signer(let signer) = await store.loginKey(named: "Enclave", access: SecretAccess { _ in true }, reason: "") else {
            Issue.record("expected a signer")
            return
        }
        #expect(signer.publicKey == store.key(named: "Enclave")?.publicKey)
        #expect(signer.sign(Data("data".utf8)) != nil)
    }

    @MainActor
    @Test func aChosenKeyFileFillsThePasteBoxOnlyIfItHoldsAPrivateKey() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "MarionetteKitTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try SSHPrivateKeyFile.generate(.ed25519)
        let keyFile = folder.appending(path: "id_ed25519")
        try key.text.write(to: keyFile, atomically: true, encoding: .utf8)
        let publicFile = folder.appending(path: "id_ed25519.pub")
        try "ssh-ed25519 AAAA me@example".write(to: publicFile, atomically: true, encoding: .utf8)
        let binary = folder.appending(path: "photo.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x80]).write(to: binary)

        let form = SSHKeyFormModel(kind: .importing, store: SSHKeyStore(secrets: InMemorySecretStore()), ownerCheck: .faceID)
        form.loadFile(at: keyFile)
        #expect(form.text == key.text && form.problem == nil)
        for wrong in [publicFile, binary, folder.appending(path: "missing")] {
            form.loadFile(at: wrong)
            #expect(form.text == key.text, "a file that is not a private key leaves the box as it was")
            #expect(form.problem == SSHKeyError.notAPrivateKey.message)
        }
    }

    @Test func noSecureEnclaveNoKey() throws {
        struct Absent: HardwareKeys {
            var isAvailable: Bool { false }
            func makeKey(requiresUserPresence: Bool) throws -> (handle: Data, publicKey: Data) { throw SecretStoreError.storeFailure(code: -1) }
            func sign(_ data: Data, handle: Data, access: SecretAccess?) -> Data? { nil }
        }
        let store = SSHKeyStore(secrets: InMemorySecretStore(), hardware: Absent())
        #expect(throws: SSHKeyError.secureEnclaveUnavailable) { try store.generate(storage: SSHKeyStorage(isInSecureEnclave: true)) }
        #expect(try store.all().isEmpty)
    }
}

@MainActor
@Suite struct OneOwnerCheckTests {
    /// The tunnel's key and the saved password both need the owner: one question unlocks both.
    @Test func theTunnelsKeyAndTheSavedPasswordAskTheOwnerOnce() async throws {
        var server = ScriptedSSHConnector.Server()
        let fixture = TunnelFixture(server)
        let info = try fixture.keys.generate(named: "Work", storage: SSHKeyStorage(protection: SecretProtection(requiresUserPresence: true)))
        let file = try #require(await fixture.keys.loginKey(named: "Work", access: SecretAccess { _ in true }, reason: ""))
        guard case .file(let key) = file else { return }
        server.authorizedKeys = [key: nil]
        _ = info
        let connector = ScriptedSSHConnector(server)
        await fixture.hostKeys.remember(server.hostKey, for: fixture.computer.tunnelServer)
        var computer = fixture.computer
        computer.tunnel.keyName = "Work"
        computer.passwordProtection.requiresUserPresence = true
        try fixture.secrets.setSecret("mac-secret", for: .remoteDesktopPassword(for: computer), protection: computer.passwordProtection)

        let asked = Mutex(0)
        let broker = PromptBroker(computer: computer, secrets: fixture.secrets, access: SecretAccess { _ in
            asked.withLock { $0 += 1 }
            return true
        })
        let factory = LiveTransportFactory(ssh: SSHServices(connector: connector, hostKeys: fixture.hostKeys, keys: fixture.keys))
        _ = try await factory.makeTransport(for: computer, prompts: broker)
        #expect(connector.logins.first?.privateKey == key)
        let answer = await broker.resolve(.credentials(CredentialRequest(context: .remoteDesktop(host: computer.host), kind: .passwordOnly)))
        #expect(answer == .credentials(username: "alex", password: "mac-secret"))
        #expect(broker.pending == nil)
        #expect(asked.withLock { $0 } == 1)
    }

    @Test func leavingTheScreenLocksProtectedSecretsAgain() async throws {
        var computer = ComputerConfiguration(name: "Studio", host: "studio-mac.local", username: "alex")
        computer.passwordProtection.requiresUserPresence = true
        let secrets = InMemorySecretStore()
        try secrets.setSecret("mac-secret", for: .remoteDesktopPassword(for: computer), protection: computer.passwordProtection)
        let asked = Mutex(0)
        let broker = PromptBroker(computer: computer, secrets: secrets, access: SecretAccess { _ in
            asked.withLock { $0 += 1 }
            return true
        })
        let request = CredentialRequest(context: .remoteDesktop(host: computer.host), kind: .passwordOnly)
        #expect(await broker.resolve(.credentials(request)) == .credentials(username: "alex", password: "mac-secret"))
        // A reconnect while the app is on screen asks nothing.
        #expect(await broker.resolve(.credentials(request)) == .credentials(username: "alex", password: "mac-secret"))
        #expect(asked.withLock { $0 } == 1)
        broker.lockProtectedSecrets()
        #expect(!broker.secretAccess.isGranted)
        #expect(await broker.resolve(.credentials(request)) == .credentials(username: "alex", password: "mac-secret"))
        #expect(asked.withLock { $0 } == 2, "the owner is asked again")
    }

    @Test func aPasswordTheOwnerDidNotUnlockIsAskedFor() async throws {
        var computer = ComputerConfiguration(name: "Studio", host: "studio-mac.local", username: "alex")
        computer.passwordProtection.requiresUserPresence = true
        let secrets = InMemorySecretStore()
        try secrets.setSecret("mac-secret", for: .remoteDesktopPassword(for: computer), protection: computer.passwordProtection)
        let broker = PromptBroker(computer: computer, secrets: secrets, access: .denied)
        let request = CredentialRequest(context: .remoteDesktop(host: computer.host), kind: .passwordOnly)
        let answer = Task { await broker.resolve(.credentials(request)) }
        try await waitUntil { broker.pending != nil }
        broker.reply(.credentials(username: "alex", password: "typed"), remember: true)
        #expect(await answer.value == .credentials(username: "alex", password: "typed"))
        broker.connectionSucceeded()
        // Remembered as the computer says.
        #expect(secrets.protection(for: .remoteDesktopPassword(for: computer)) == computer.passwordProtection)
    }

    @Test func aRememberedSSHPasswordIsKeptAsTheComputerSays() async throws {
        let fixture = TunnelFixture(TunnelFixture.accepting(password: "right"))
        await fixture.hostKeys.remember(fixture.connector.server.hostKey, for: fixture.computer.tunnelServer)
        var computer = fixture.computer
        computer.passwordProtection.includedInBackups = false
        let broker = PromptBroker(computer: computer, secrets: fixture.secrets)
        let factory = fixture.factory
        let attempt = Task { try await factory.makeTransport(for: computer, prompts: broker) }
        try await waitUntil { broker.pending != nil }
        broker.reply(.credentials(username: "alex", password: "right"), remember: true)
        _ = try await attempt.value
        broker.connectionSucceeded()
        #expect(fixture.secrets.protection(for: .sshPassword(for: computer, server: computer.tunnelServer)) == computer.passwordProtection)
    }
}

@MainActor
@Suite struct PasswordSecurityEditorTests {
    private func rig(_ owner: OwnerAuthentication) throws -> (LibraryModel, InMemorySecretStore, ComputerConfiguration) {
        let secrets = InMemorySecretStore()
        let repository = ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true))
        var computer = ComputerConfiguration(name: "Studio", host: "studio-mac.local", username: "alex")
        computer.passwordProtection.requiresUserPresence = true
        repository.save(computer, now: Date())
        try secrets.setSecret("mac-secret", for: .remoteDesktopPassword(for: computer), protection: computer.passwordProtection)
        try secrets.setSecret("ssh-secret", for: .sshPassword(for: computer, server: computer.tunnelServer), protection: computer.passwordProtection)
        let library = LibraryModel(repository: repository, secrets: secrets, discovery: SimulatedDiscoveryProvider(computers: []), clock: FixedClock(), owner: owner)
        return (library, secrets, computer)
    }

    @Test func protectedPasswordsStayLockedAndSavedUntilUnlockedTogether() async throws {
        let asked = Mutex(0)
        let owner = OwnerAuthentication(check: { .faceID }, makeAccess: {
            SecretAccess { _ in
                asked.withLock { $0 += 1 }
                return true
            }
        })
        let (library, secrets, computer) = try rig(owner)
        let editor = try #require(library.editor(for: computer.id))
        #expect(editor.isPasswordLocked && editor.password.isEmpty && editor.hasPassword && !editor.hasChanges)
        #expect(editor.isTunnelPasswordLocked && editor.tunnelPassword.isEmpty)
        editor.configuration.name = "Studio Mac"
        _ = try #require(await editor.save())
        let granted = SecretAccess { _ in true }
        #expect(try await secrets.unlockedSecret(for: .remoteDesktopPassword(for: computer), access: granted, reason: "") == "mac-secret")
        #expect(try await secrets.unlockedSecret(for: .sshPassword(for: computer, server: computer.tunnelServer), access: granted, reason: "") == "ssh-secret")
        #expect(asked.withLock { $0 } == 0, "saving without changing Password Security reads nothing")

        let again = try #require(library.editor(for: computer.id))
        #expect(await again.unlockPasswords())
        #expect(again.password == "mac-secret" && again.tunnelPassword == "ssh-secret")
        #expect(!again.isPasswordLocked && !again.isTunnelPasswordLocked && !again.hasChanges)
        #expect(asked.withLock { $0 } == 1, "one question for both passwords")
    }

    @Test func changingPasswordSecurityStoresThePasswordAgainAndTheMarksWithIt() async throws {
        let (library, secrets, computer) = try rig(.simulated)
        try secrets.setSecret("1", for: .provenIdentity(for: computer), protection: computer.passwordProtection.withoutUserPresence)
        let editor = try #require(library.editor(for: computer.id))
        editor.configuration.passwordProtection.requiresUserPresence = false
        #expect(editor.hasChanges)
        let saved = try #require(await editor.save())
        #expect(saved.passwordProtection == .standard)
        #expect(secrets.protection(for: .remoteDesktopPassword(for: computer)) == .standard)
        #expect(try secrets.secret(for: .remoteDesktopPassword(for: computer)) == "mac-secret")
        let tunnel = SecretKey.sshPassword(for: computer, server: computer.tunnelServer)
        #expect(secrets.protection(for: tunnel) == .standard)
        #expect(try secrets.secret(for: tunnel) == "ssh-secret")
        #expect(secrets.protection(for: .provenIdentity(for: computer)) == .standard)
    }

    @Test func passwordSecurityThatCannotUnlockThePasswordIsNotSaved() async throws {
        let declining = OwnerAuthentication(check: { .faceID }, makeAccess: { .denied })
        let (library, secrets, computer) = try rig(declining)
        let editor = try #require(library.editor(for: computer.id))
        editor.configuration.passwordProtection.requiresUserPresence = false
        #expect(await editor.save() == nil)
        #expect(editor.problem != nil)
        #expect(secrets.protection(for: .remoteDesktopPassword(for: computer))?.requiresUserPresence == true)
        // The SSH tunnel's password is kept the same way: while it stays locked, nothing changes.
        editor.password = "new-secret"
        #expect(await editor.save() == nil)
        // New passwords need no unlocking.
        editor.tunnelPassword = "new-ssh-secret"
        #expect(await editor.save() != nil)
        #expect(try secrets.secret(for: .remoteDesktopPassword(for: computer)) == "new-secret")
        #expect(try secrets.secret(for: .sshPassword(for: computer, server: computer.tunnelServer)) == "new-ssh-secret")
    }

    @Test func withoutAPasswordThereIsNothingToSecure() throws {
        let secrets = InMemorySecretStore()
        let repository = ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true))
        let library = LibraryModel(repository: repository, secrets: secrets, discovery: SimulatedDiscoveryProvider(computers: []), clock: FixedClock())
        let editor = library.editorForNewComputer()
        #expect(!editor.hasPassword)
        editor.password = "typed"
        #expect(editor.hasPassword)
        editor.password = ""
        editor.tunnelPassword = "typed"
        #expect(editor.hasPassword)
    }

    @Test func aKeyThatIsGoneIsNone() throws {
        let secrets = InMemorySecretStore()
        let keys = SSHKeyStore(secrets: secrets)
        try keys.generate(named: "Kept")
        let repository = ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true))
        var kept = ComputerConfiguration(name: "Kept", host: "kept.local")
        kept.tunnel.keyName = "Kept"
        var gone = ComputerConfiguration(name: "Gone", host: "gone.local")
        // Deleted, or a Secure Enclave key that did not come back with a restored backup.
        gone.tunnel.keyName = "Gone"
        repository.save(kept, now: Date())
        repository.save(gone, now: Date())
        let library = LibraryModel(repository: repository, secrets: secrets, discovery: SimulatedDiscoveryProvider(computers: []), clock: FixedClock())
        #expect(try #require(library.editor(for: kept.id)).configuration.tunnel.keyName == "Kept")
        let editor = try #require(library.editor(for: gone.id))
        #expect(editor.configuration.tunnel.keyName == nil)
        #expect(!editor.hasChanges, "nothing for the user to discard")
    }

    @Test func aKeyThatCannotBeReadIsKept() throws {
        /// A Keychain that fails to read SSH key descriptions.
        final class Failing: SecretStore {
            let base = InMemorySecretStore()
            func secret(for key: SecretKey, access: SecretAccess?) throws -> String? {
                if key.kind == .sshKeyInfo { throw SecretStoreError.storeFailure(code: -25308) }
                return try base.secret(for: key, access: access)
            }
            func setSecret(_ secret: String, for key: SecretKey, protection: SecretProtection) throws { try base.setSecret(secret, for: key, protection: protection) }
            func removeSecret(for key: SecretKey) throws { try base.removeSecret(for: key) }
            func names(of kind: SecretKey.Kind) throws -> [String] { try base.names(of: kind) }
        }
        let repository = ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true))
        var computer = ComputerConfiguration(name: "Studio", host: "studio-mac.local")
        computer.tunnel.keyName = "Work"
        repository.save(computer, now: Date())
        let library = LibraryModel(repository: repository, secrets: Failing(), discovery: SimulatedDiscoveryProvider(computers: []), clock: FixedClock())
        #expect(try #require(library.editor(for: computer.id)).configuration.tunnel.keyName == "Work")
    }

    @Test func choosingTheDefaultAgainIsNoChange() throws {
        let repository = ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true))
        let computer = ComputerConfiguration(name: "Studio", host: "studio-mac.local")
        repository.save(computer, now: Date())
        let library = LibraryModel(repository: repository, secrets: InMemorySecretStore(), discovery: SimulatedDiscoveryProvider(computers: []), clock: FixedClock())
        let editor = try #require(library.editor(for: computer.id))
        editor.configuration.passwordProtection.requiresUserPresence = true
        #expect(editor.hasChanges)
        editor.configuration.passwordProtection.requiresUserPresence = false
        #expect(!editor.hasChanges)
    }

    @Test func nothingIsRequiredOnADeviceWithoutAPasscode() async throws {
        let secrets = InMemorySecretStore()
        let repository = ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true))
        let noPasscode = OwnerAuthentication(check: { .unavailable }, makeAccess: { .denied })
        let library = LibraryModel(repository: repository, secrets: secrets, discovery: SimulatedDiscoveryProvider(computers: []), clock: FixedClock(), owner: noPasscode)
        let editor = library.editorForNewComputer()
        editor.address = "studio-mac.local"
        editor.password = "typed"
        editor.configuration.passwordProtection.requiresUserPresence = true
        let saved = try #require(await editor.save())
        #expect(!saved.passwordProtection.requiresUserPresence)
        #expect(try secrets.secret(for: .remoteDesktopPassword(for: saved)) == "typed")

        let form = SSHKeyFormModel(kind: .new, store: SSHKeyStore(secrets: secrets), ownerCheck: .unavailable)
        form.storage.protection.requiresUserPresence = true
        let key = try #require(await form.save())
        #expect(!key.storage.protection.requiresUserPresence)
    }

    @Test func aNewTunnelPasswordIsKeptAsThePasswordSecuritySays() async throws {
        let secrets = InMemorySecretStore()
        let repository = ComputerRepository(container: try ComputerRepository.makeContainer(inMemory: true))
        let library = LibraryModel(repository: repository, secrets: secrets, discovery: SimulatedDiscoveryProvider(computers: []), clock: FixedClock())
        let editor = library.editorForNewComputer()
        editor.address = "studio-mac.local"
        editor.configuration.tunnel.isEnabled = true
        editor.tunnelPassword = "ssh-secret"
        editor.configuration.passwordProtection.requiresUserPresence = true
        let saved = try #require(await editor.save())
        #expect(secrets.protection(for: .sshPassword(for: saved, server: saved.tunnelServer)) == saved.passwordProtection)
    }
}
