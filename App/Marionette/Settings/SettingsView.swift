// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UIKit
import MarionetteKit

/// App-wide settings: input, what Marionette keeps for SSH, and the licences of what it is built from.
struct SettingsView: View {
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var preferences = SessionPreferences()

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "\(short) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Default Input", selection: $preferences.defaultInputPanel) {
                        ForEach(InputPanel.shown, id: \.self) { panel in
                            Text(panel.title).tag(panel)
                        }
                    }
                    .accessibilityIdentifier("default-input-panel")
                    Toggle("Natural Scrolling", isOn: $preferences.naturalScrolling)
                        .accessibilityIdentifier("natural-scrolling")
                    VStack(alignment: .leading) {
                        // The slider says its own name; this one is for the eye.
                        Text("Trackpad Speed").accessibilityHidden(true)
                        Slider(value: $preferences.pointerSpeed, in: SessionPreferences.pointerSpeedRange, step: 0.25) {
                            Text("Trackpad Speed")
                        } minimumValueLabel: {
                            Image(systemName: "tortoise").accessibilityLabel("Slow")
                        } maximumValueLabel: {
                            Image(systemName: "hare").accessibilityLabel("Fast")
                        }
                        .accessibilityValue(preferences.pointerSpeed.formatted(.percent))
                    }
                    Picker("Secondary Display Position", selection: $preferences.secondaryDisplayEdge) {
                        ForEach(DisplayEdge.allCases, id: \.self) { edge in
                            Text(edge.title).tag(edge)
                        }
                    }
                    .accessibilityIdentifier("secondary-display-edge")
                } header: {
                    Text("Input")
                }
                Section {
                    Picker("Clipboard Sharing", selection: $preferences.clipboardMode) {
                        ForEach(ClipboardMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .accessibilityIdentifier("clipboard-mode")
                } header: {
                    Text("Clipboard Sharing")
                }
                Section {
                    NavigationLink {
                        SSHKeysView(store: environment.sshKeys)
                    } label: {
                        Label("SSH Keys", systemImage: "key")
                    }
                    NavigationLink {
                        KnownHostsView(store: environment.hostKeys)
                    } label: {
                        Label("Known Hosts", systemImage: "checkmark.shield")
                    }
                } header: {
                    Text("SSH")
                }
                Section("About") {
                    LabeledContent("Version", value: version)
                    NavigationLink {
                        LicencesView()
                    } label: {
                        Label("Licences", systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { preferences = SessionPreferences(defaults: environment.defaults) }
            .onChange(of: preferences) { _, new in
                // Only the input settings are this screen's; the rest is written by sessions.
                var stored = SessionPreferences(defaults: environment.defaults)
                stored.defaultInputPanel = new.defaultInputPanel
                stored.naturalScrolling = new.naturalScrolling
                stored.pointerSpeed = new.pointerSpeed
                stored.secondaryDisplayEdge = new.secondaryDisplayEdge
                stored.clipboardMode = new.clipboardMode
                stored.save(to: environment.defaults)
            }
        }
    }
}

/// The SSH servers whose host keys have been accepted and remembered.
struct KnownHostsView: View {
    let store: any KnownHostsStore
    @State private var hosts: [KnownHost] = []
    @State private var isLoaded = false

    var body: some View {
        List {
            ForEach(hosts) { host in
                VStack(alignment: .leading, spacing: 4) {
                    let name = Text(host.port == 22 ? host.host : "\(host.host):\(host.port)").font(.headline)
                    let algorithm = Text(host.key.algorithm).font(.footnote).foregroundStyle(.secondary)
                    ViewThatFits(in: .horizontal) {
                        HStack { name; Spacer(); algorithm }
                        VStack(alignment: .leading, spacing: 2) { name; algorithm }
                    }
                    Text(host.key.fingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Accepted \(host.added.formatted(date: .abbreviated, time: .shortened))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .accessibilityElement(children: .combine)
            }
            .onDelete { offsets in
                let removed = offsets.map { hosts[$0] }
                hosts.remove(atOffsets: offsets)
                Task {
                    for host in removed { await store.remove(host: host.host, port: host.port) }
                }
            }
        }
        .overlay {
            if isLoaded, hosts.isEmpty {
                ContentUnavailableView(
                    "No Known Hosts",
                    systemImage: "checkmark.shield",
                    description: Text("SSH servers you choose to remember appear here.")
                )
            }
        }
        .navigationTitle("Known Hosts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !hosts.isEmpty { EditButton() }
        }
        .task {
            hosts = await store.all().sorted { $0.host.localizedStandardCompare($1.host) == .orderedAscending }
            isLoaded = true
        }
    }
}

/// The notices of the third-party work Marionette includes, as shipped in the app bundle.
struct LicencesView: View {
    private var notice: String {
        guard let url = Bundle.main.url(forResource: "NOTICE", withExtension: nil), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Marionette is free software under the GNU General Public License, version 3 or later. It comes with no warranty.")
                Text(notice)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle("Licences")
        .navigationBarTitleDisplayMode(.inline)
    }
}
