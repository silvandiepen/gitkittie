import GitKanbanKit
import SwiftUI

/// File storage for one repository: the bucket its images, audio, video and other big
/// files go to. The settings are saved in the repository; the keys stay on this device.
struct StorageSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let repo: AddedRepo

    @State private var isLoading = true
    @State private var enabled = true
    @State private var endpoint = ""
    @State private var bucket = ""
    @State private var region = "auto"
    @State private var publicBaseURL = ""
    @State private var accessKeyID = ""
    @State private var secretAccessKey = ""
    @State private var hasKeys = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var stillInRepository: Int?
    @State private var moved: (done: Int, total: Int)?
    @State private var moveTask: Task<Void, Never>?
    @State private var confirmsMove = false

    private var config: BoardStorageConfig {
        BoardStorageConfig(
            enabled: enabled,
            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines),
            bucket: bucket.trimmingCharacters(in: .whitespacesAndNewlines),
            region: region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "auto" : region.trimmingCharacters(in: .whitespacesAndNewlines),
            publicBaseURL: publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var canSave: Bool {
        !isWorking && !isLoading && URL(string: config.endpoint)?.host != nil && !config.bucket.isEmpty
    }

    var body: some View {
        Form {
            Section {
                Toggle("Send files to a bucket", isOn: $enabled)
            } footer: {
                Text("Images, audio, video and other big files of \(repo.displayName) go to the bucket. The repository keeps the tasks, the review requests and a small pointer per file. Files that are already in the repository keep working.")
            }

            Section {
                field("Endpoint", text: $endpoint, prompt: "https://<account>.r2.cloudflarestorage.com")
                field("Bucket", text: $bucket, prompt: "project-assets")
                field("Region", text: $region, prompt: "auto")
                field("Public address", text: $publicBaseURL, prompt: "https://files.example.com")
            } header: {
                Text("Bucket")
            } footer: {
                Text("Saved in the repository, so your other devices and your agents use the same bucket. With a public address, files are read without keys: anyone who has a file's link can open it. Without one, every device that reads needs the keys.")
            }

            Section {
                field("Access key ID", text: $accessKeyID, prompt: hasKeys ? "Saved on this device" : "Access key ID")
                SecureField("Secret access key", text: $secretAccessKey, prompt: Text(hasKeys ? "Saved on this device" : "Secret access key"))
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } header: {
                Text("Keys on this device")
            } footer: {
                Text(hasKeys
                     ? "This device has keys for this bucket. Fill in both fields to replace them."
                     : "Kept in the Keychain of this device only, never in the repository. A device without keys still reads files through the public address, and writes new files to the repository.")
            }

            Section {
                Button("Test Connection") { test() }
                    .disabled(!canSave)
                if let message {
                    Label(message, systemImage: messageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(messageIsError ? .red : .green)
                        .font(.callout)
                }
            }

            if let stillInRepository, stillInRepository > 0, hasKeys {
                Section {
                    if let moved {
                        ProgressView(value: Double(moved.done), total: Double(max(moved.total, 1))) {
                            Text("Moved \(moved.done) of \(moved.total)")
                        }
                        Button("Stop", role: .cancel) { moveTask?.cancel() }
                    } else {
                        Button("Move \(stillInRepository) Existing Files to the Bucket…") { confirmsMove = true }
                            .disabled(isWorking)
                    }
                } footer: {
                    Text("Each file becomes two commits: its pointer, and its removal. The files stay in the repository's history, so this stops the repository from growing; it does not make what git already holds smaller.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("File Storage")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!canSave)
            }
        }
        .overlay { if isLoading { ProgressView() } }
        .confirmationDialog("Move \(stillInRepository ?? 0) files to the bucket?", isPresented: $confirmsMove, titleVisibility: .visible) {
            Button("Move Files") { move() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This writes two commits per file to \(repo.displayName) and can take a long time. You can stop it; what was moved stays moved.")
        }
        .task { await load() }
        .onDisappear { moveTask?.cancel() }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        TextField(title, text: text, prompt: Text(prompt))
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            #endif
            .autocorrectionDisabled()
    }

    private func load() async {
        if let saved = await model.storageConfig(for: repo) {
            enabled = saved.enabled
            endpoint = saved.endpoint
            bucket = saved.bucket
            region = saved.region
            publicBaseURL = saved.publicBaseURL
            hasKeys = model.hasStorageKeys(for: saved)
        }
        isLoading = false
        if hasKeys { stillInRepository = await model.filesStillInRepository(repo) }
    }

    private func show(_ text: String, error: Bool) {
        message = text
        messageIsError = error
    }

    private func test() {
        isWorking = true
        message = nil
        Task {
            let problem = await model.testStorage(config, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey)
            show(problem ?? "The bucket answers with these keys.", error: problem != nil)
            isWorking = false
        }
    }

    private func save() {
        isWorking = true
        message = nil
        Task {
            if let problem = await model.saveStorage(config, accessKeyID: accessKeyID, secretAccessKey: secretAccessKey, for: repo) {
                show(problem, error: true)
                isWorking = false
            } else {
                dismiss()
            }
        }
    }

    private func move() {
        moved = (0, stillInRepository ?? 0)
        moveTask = Task {
            let problem = await model.moveExistingFilesToBucket(repo) { done, total in moved = (done, total) }
            if let problem { show(problem, error: true) } else { show("All files are in the bucket.", error: false) }
            moved = nil
            stillInRepository = await model.filesStillInRepository(repo)
        }
    }
}
