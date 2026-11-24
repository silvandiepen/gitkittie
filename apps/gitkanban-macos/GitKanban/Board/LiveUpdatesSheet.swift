import GitKanbanKit
import SwiftUI

/// Turn live updates on or off for the open repo. With them on, a push to the repo
/// reaches this board within a second or two through the relay, with no polling.
///
/// Laid out like the other Mac sheets (Agent Access): a header that says what this is, then
/// the one field and the one action. A grouped `Form` puts a text field's prompt in a label
/// column on the Mac, which cut the address in half and pushed the text off the sheet.
struct LiveUpdatesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var config: RelayConfig?
    @State private var relay = ""
    @State private var isLoading = true
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(
                title: "Live Updates",
                detail: "A push to this repository shows up on the open board within seconds, on every device, without waiting for a refresh."
            )

            if isLoading {
                ProgressView().controlSize(.small)
            } else if let config {
                onContent(config)
            } else if model.canEnableLiveUpdates {
                offContent
            } else {
                Text("Live updates are for repositories on GitHub or GitLab. A folder or a folder server already updates by itself.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task {
            relay = model.relayURL
            config = await model.liveUpdatesConfig()
            isLoading = false
        }
    }

    private func onContent(_ config: RelayConfig) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsPanel {
                SettingsRow(icon: "dot.radiowaves.left.and.right", tint: .green, title: "Live updates are on",
                            detail: "The relay is told which files changed, never what is in them.") {
                    Button("Turn Off", role: .destructive) { run { await model.disableLiveUpdates() } }
                        .controlSize(.small)
                        .disabled(isWorking)
                }
                SettingsDivider()
                SettingsRow(icon: "server.rack", tint: .gray, title: "Relay") {
                    Text(config.relay)
                        .font(.callout.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Text("Turning off removes the webhook, the relay channel and the settings file from the repository.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var offContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsPanel {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Relay address").font(.subheadline.weight(.medium))
                    HStack(spacing: 8) {
                        TextField("Relay address", text: $relay, prompt: Text("https://your-relay.workers.dev"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                            .onSubmit(turnOn)
                        Button("Turn On", action: turnOn)
                            .keyboardShortcut(.defaultAction)
                            .disabled(isWorking || relay.trimmingCharacters(in: .whitespaces).isEmpty)
                        if isWorking { ProgressView().controlSize(.small) }
                    }
                    Text("Your GitKanban relay on Cloudflare (apps/gitkanban-relay).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
            }
            Text("Turning on adds a push webhook to the repository and commits .gitkanban/relay.json so your other devices subscribe too. It needs admin access on GitHub, or the Maintainer role on GitLab.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func turnOn() {
        guard !isWorking, !relay.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        model.relayURL = relay
        run { await model.enableLiveUpdates() }
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
