import GitKanbanKit
import SwiftUI

/// Turn live updates on or off for the open repo. With them on, a push to the repo
/// reaches this board within a second or two through the relay, with no polling.
struct LiveUpdatesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var config: RelayConfig?
    @State private var relay = ""
    @State private var isLoading = true
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Group {
                    if isLoading {
                        ProgressView()
                    } else if let config {
                        Section {
                            Label("Live updates are on", systemImage: "dot.radiowaves.left.and.right")
                            LabeledContent("Relay", value: config.relay)
                        } footer: {
                            Text("Every device that opens this repo gets changes as they are pushed. The relay is told which files changed, never what is in them.")
                        }
                        Section {
                            Button("Turn Off", role: .destructive) { run { await model.disableLiveUpdates() } }
                                .disabled(isWorking)
                        } footer: {
                            Text("Removes the webhook from the repo, the channel from the relay, and the settings file from the repo.")
                        }
                    } else if model.canEnableLiveUpdates {
                        Section {
                            TextField("https://your-relay.workers.dev", text: $relay)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                .keyboardType(.URL)
                                #endif
                        } header: {
                            Text("Relay address")
                        } footer: {
                            Text("The address of your GitKanban relay (apps/gitkanban-relay, deployed to Cloudflare).")
                        }
                        Section {
                            Button("Turn On") {
                                model.relayURL = relay
                                run { await model.enableLiveUpdates() }
                            }
                            .disabled(isWorking || relay.trimmingCharacters(in: .whitespaces).isEmpty)
                        } footer: {
                            Text("Adds a push webhook to the repo (your account needs admin access on GitHub, or the Maintainer role on GitLab) and commits .gitkanban/relay.json so your other devices can subscribe.")
                        }
                    } else {
                        Section {
                            Text("Live updates are for repositories on GitHub or GitLab. A folder or a folder server already updates by itself.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.errorMessage {
                        Section { Text(error).font(.callout).foregroundStyle(.red) }
                    }
                }
                // Rows on the navy, not the system grey (GITKITTIE-095).
                .themedRows()
            }
            .themedList()
            .navigationTitle("Live Updates")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 320)
        #endif
        .task {
            relay = model.relayURL
            config = await model.liveUpdatesConfig()
            isLoading = false
        }
    }

    private func run(_ action: @escaping () async -> Void) {
        isWorking = true
        Task {
            await action()
            config = await model.liveUpdatesConfig()
            isWorking = false
        }
    }
}
