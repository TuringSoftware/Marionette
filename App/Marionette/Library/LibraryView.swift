// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import SwiftUI
import TipKit
import UIKit
import MarionetteKit

/// Home: the saved computers, and the Macs found on the network.
struct LibraryView: View {
    let environment: AppEnvironment

    @State private var editor: ComputerEditorModel?
    @State private var helpTopic: HelpTopic?
    @State private var pendingDeletion: LibraryModel.Item?
    @State private var showsSettings = false
    private let addComputerTip = AddComputerTip()
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var library: LibraryModel { environment.library }
    private var sessions: SessionStore { environment.sessions }

    var body: some View {
        @Bindable var sessions = sessions
        NavigationStack {
            content
                .navigationTitle("Computers")
                .toolbar { toolbar }
                // SwiftUI's popover tips do not show on bar buttons (iOS 26 and 27); UIKit's do.
                .background {
                    BarButtonTip(
                        tip: addComputerTip,
                        itemTitle: String(localized: "Add Computer"),
                        // Only while the library itself is in front: not over a session or a sheet.
                        isActive: sessions.presented == nil && editor == nil && helpTopic == nil && !showsSettings
                    )
                }
        }
        .sheet(item: $editor) { model in
            ComputerEditorView(model: model, sshKeys: environment.sshKeys) { _ in
                editor = nil
            } onDelete: {
                editor = nil
                library.delete(model.configuration.id)
            }
        }
        .sheet(item: $helpTopic) { topic in
            HelpSheet(topic: topic)
        }
        .sheet(isPresented: $showsSettings) {
            SettingsView(environment: environment)
        }
        .fullScreenCover(item: $sessions.presented) { session in
            SessionScreen(session: session)
                .environment(\.launchOptions, environment.options)
        }
        .onChange(of: sessions.presented == nil) { _, dismissed in
            guard dismissed else { return }
            library.reload()
            if let id = sessions.editRequest {
                sessions.editRequest = nil
                editor = library.editor(for: id)
            }
        }
        // After the first computer the tip on + has done its job, even if all are deleted later.
        .onChange(of: library.isEmpty, initial: true) { _, isEmpty in
            if !isEmpty { AddComputerTip.hasHadComputer = true }
        }
        .task { library.startDiscovery() }
        // Restarts a search the system stopped while in the background or behind a session.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { library.resumeDiscovery() }
        }
        .onChange(of: sessions.presented == nil, initial: true) { _, showsLibrary in
            if showsLibrary { library.resumeDiscovery() }
            CommandTargets.shared.library = showsLibrary ? LibraryActions(
                newComputer: {
                    addComputerTip.invalidate(reason: .actionPerformed)
                    BarButtonTipPresenter.dismissShown { editor = library.editorForNewComputer() }
                },
                lookAgain: { Task { await library.refreshDiscovery() } },
                showSettings: { BarButtonTipPresenter.dismissShown { showsSettings = true } },
                showHelp: { BarButtonTipPresenter.dismissShown { helpTopic = .enableScreenSharing } }
            ) : nil
        }
    }

    // MARK: Pieces

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !library.isEmpty {
                    cardGrid {
                        ForEach(library.items) { item in
                            Button { connect(item.configuration) } label: {
                                ComputerCard(item: item, now: library.now)
                            }
                            .buttonStyle(.plain)
                            .contextMenu { contextMenu(for: item) }
                            // On the card, so that where it shows as a popover (iPad, an open Duo)
                            // it points at the computer being deleted.
                            .confirmationDialog(
                                "Delete “\(item.configuration.displayName)”?",
                                isPresented: Binding(
                                    get: { pendingDeletion?.id == item.id },
                                    set: { if !$0, pendingDeletion?.id == item.id { pendingDeletion = nil } }
                                ),
                                titleVisibility: .visible
                            ) {
                                Button("Delete Computer", role: .destructive) { library.delete(item.id) }
                            }
                            .accessibilityIdentifier("computer-\(item.configuration.displayName)")
                        }
                    }
                }
                switch library.discoveryState {
                case .denied:
                    if library.isEmpty { emptyState }
                    localNetworkDenied
                case .searching where !library.discovered.isEmpty:
                    discoveryHeader
                    cardGrid {
                        ForEach(library.discovered) { computer in
                            Button { connect(library.unsavedConfiguration(for: computer)) } label: {
                                DiscoveredCard(computer: computer)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Connect", systemImage: "play") { connect(library.unsavedConfiguration(for: computer)) }
                                Button("Add…", systemImage: "plus") { BarButtonTipPresenter.dismissShown { editor = library.editor(for: computer) } }
                            }
                            .accessibilityHint("Connects to this computer")
                            .accessibilityIdentifier("discovered-\(computer.name)")
                        }
                    }
                default:
                    if library.isEmpty { emptyState }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .refreshable { await library.refreshDiscovery() }
    }

    /// Two columns on a phone; larger cards where there is room for them. At the largest text sizes
    /// a name needs the width: one column on a phone, wider cards elsewhere.
    private func cardGrid(@ViewBuilder content: () -> some View) -> some View {
        let large = dynamicTypeSize.isAccessibilitySize
        let regular = horizontalSizeClass == .regular
        let columns = large && !regular
            ? [GridItem(.flexible(), spacing: 16, alignment: .top)]
            : [GridItem(.adaptive(minimum: regular ? (large ? 320 : 220) : 158, maximum: large ? 480 : 360), spacing: 16, alignment: .top)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
            content()
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Computers", systemImage: "desktopcomputer")
        } description: {
            Text("No Macs discovered on the network. To add one manually, tap +.")
        } actions: {
            Button("How to Turn On Screen Sharing") { BarButtonTipPresenter.dismissShown { helpTopic = .enableScreenSharing } }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    /// Across the whole width, not in a card's cell: it is about the list, not one computer.
    private var localNetworkDenied: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local Network Access Is Off", systemImage: "network.slash")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            Text("Marionette needs it to find computers near you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.fill.quaternary, in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("local-network-denied")
    }

    private var discoveryHeader: some View {
        Text("On This Network")
            .font(.title3.bold())
            .padding(.top, library.isEmpty ? 0 : 8)
            .accessibilityAddTraits(.isHeader)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("Add Computer", systemImage: "plus") {
                addComputerTip.invalidate(reason: .actionPerformed)
                // The tip is a presented popover; the editor can only be presented once it is gone.
                BarButtonTipPresenter.dismissShown { editor = library.editorForNewComputer() }
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Button("How to Turn On Screen Sharing", systemImage: "questionmark.circle") { BarButtonTipPresenter.dismissShown { helpTopic = .enableScreenSharing } }
        }
        ToolbarItem(placement: .secondaryAction) {
            Button("Settings", systemImage: "gear") { BarButtonTipPresenter.dismissShown { showsSettings = true } }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: LibraryModel.Item) -> some View {
        Button("Connect", systemImage: "play") { connect(item.configuration) }
        Button("Edit", systemImage: "pencil") { BarButtonTipPresenter.dismissShown { editor = library.editor(for: item.id) } }
        Button("Duplicate", systemImage: "plus.square.on.square") { library.duplicate(item.id) }
        Divider()
        Button("Delete", systemImage: "trash", role: .destructive) { BarButtonTipPresenter.dismissShown { pendingDeletion = item } }
    }

    private func connect(_ configuration: ComputerConfiguration) {
        BarButtonTipPresenter.dismissShown {
            sessions.open(configuration)
            library.activeComputerIDs = sessions.activeComputerIDs
        }
    }
}

extension HelpTopic: @retroactive Identifiable {
    public var id: String { rawValue }
}

/// Points at + while there has never been a computer: the Macs nearby show up by themselves, but one
/// elsewhere has to be added by its address.
struct AddComputerTip: Tip {
    /// Set once any computer has been saved; the tip never comes back after that.
    @Parameter static var hasHadComputer: Bool = false

    var title: Text { Text("Add a Computer") }
    var message: Text? { Text("Tap + to add a new remote connection.") }
    var image: Image? { Image(systemName: "plus.circle") }

    var rules: [Rule] {
        #Rule(Self.$hasHadComputer) { $0 == false }
    }
}

/// Shows a tip as a popover from the bar button with the given title, in the navigation bar of the
/// view this sits behind.
private struct BarButtonTip<T: Tip>: UIViewControllerRepresentable {
    let tip: T
    let itemTitle: String
    /// Whether the screen the bar belongs to is the one in front.
    var isActive = true

    func makeUIViewController(context: Context) -> BarButtonTipPresenter {
        BarButtonTipPresenter(tip: tip, itemTitle: itemTitle)
    }

    func updateUIViewController(_ controller: BarButtonTipPresenter, context: Context) {
        controller.isActive = isActive
    }
}

/// Presents a tip from a bar button; see ``BarButtonTip``.
///
/// UIKit ignores a present or dismiss requested mid-transition (a dismissal while the popover is
/// still arriving leaves it on screen for good). So nothing presents or dismisses directly: the
/// presenter tracks what is wanted (`wantsShown`, and what others are waiting to present) and moves
/// one step towards it whenever a transition ends.
final class BarButtonTipPresenter: UIViewController {
    private enum Stage {
        case hidden
        case presenting
        case shown
        case dismissing
    }

    /// The presenter on screen. One at a time.
    private static weak var current: BarButtonTipPresenter?
    /// What is waiting for the tip to be out of the way before it presents something itself.
    private static var waiting: [() -> Void] = []

    /// Runs `action` once no tip is on screen: at once when there is none, after its dismissal
    /// otherwise. Presenting anything while a popover is on screen, or still going away, fails
    /// silently, so everything that presents goes through here.
    static func dismissShown(then action: @escaping () -> Void) {
        guard let presenter = current, presenter.stage != .hidden else {
            action()
            return
        }
        waiting.append(action)
        presenter.reconcile()
    }

    private let tip: any Tip
    private let shouldDisplayUpdates: AsyncStream<Bool>
    private let itemTitle: String
    private var watcher: Task<Void, Never>?
    private var stage = Stage.hidden
    /// The tip's own rules say it should show.
    private var isEligible = false
    /// The screen the bar belongs to is in front. Otherwise the tip, still eligible while a session
    /// covers the library, would present from behind it and swallow every touch.
    var isActive = true {
        didSet { if isActive != oldValue { reconcile() } }
    }
    private var wantsShown: Bool { isEligible && isActive }
    private var popover: UIViewController?

    init(tip: some Tip, itemTitle: String) {
        self.tip = tip
        self.itemTitle = itemTitle
        shouldDisplayUpdates = AsyncStream { continuation in
            let task = Task {
                for await value in tip.shouldDisplayUpdates { continuation.yield(value) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Self.current = self
        watcher?.cancel()
        let updates = shouldDisplayUpdates
        watcher = Task { [weak self] in
            for await shouldDisplay in updates {
                // What the tip depends on is often still settling when the screen appears (a
                // computer just saved, say); show it only if it is still wanted a moment later.
                if shouldDisplay { try? await Task.sleep(for: .milliseconds(400)) }
                guard let self, !Task.isCancelled else { return }
                self.isEligible = shouldDisplay && self.tip.shouldDisplay
                self.reconcile()
            }
        }
        reconcile()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        watcher?.cancel()
        watcher = nil
        isEligible = false
        reconcile()
    }

    /// One step towards what is wanted. Called whenever that changes and whenever a transition ends.
    private func reconcile() {
        switch stage {
        case .hidden:
            if !Self.waiting.isEmpty {
                let actions = Self.waiting
                Self.waiting = []
                for action in actions { action() }
            } else if wantsShown {
                present()
            }
        case .shown:
            if !wantsShown || !Self.waiting.isEmpty { dismissTip() }
        case .presenting, .dismissing:
            break
        }
    }

    private func present() {
        guard let window = view.window, let host = hostController, host.presentedViewController == nil,
              window.rootViewController?.presentedViewController == nil,
              let item = barItem(in: host) else { return }
        let popover = TipUIPopoverViewController(tip, sourceItem: item) { _ in }
        // Everything behind the tip stays usable, + especially. The bar's own view is not enough:
        // on the outer display of an iPhone Duo the bar's buttons stand in a strip at the side,
        // outside it. Whatever is tapped closes the tip before presenting (`dismissShown`).
        if let behind = host.navigationController?.view ?? host.view {
            popover.popoverPresentationController?.passthroughViews = [behind]
        }
        self.popover = popover
        stage = .presenting
        host.present(popover, animated: true) { [weak self] in
            self?.stage = .shown
            self?.reconcile()
        }
    }

    private func dismissTip() {
        guard let popover, popover.presentingViewController != nil else {
            // Already gone (the system took it away).
            self.popover = nil
            stage = .hidden
            reconcile()
            return
        }
        stage = .dismissing
        popover.dismiss(animated: true) { [weak self] in
            self?.popover = nil
            self?.stage = .hidden
            self?.reconcile()
        }
    }

    /// The controller whose navigation item SwiftUI filled from the toolbar.
    private var hostController: UIViewController? {
        var candidate: UIViewController? = parent
        while let controller = candidate {
            if controller.navigationController != nil { return controller.navigationController?.topViewController }
            candidate = controller.parent
        }
        return nil
    }

    private func barItem(in host: UIViewController) -> UIBarButtonItem? {
        let navigationItem = host.navigationItem
        let items = (navigationItem.rightBarButtonItems ?? [])
            + navigationItem.trailingItemGroups.flatMap(\.barButtonItems)
        return items.first { $0.title == itemTitle || $0.accessibilityLabel == itemTitle }
    }
}
