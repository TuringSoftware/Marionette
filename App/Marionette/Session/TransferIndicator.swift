// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MarionetteKit

/// File transfer progress on the control strip: a ring that fills as transfers go, and how many are
/// left when there are several.
///
/// Files dropped on or dragged from the remote display move without the Files sheet open, so this
/// is where progress shows. It stays briefly after the last transfer to show the outcome; a tap
/// opens Files.
struct TransferIndicator: View {
    let activity: TransferQueue.Activity
    /// Stacked, for the strip standing up as a column.
    var vertical = false
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var symbol: String {
        switch activity.phase {
        case .finished: "checkmark"
        case .failed: "exclamationmark"
        case .active:
            switch activity.direction {
            case .upload: "arrow.up"
            case .download: "arrow.down"
            case nil: "arrow.up.arrow.down"
            }
        }
    }

    private var remaining: Int? {
        if case .active(let remaining) = activity.phase, remaining > 1 { remaining } else { nil }
    }

    private var isFailure: Bool {
        if case .failed = activity.phase { true } else { false }
    }

    private var summary: String {
        switch activity.phase {
        case .active(let remaining):
            let percent = activity.fraction.formatted(.percent.precision(.fractionLength(0)))
            return remaining == 1 ? String(localized: "1 transfer, \(percent) done") : String(localized: "\(remaining) transfers, \(percent) done")
        case .finished(let count):
            return count == 1 ? String(localized: "Transfer finished") : String(localized: "\(count) transfers finished")
        case .failed(let count):
            return count == 1 ? String(localized: "1 transfer failed") : String(localized: "\(count) transfers failed")
        }
    }

    var body: some View {
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 5))
        Button(action: action) {
            layout {
                ZStack {
                    Circle()
                        .stroke(.primary.opacity(0.25), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: activity.fraction)
                        .stroke(isFailure ? AnyShapeStyle(.yellow) : AnyShapeStyle(.primary), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(reduceMotion ? nil : .linear(duration: 0.2), value: activity.fraction)
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isFailure ? AnyShapeStyle(.yellow) : AnyShapeStyle(.primary))
                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                }
                .frame(width: 26, height: 26)
                if let remaining {
                    Text(remaining, format: .number)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
            .padding(vertical ? .vertical : .horizontal, 9)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        // A piece of a bar: it cannot grow with the text, so it is shown large while held instead.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer { Label(summary, systemImage: symbol) }
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("File Transfers")
        .accessibilityValue(summary)
        .accessibilityHint("Opens Files")
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("transfer-indicator")
        // Announced, because the indicator goes away by itself soon after.
        .onChange(of: activity.phase) { _, phase in
            if case .active = phase { return }
            AccessibilityNotification.Announcement(summary).post()
        }
    }
}
