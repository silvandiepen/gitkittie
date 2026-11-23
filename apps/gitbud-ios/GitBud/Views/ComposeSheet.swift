import GitKittieKit
import GitPontCore
import SwiftUI

/// Makes a pull request from chosen lines: undoing them, or bringing them to a branch. A new
/// branch is cut from the target, the change is committed there, and the pull request opens —
/// nothing is written to the target branch itself.
struct ComposeSheet: View {
    enum Intent: String, Identifiable {
        case undo, pick
        var id: String { rawValue }
    }

    let intent: Intent
    let commit: GitCommitDetail
    let diffs: [GitFileDiff]
    let selection: GitChangeSelection
    var onDone: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var target = ""
    @State private var branchName = ""
    @State private var title = ""
    @State private var details = ""
    @State private var isWorking = false
    @State private var isDrafting = false
    @State private var problem: String?
    @State private var opened: GitPullRequest?

    private var name: String { model.connection?.changeRequestName ?? "pull request" }

    var body: some View {
        NavigationStack {
            Form {
                if let opened {
                    Section {
                        Label("Opened #\(opened.number.map(String.init) ?? opened.id)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(opened.title)
                        Button {
                            openURL(opened.webURL)
                        } label: {
                            Label("Open on \(opened.providerName)", systemImage: "safari")
                        }
                    }
                } else {
                    Section {
                        Text(explanation)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Section("Where") {
                        Picker(intent == .undo ? "Undo on" : "Bring to", selection: $target) {
                            ForEach(model.branches, id: \.name) { Text($0.name).tag($0.name) }
                        }
                        TextField("New branch", text: $branchName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                    }
                    Section {
                        TextField("Title", text: $title, axis: .vertical)
                        TextField("Description", text: $details, axis: .vertical)
                            .lineLimit(3...8)
                        if model.magicUnavailableReason == nil {
                            Button {
                                draft()
                            } label: {
                                if isDrafting {
                                    HStack { ProgressView(); Text("Drafting on this device…") }
                                } else {
                                    Label("Draft with Apple Intelligence", systemImage: "sparkles")
                                }
                            }
                            .disabled(isDrafting)
                        }
                    } header: {
                        Text("The \(name)")
                    } footer: {
                        if model.magicUnavailableReason == nil {
                            Text("Drafted on this device; your changes never leave it. You can edit the result.")
                        }
                    }
                    if let problem {
                        Section { Text(problem).foregroundStyle(.red) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.window.ignoresSafeArea())
            .navigationTitle(intent == .undo ? "Undo in a \(name)" : "Bring to a branch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(opened == nil ? "Cancel" : "Done") {
                        if opened != nil { onDone() }
                        dismiss()
                    }
                }
                if opened == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        if isWorking {
                            ProgressView()
                        } else {
                            Button("Open") { open() }
                                .accessibilityIdentifier("openPullRequest")
                                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || branchName.isEmpty || target.isEmpty)
                        }
                    }
                }
            }
            .onAppear(perform: prefill)
        }
    }

    private var explanation: String {
        let count = selection.count(in: diffs)
        let lines = "\(count) changed line\(count == 1 ? "" : "s")"
        return intent == .undo
            ? "Takes \(lines) of “\(commit.summary.subject)” back out, on a new branch, and opens a \(name) for it. Edits made since are kept."
            : "Makes \(lines) of “\(commit.summary.subject)” again on a new branch from the branch you pick, and opens a \(name) for it."
    }

    private func prefill() {
        guard target.isEmpty else { return }
        target = model.branch ?? model.branches.first?.name ?? ""
        let short = commit.summary.shortSHA
        branchName = intent == .undo ? "bud/undo-\(short)" : "bud/pick-\(short)"
        title = intent == .undo ? "Undo part of “\(commit.summary.subject)”" : "Bring part of “\(commit.summary.subject)”"
    }

    private func draft() {
        isDrafting = true
        problem = nil
        Task {
            defer { isDrafting = false }
            do {
                let drafted = try await model.draftPullRequest(commit: commit, diffs: diffs, selection: selection, reverse: intent == .undo)
                title = drafted.title
                if !drafted.body.isEmpty { details = drafted.body }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func open() {
        isWorking = true
        problem = nil
        Task {
            defer { isWorking = false }
            do {
                opened = try await model.openPullRequest(
                    commit: commit, diffs: diffs, selection: selection, reverse: intent == .undo,
                    target: target, branchName: branchName.trimmingCharacters(in: .whitespaces),
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    body: details.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
