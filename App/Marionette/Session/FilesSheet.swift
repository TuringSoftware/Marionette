// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import SwiftUI
import UniformTypeIdentifiers
import MarionetteKit

/// Files on the remote computer: browse, fetch, send, and watch transfers.
///
/// File access comes with the session when the back end has it, rides on the SSH tunnel when there
/// is one, and otherwise needs a separate SSH sign-in, which this sheet offers.
struct FilesSheet: View {
    let session: SessionModel
    @State private var showsImporter = false
    @State private var importProblem: String?
    @State private var showsDragHelp = false

    private var files: FileAccessModel { session.files }

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { session.setFilesPresented(false) }
                    }
                }
        }
        // Sign-in questions (host key, password) have to appear over this sheet, not under it.
        .sheet(item: Binding(get: { session.prompts.pending }, set: { if $0 == nil { session.prompts.cancelPending() } })) { pending in
            PromptSheet(pending: pending, broker: session.prompts, computerName: session.title)
        }
        .sheet(isPresented: $showsDragHelp) {
            HelpSheet(topic: .draggingFiles)
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { send(urls) }
        }
        .alert("Couldn’t Send File", item: $importProblem) { _ in
            Button("OK", role: .cancel) {}
        } message: { problem in
            Text(problem)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch files.state {
        case .ready:
            if let browser = session.fileBrowser {
                FileBrowser(session: session, browser: browser, onSend: { showsImporter = true }, onDrop: send, onHelp: { showsDragHelp = true })
            } else if !files.canBrowse {
                SendOnlyFiles(session: session, onSend: { showsImporter = true }, onDrop: send, onHelp: { showsDragHelp = true })
            } else {
                ProgressView()
            }
        case .connecting:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Signing in over SSH…").foregroundStyle(.secondary)
            }
            .navigationTitle("Files")
        case .signedOut:
            ScrollIfNeeded {
                ContentUnavailableView {
                    Label("Sign In to Use Files", systemImage: "folder.badge.person.crop")
                } description: {
                    Text("Remote Login must be turned on at “\(session.title)”.")
                } actions: {
                    Button("Sign In over SSH") { files.signIn() }
                        .buttonStyle(.borderedProminent).tint(.prominentFill)
                        .disabled(!files.canSignIn)
                }
            }
            .navigationTitle("Files")
        case .failed(let message):
            ScrollIfNeeded {
                ContentUnavailableView {
                    Label("Couldn’t Reach Files", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try Again") { files.signIn() }
                        .buttonStyle(.borderedProminent).tint(.prominentFill)
                        .disabled(!files.canSignIn)
                }
            }
            .navigationTitle("Files")
        case .unavailable(let message):
            ScrollIfNeeded {
                ContentUnavailableView("Files Aren’t Available", systemImage: "folder.badge.questionmark", description: Text(message))
            }
            .navigationTitle("Files")
        }
    }

    /// Queues local files for sending to the folder being shown. Picked and dropped files are only
    /// readable for a moment, so each is copied aside first; the copy goes when it has been sent.
    private func send(_ urls: [URL]) {
        let directory = session.fileBrowser?.path
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                session.transfers.upload(try StagedUpload(copying: url), toDirectory: directory)
            } catch {
                importProblem = String(localized: "“\(url.lastPathComponent)” couldn’t be read.")
            }
        }
    }
}

/// Files through Screen Sharing itself: sending works, to the Mac's Downloads folder, but the Mac's
/// folders cannot be listed. Browsing needs Remote Login, which is offered here.
private struct SendOnlyFiles: View {
    let session: SessionModel
    var onSend: () -> Void
    var onDrop: ([URL]) -> Void
    var onHelp: () -> Void

    private var files: FileAccessModel { session.files }

    var body: some View {
        List {
            TransferSection(session: session)
            Section {
                Button("Send Files…", systemImage: "square.and.arrow.up", action: onSend)
                    .accessibilityIdentifier("files-send")
            } footer: {
                Text("Files go to the Downloads folder on “\(session.title)”.")
            }
            // Without SSH there is nothing to offer here, and an empty section would look broken.
            if files.isSigningIn || files.canSignIn || files.signInFailure != nil {
                Section {
                    if files.isSigningIn {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Signing in over SSH…").foregroundStyle(.secondary)
                        }
                    } else if files.canSignIn {
                        Button("Sign In over SSH", systemImage: "folder.badge.person.crop") { files.signIn() }
                    }
                    if let failure = files.signInFailure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Browse the Mac’s Files")
                } footer: {
                    Text("Remote Login must be turned on at “\(session.title)”.")
                }
            }
            DragHelpSection(session: session, onHelp: onHelp)
        }
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return !urls.isEmpty
        }
        .navigationTitle("Files")
    }
}

/// Help on dragging files onto and off the remote display, where supported: it needs no sheet and
/// is easy to miss.
private struct DragHelpSection: View {
    let session: SessionModel
    var onHelp: () -> Void

    var body: some View {
        if session.features.fileDrag.isAvailable {
            Section {
                Button("About Dragging Files", systemImage: "questionmark.circle", action: onHelp)
                    .accessibilityIdentifier("files-drag-help")
            }
        }
    }
}

private struct TransferSection: View {
    let session: SessionModel
    @State private var deleteFailure: String?

    // Reads the transfers itself so the enclosing list is not redrawn at every progress step.
    var body: some View {
        if !session.transfers.items.isEmpty {
            section
        }
    }

    private var section: some View {
        Section {
            ForEach(session.transfers.items) { item in
                TransferRow(item: item) {
                    session.transfers.cancel(item.id)
                } onDelete: {
                    do {
                        try session.transfers.deleteReceivedFile(item.id)
                    } catch {
                        deleteFailure = error.localizedDescription
                    }
                }
            }
        } header: {
            HStack {
                Text("Transfers")
                Spacer()
                if session.transfers.items.contains(where: { !$0.isActive }) {
                    Button("Clear") { session.transfers.clearCompleted() }
                        .font(.footnote)
                }
            }
        }
        .alert("Couldn’t Delete File", item: $deleteFailure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure)
        }
    }
}

private struct FileBrowser: View {
    let session: SessionModel
    let browser: RemoteFileBrowserModel
    var onSend: () -> Void
    var onDrop: ([URL]) -> Void
    var onHelp: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            TransferSection(session: session)
            Section {
                if let message = browser.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if browser.entries.isEmpty, !browser.isLoading {
                    Text("This folder is empty.")
                        .foregroundStyle(.secondary)
                }
                ForEach(browser.entries) { entry in
                    Button {
                        if entry.isDirectory {
                            browser.open(entry)
                        } else {
                            session.transfers.download(entry)
                        }
                    } label: {
                        EntryRow(entry: entry)
                    }
                    .accessibilityValue(entry.isDirectory ? "Folder" : "")
                    .accessibilityHint(entry.isDirectory ? "Opens this folder" : "Downloads this file")
                    .accessibilityIdentifier("file-\(entry.name)")
                }
            } header: {
                Text(browser.path)
                    .textCase(nil)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.head)
            }
            DragHelpSection(session: session, onHelp: onHelp)
        }
        .overlay {
            if browser.isLoading, browser.entries.isEmpty { ProgressView() }
        }
        .refreshable { browser.reload() }
        .dropDestination(for: URL.self) { urls, _ in
            onDrop(urls)
            return !urls.isEmpty
        }
        .navigationTitle(browser.breadcrumbs.last?.name ?? String(localized: "Files"))
        .toolbarTitleMenu {
            ForEach(browser.breadcrumbs.reversed()) { crumb in
                Button(crumb.name, systemImage: "folder") { browser.go(to: crumb.path) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Enclosing Folder", systemImage: "chevron.up") { browser.goUp() }
                    .disabled(!browser.canGoUp)
                    .accessibilityIdentifier("files-up")
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Send File", systemImage: "square.and.arrow.up", action: onSend)
                    .labelStyle(.titleAndIcon)
                    .accessibilityIdentifier("files-send")
                Spacer()
                if session.files.isSignedIn {
                    Button("Sign Out") { session.files.signOut() }
                }
            }
        }
    }
}

private struct EntryRow: View {
    let entry: RemoteFileEntry
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .foregroundStyle(Color.primary)
                        .lineLimit(stacked ? nil : 2)
                    if stacked, !entry.isDirectory, let size = entry.size { sizeText(Int64(size)) }
                }
            } icon: {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
            }
            Spacer()
            if entry.isDirectory {
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            } else {
                if !stacked, let size = entry.size { sizeText(Int64(size)) }
                Image(systemName: "arrow.down.circle")
                    .accessibilityHidden(true)
            }
        }
    }

    private func sizeText(_ size: Int64) -> some View {
        Text(size, format: .byteCount(style: .file))
            .font(.footnote)
            .foregroundStyle(Color.secondary)
    }
}

private struct TransferRow: View {
    let item: TransferQueue.Item
    var onCancel: () -> Void
    var onDelete: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if item.direction == .download, item.state == .finished, let url = item.localURL {
            // iPad: a received file can be dragged to another app. Offered as file contents, since
            // other apps take a URL for a link.
            row
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .contextMenu {
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                        .accessibilityIdentifier("delete-received-file")
                }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            Image(systemName: item.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(item.direction == .upload ? "Upload" : "Download")
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                switch item.state {
                case .waiting:
                    Text("Waiting…").font(.footnote).foregroundStyle(.secondary)
                case .running:
                    ProgressView(value: item.progress?.fraction)
                        .accessibilityLabel("Progress")
                case .finished:
                    Text(item.direction == .upload ? "Sent" : "Saved to Files")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text(message).font(.footnote).foregroundStyle(Color.errorText)
                case .cancelled:
                    Text("Cancelled").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if item.isActive {
                Button("Cancel Transfer", systemImage: "xmark.circle.fill", action: onCancel)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            } else if item.state == .finished, let url = item.localURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Share")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transfer-\(item.name)")
    }
}
