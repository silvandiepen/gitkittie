import SwiftUI

/// Settings ▸ General: what doesn't belong to one account, storage or notifications.
struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Messages", value: model.totalCount.formatted())
                LabeledContent("Accounts", value: model.accounts.count.formatted())
            }
            Section {
                LabeledContent("Sync") {
                    Button("Sync Now") { Task { await model.sync.syncNow() } }
                        .disabled(!model.sync.isRunning)
                }
                LabeledContent("Search index") {
                    HStack {
                        if model.isRebuildingIndex { ProgressView().controlSize(.small) }
                        Button("Rebuild Search Index") { Task { await model.rebuildIndex() } }
                            .disabled(model.phase != .ready || model.isRebuildingIndex)
                    }
                }
            } footer: {
                Text("Rebuilding reads every message in the mail folder again. Your mail and your choices are not touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Import") {
                    Button("Import Messages…") { Task { await Platform.importMessages(into: model) } }
                        .disabled(model.phase != .ready || model.isImporting)
                }
            } footer: {
                Text(".eml files you import arrive unread in On My Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .frame(minHeight: 360)
    }
}
