import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Encrypted archive (GKM-032, MAIL-128..130): File ▸ Export Encrypted Archive… writes it and
// shows the recovery key once; File ▸ Restore Encrypted Archive… opens one into a new folder.
// The decisions (what is in it, the key, the confirm step) live in the app model,
// `EncryptedArchiveModel`; these views only show it.

extension Platform {
    /// Asks for a folder and writes the encrypted archive into it.
    @MainActor
    static func writeEncryptedArchive(model: AppModel) async {
        guard let folder = await chooseFolder(
            title: "Export Encrypted Archive", prompt: "Export Here",
            message: "One encrypted file with all your mail, attachments, accounts (without passwords), spaces, rules and corrections. You get a recovery key to save; it is the only way to open the archive.")
        else { return }
        await model.writeEncryptedArchive(to: folder)
    }

    @MainActor
    static func chooseArchive() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose an Encrypted Archive"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gkmarchive") ?? .data]
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }
}

extension View {
    /// The recovery key sheet, the restore sheet and their notices.
    func encryptedArchiveChrome(_ model: AppModel, restoring: Binding<Bool>) -> some View {
        modifier(EncryptedArchiveChrome(model: model, restoring: restoring))
    }
}

private struct EncryptedArchiveChrome: ViewModifier {
    let model: AppModel
    @Binding var restoring: Bool

    func body(content: Content) -> some View {
        let archive = model.encryptedArchive
        content
            .sheet(isPresented: Binding(get: { archive.written != nil }, set: { _ in })) {
                RecoveryKeySheet(archive: archive)
            }
            .sheet(isPresented: $restoring) { RestoreArchiveSheet() }
            .alert("Archive restored", isPresented: Binding(
                get: { archive.restored != nil },
                set: { if !$0 { archive.restored = nil } }
            ), presenting: archive.restored) { restored in
                Button("Use Restored Mail") { Task { await model.useRestoredMail() } }
                Button("Show in Finder") { Platform.reveal(restored.folder) }
                Button("Later", role: .cancel) {}
            } message: { restored in
                Text(restored.summary)
            }
            .alert("Encrypted archive", isPresented: Binding(
                get: { archive.error != nil && !restoring },
                set: { if !$0 { archive.error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(archive.error ?? "")
            }
            .overlay {
                if archive.isWorking && !restoring {
                    ProgressView("Writing the encrypted archive…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
    }
}

/// The recovery key, shown once: copy it or save it, then type its last group back.
private struct RecoveryKeySheet: View {
    @Bindable var archive: EncryptedArchiveModel
    @State private var confirmsDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Save Your Recovery Key",
                        detail: "This key is the only way to open the archive. GitKittie Mail keeps no copy and can’t show it again. Keep it somewhere other than the archive: anyone who has both can read your mail.")
            if let written = archive.written {
                Text(written.summary).foregroundStyle(.secondary)
                Text(written.keyText)
                    .font(.system(.title2, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.12)))
                    .accessibilityLabel("Recovery key")
                    .accessibilityValue(written.keyGroups.joined(separator: ", "))
                HStack {
                    Button("Copy Key") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(written.keyText, forType: .string)
                    }
                    Button("Save as Text File…") { Task { await saveKeyFile() } }
                }
                SettingsPanel {
                    FieldRow(label: "Last four") {
                        TextField(String(repeating: "•", count: 4), text: $archive.confirmation)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel("The last four characters of the recovery key")
                    }
                }
                Text("Type the key’s last four characters to confirm you saved it.").foregroundStyle(.secondary)
            }
            HStack {
                Button("Delete Archive…", role: .destructive) { confirmsDiscard = true }
                Spacer()
                Button("Done") { archive.finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!archive.isConfirmed)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.window)
        .interactiveDismissDisabled()
        .confirmationDialog("Delete the archive?", isPresented: $confirmsDiscard) {
            Button("Delete Archive", role: .destructive) { archive.discard() }
        } message: {
            Text("Without this key the archive can never be opened, so it is removed.")
        }
    }

    @MainActor
    private func saveKeyFile() async {
        guard let text = archive.keyFileText else { return }
        let panel = NSSavePanel()
        panel.title = "Save Recovery Key"
        panel.nameFieldStringValue = archive.keyFileName ?? "Recovery Key.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            archive.error = "The key couldn’t be saved: \(error.localizedDescription)"
        }
    }
}

/// Choose an archive, type its key, choose where the restored mail goes.
private struct RestoreArchiveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var key = ""

    var body: some View {
        let archive = model.encryptedArchive
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Restore Encrypted Archive",
                        detail: "The archive is checked as it is opened and restored into a new folder, “Restored Mail”. Your current mail folder isn’t changed.")
            SettingsPanel {
                FieldRow(label: "Archive") {
                    HStack {
                        Text(file?.lastPathComponent ?? "None chosen").foregroundStyle(file == nil ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") { Task { if let url = await Platform.chooseArchive() { file = url } } }
                    }
                }
                SettingsDivider()
                FieldRow(label: "Recovery key") {
                    TextField("XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX", text: $key)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Recovery key")
                }
            }
            if let error = archive.error { SheetError(message: error) }
            HStack {
                if archive.isWorking { ProgressView().controlSize(.small); Text("Restoring…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore…") { Task { await restore() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(file == nil || key.isEmpty || archive.isWorking)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(Theme.window)
        .onAppear { archive.error = nil }
    }

    @MainActor
    private func restore() async {
        guard let file, let parent = await Platform.chooseFolder(
            title: "Restore Into", prompt: "Restore Here",
            message: "A new folder, “Restored Mail”, is made here.") else { return }
        model.encryptedArchive.error = nil
        await model.restoreEncryptedArchive(file, recoveryKey: key, into: parent)
        if model.encryptedArchive.error == nil { dismiss() }
    }
}
