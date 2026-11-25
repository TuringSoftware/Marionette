// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import SwiftUI
import MarionetteKit

/// Shown while a connection attempt runs: which computer, how far along, and a way out.
struct ConnectingView: View {
    let session: SessionModel
    let step: ConnectionPhase?

    /// Steps a direct connection goes through; a tunnel adds one in front.
    private var totalSteps: Double { session.computer.tunnel.isEnabled ? 7 : 6 }

    private var completedSteps: Double {
        guard session.connectionProgress >= 0 else { return 0.3 }
        return Double(session.connectionProgress) + (session.computer.tunnel.isEnabled ? 1 : 0) - 0.5
    }

    var body: some View {
        ScrollIfNeeded {
            steps
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connecting")
    }

    private var steps: some View {
        VStack(spacing: 20) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(spacing: 6) {
                Text("Connecting to “\(session.title)”")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                // Spoken as the progress bar's value.
                Text(step?.title ?? String(localized: "Connecting…"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .accessibilityHidden(true)
            }
            ProgressView(value: min(max(completedSteps, 0.3), totalSteps), total: totalSteps)
                .frame(maxWidth: 240)
                .accessibilityLabel("Connection Progress")
                .accessibilityValue(step?.title ?? String(localized: "Connecting"))
            if session.computer.tunnel.isEnabled {
                Label("SSH Tunnel", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

/// A failed connection attempt, with the ways forward that the failure itself suggests.
struct FailureView: View {
    let session: SessionModel
    let failure: ConnectionFailure
    @State private var helpTopic: HelpTopic?
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollIfNeeded {
            message
        }
        .sheet(item: $helpTopic) { HelpSheet(topic: $0) }
        .accessibilityIdentifier("connection-failure")
    }

    private var message: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: failure.symbolName)
        } description: {
            Text(failure.message)
        } actions: {
            let actions = failure.recoveryActions
            ActionButtons {
                ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                    if index == 0 {
                        button(for: action).buttonStyle(.borderedProminent).tint(.prominentFill)
                    } else if case .showHelp = action {
                        button(for: action)
                    } else {
                        button(for: action).buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func button(for action: RecoveryAction) -> some View {
        Button(action.title) {
            switch action {
            case .showHelp(let topic):
                helpTopic = topic
            case .openSystemSettings:
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            default:
                session.perform(action)
            }
        }
    }
}
