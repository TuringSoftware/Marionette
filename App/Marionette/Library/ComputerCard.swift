// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import RemoteDesktopCore
import SwiftUI
import MarionetteKit

/// One saved computer in the library grid: the last frame seen and its name.
struct ComputerCard: View {
    let item: LibraryModel.Item
    let now: Date
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme

    private var configuration: ComputerConfiguration { item.configuration }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Thumbnail(data: item.record.thumbnail)
                .overlay(alignment: .topTrailing) {
                    if item.isOnline {
                        Circle()
                            // The system's green is too pale against a light surround.
                            .fill(colorScheme == .dark ? Color.green : Color(red: 0.141, green: 0.541, blue: 0.239))
                            .stroke(.background, lineWidth: 2)
                            .frame(width: 12, height: 12)
                            .padding(8)
                            .accessibilityHidden(true)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.displayName)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(configuration.displayName)
        .accessibilityValue(([subtitle] + (item.isOnline ? [String(localized: "On this network")] : [])).joined(separator: ", "))
        .accessibilityHint("Connects to this computer")
        .accessibilityAddTraits(.isButton)
    }

    private var subtitle: String {
        if let date = item.record.lastConnected {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return String(localized: "Connected \(formatter.localizedString(for: date, relativeTo: now))")
        }
        return configuration.name.isEmpty ? String(localized: "Never connected") : configuration.host
    }
}

/// A machine found on the network that is not saved yet.
struct DiscoveredCard: View {
    let computer: DiscoveredComputer
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Thumbnail(data: nil)
            VStack(alignment: .leading, spacing: 2) {
                Text(computer.name)
                    .font(.headline)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(computer.host)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// The last frame of a computer's screen, or a placeholder in the same shape.
private struct Thumbnail: View {
    let data: Data?
    var symbolName = "desktopcomputer"

    var body: some View {
        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if let data, let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.fill.tertiary)
                        Image(systemName: symbolName)
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipShape(.rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}
