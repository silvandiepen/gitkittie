import GitKanbanKit
import SwiftUI

/// The folder servers announced on the local network, each one tap away. Typing an address
/// stays available below them, folded away, for servers that can't be seen from here.
struct FolderServerPicker: View {
    @Environment(AppModel.self) private var model
    var onAdded: (AddedRepo) -> Void = { _ in }
    @State private var browser = FolderServerBrowser()
    @State private var connecting: String?
    @State private var showAddress = false

    var body: some View {
        Group {
            ForEach(browser.servers) { server in
                Button { connect(server) } label: { row(for: server) }
                    .disabled(connecting != nil || server.url == nil)
                    .accessibilityIdentifier("discoveredServer")
            }
            if browser.servers.isEmpty {
                HStack(spacing: 10) {
                    if browser.problem == nil { ProgressView() }
                    Text(browser.problem ?? "Looking for servers on this network…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Enter an address", isExpanded: $showAddress) {
                AddFolderServerRow(onAdded: onAdded)
            }
            .accessibilityIdentifier("enterServerAddress")
        }
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
    }

    private func row(for server: DiscoveredServer) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(server.url == nil ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).foregroundStyle(.primary)
                Text(subtitle(for: server)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if connecting == server.id {
                ProgressView()
            } else if model.addedServer(for: server) != nil {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("Added")
            }
        }
    }

    private func subtitle(for server: DiscoveredServer) -> String {
        guard let url = server.url else { return "No address yet. Turn on Tailscale on that Mac." }
        return URL(string: url)?.host ?? url
    }

    private func connect(_ server: DiscoveredServer) {
        guard connecting == nil else { return }
        connecting = server.id
        Task {
            defer { connecting = nil }
            if let added = await model.addDiscoveredServer(server) { onAdded(added) }
        }
    }
}
