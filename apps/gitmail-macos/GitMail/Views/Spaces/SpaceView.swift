import MailStore
import SwiftUI

/// A space: its conversations, or its attachments (GKM-022).
struct SpaceView: View {
    @Environment(AppModel.self) private var model
    let space: MailSpaceID
    @State private var showsAttachments = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Show", selection: $showsAttachments) {
                Text("Messages").tag(false)
                Text("Attachments").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 8)
            if showsAttachments {
                AttachmentLibraryView(space: space)
                    .navigationTitle(model.spaces.space(space)?.name ?? "Space")
            } else {
                MessageListView()
            }
        }
        .background(Theme.window)
        .onChange(of: space) { _, _ in showsAttachments = false }
    }
}

/// "Add to Space" for the list's context menu and the Message menu: every space, and a new one.
struct AddToSpaceMenu: View {
    @Environment(AppModel.self) private var model
    let threadIDs: () -> [String]
    let newSpace: (() -> Void)?

    var body: some View {
        Menu("Add to Space") {
            ForEach(model.spaces.spaces) { space in
                Button(space.name) {
                    Task {
                        await model.spaces.add(threads: threadIDs(), to: space.id)
                        model.browser.clearMarks()
                        await model.browser.reload()
                    }
                }
            }
            if let newSpace {
                if !model.spaces.spaces.isEmpty { Divider() }
                Button("New Space…", action: newSpace)
                    .disabled(!model.canWrite)
            }
        }
        .disabled(model.spaces.spaces.isEmpty && newSpace == nil)
    }
}

/// The message list's context menu for one row (or every marked row): spaces and export.
struct SpaceRowMenu: View {
    @Environment(AppModel.self) private var model
    let rowID: String

    var body: some View {
        let threads = { model.browser.threadIDs(actingOn: rowID) }
        AddToSpaceMenu(threadIDs: threads, newSpace: nil)
        if case .space(let id) = model.selection, let space = model.spaces.space(id) {
            Button("Remove from “\(space.name)”") {
                Task {
                    await model.spaces.remove(threads: threads(), from: id)
                    model.browser.clearMarks()
                    await model.browser.reload()
                }
            }
        }
        Divider()
        Button(threads().count > 1 ? "Export \(threads().count) Conversations…" : "Export Conversation…") {
            let ids = threads()
            Task { await Platform.export(.threads(ids), what: ids.count > 1 ? "Conversations" : "Conversation", model: model) }
        }
    }
}
