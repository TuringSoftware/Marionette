// Copyright © 2026 Turing Software, LLC
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import MarionetteKit

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
