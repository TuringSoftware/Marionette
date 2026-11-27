// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import StoreKit
import SwiftUI
import TipKit
import MarionetteKit

/// What Marionette asks of its users, which is nothing, and the donation they can make anyway.
struct SupportSheet: View {
    let support: SupportPrompts
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsConfetti = false
    @State private var isRestoring = false
    /// Counts the purchases made in this sheet, for the haptic that goes with one.
    @State private var donationsMade = 0
    /// Kept after its alert is dismissed: the alert reads its title and message while it leaves.
    @State private var restoreFailure = RestoreFailure.nothingFound
    @State private var showsRestoreFailure = false

    /// Why a restore changed nothing, for the alert that says so.
    private enum RestoreFailure: Hashable {
        case nothingFound
        case error(String)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Marionette is free and open source software. We do not charge subscription fees, lock features behind payment, show ads or sell your data.")
                        // Not asked of someone who already has.
                        if !support.hasDonated {
                            Text("If you found this app useful, please consider making a donation to support its development.")
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("support-message")
                } header: {
                    AppIconImage()
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 12)
                }
                Section {
                    if support.hasDonated {
                        Label("Thank you for your support!", systemImage: "heart.fill")
                            .accessibilityIdentifier("support-thanks")
                    } else {
                        ProductView(id: Donations.productID)
                            .productViewStyle(.compact)
                            // The text above has said what it is for.
                            .productDescription(.hidden)
                            // StoreKit's own capsule is filled with the row's colour in dark mode.
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .accessibilityIdentifier("donation")
                    }
                } footer: {
                    if !support.hasDonated {
                        Button("Restore Purchase") { Task { await restore() } }
                            .font(.footnote)
                            .disabled(isRestoring)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 8)
                            .accessibilityIdentifier("restore-purchase")
                    }
                }
            }
            .navigationTitle("Support Us")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onInAppPurchaseCompletion { _, result in
                // A cancelled purchase and one waiting for a parent's approval are no donation yet.
                guard case .success(.success(let transaction)) = result, await Donations.finish(transaction) else { return }
                support.setDonated(true)
                donationsMade += 1
                // The button VoiceOver was on has gone, and the confetti says nothing.
                AccessibilityNotification.Announcement(String(localized: "Thank you for your support!")).post()
            }
        }
        .alert(
            restoreFailure == .nothingFound ? Text("No Donation Found") : Text("Couldn’t Restore the Purchase"),
            isPresented: $showsRestoreFailure
        ) {
            Button("OK") {}
        } message: {
            switch restoreFailure {
            case .nothingFound: Text("This Apple Account has not made a donation.")
            case .error(let reason): Text(reason)
            }
        }
        .sensoryFeedback(.success, trigger: donationsMade)
        .overlay {
            if showsConfetti {
                ConfettiView()
                    .ignoresSafeArea()
            }
        }
        // The App Store's word as the sheet opens: a donation made on another device, or before the
        // app was installed again, may have reached this one since the launch.
        .task { support.setDonated(await Donations.isMade()) }
        // As the donation is made, and every time the sheet is opened after that.
        .task(id: support.hasDonated) {
            guard support.hasDonated, !reduceMotion else { return }
            // Once the sheet has arrived, or the App Store's own sheet has left: about 0.5 s either way.
            try? await Task.sleep(for: .seconds(0.5))
            guard !Task.isCancelled else { return }
            showsConfetti = true
            try? await Task.sleep(for: .seconds(ConfettiView.duration))
            showsConfetti = false
        }
    }
}

extension SupportSheet {
    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        switch await Donations.restore() {
        case .found: support.setDonated(true)
        case .nothingFound: show(.nothingFound)
        case .cancelled: break
        case .failed(let reason): show(.error(reason))
        }
    }

    private func show(_ failure: RestoreFailure) {
        restoreFailure = failure
        showsRestoreFailure = true
    }
}

/// The app's icon as the Home Screen shows it, 96 pt across. Decorative.
///
/// A picture of the icon, because the icon itself cannot be loaded: `UIImage(named:)` raises an
/// exception for an Icon Composer icon. Made again, when the icon changes, with Icon Composer's
/// `ictool AppIcon.icon --export-image --platform iOS --rendition Default --width 96 --height 96`
/// at `--scale 2` and `--scale 3`.
private struct AppIconImage: View {
    var body: some View {
        Image(.appIconPicture)
            .accessibilityHidden(true)
    }
}

// MARK: - The prompt in the library

/// Asks for a donation once the app has been in use for a while (``SupportPrompts``). When it shows
/// is the model's decision alone: the tip has no rules and is never invalidated, so that it can
/// come back after "Not Now".
struct SupportTip: Tip {
    static let open = "open"
    static let notNow = "not-now"
    static let never = "never"

    var title: Text { Text("Enjoying Marionette?") }
    var message: Text? { Text("Marionette is free, with no ads. You can support the development with a small donation.") }
    var image: Image? { Image(systemName: "heart") }

    var actions: [Action] {
        Action(id: Self.open) { Text("Support Us") }
        Action(id: Self.notNow) { Text("Not Now") }
        Action(id: Self.never) { Text("Do Not Show Again") }
    }
}

/// A tip whose first action is a prominent button, and what a tap on the tip itself does; the
/// other actions follow as plain buttons. There is no close button: the system's one would
/// invalidate the tip for good, without the model knowing.
struct ProminentActionTipStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentActionTip(configuration: configuration)
    }
}

private struct ProminentActionTip: View {
    let configuration: TipViewStyleConfiguration
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 12) {
            if let primary = configuration.actions.first {
                Button(action: primary.handler) {
                    summary.contentShape(.rect)
                }
                .buttonStyle(.plain)
                // The button below says the same, by name.
                .accessibilityRemoveTraits(.isButton)
                Button(action: primary.handler) {
                    primary.label()
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.prominentFill)
                .controlSize(.large)
            }
            // At the two ends of the button above; under each other where they do not fit.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    ForEach(secondaryActions) { action in
                        if action.id != secondaryActions.first?.id { Spacer(minLength: 0) }
                        Button(action: action.handler) { action.label() }
                    }
                }
                VStack(spacing: 12) {
                    ForEach(secondaryActions) { action in
                        Button(action: action.handler) { action.label() }
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding()
    }

    private var secondaryActions: [Tips.Action] { Array(configuration.actions.dropFirst()) }

    /// The image beside the text; at the largest text sizes above it, so that the words have the
    /// whole width.
    @ViewBuilder
    private var summary: some View {
        let image = configuration.image?
            .font(.title)
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        let text = VStack(alignment: .leading, spacing: 4) {
            configuration.title?
                .font(.headline)
            configuration.message?
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                image
                text
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                image
                text
            }
        }
    }
}
