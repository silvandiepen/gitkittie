import MailStore
import SwiftUI

/// The sheets the sidebar opens for spaces.
enum SpaceSheet: Identifiable {
    case create
    case edit(MailSpace)

    var id: String {
        switch self {
        case .create: "create-space"
        case .edit(let space): "edit-\(space.id.rawValue)"
        }
    }
}

/// The attachment library's row, under All Mail (GKM-023).
struct AttachmentsSidebarRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "paperclip")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("Attachments").font(.body)
        }
        .padding(.vertical, 3)
        .tag(SidebarSelection.attachments)
    }
}

/// Spaces (GKM-022): drag to reorder, drop conversations on one to add them, right-click to
/// edit, export or delete.
struct SpacesSidebarSection: View {
    @Environment(AppModel.self) private var model
    @Binding var sheet: SpaceSheet?
    @State private var deleting: MailSpace?

    var body: some View {
        Section("Spaces") {
            if model.spaces.spaces.isEmpty {
                Button {
                    sheet = .create
                } label: {
                    Label("New Space…", systemImage: "plus.circle").font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .padding(.vertical, 2)
                .selectionDisabled()
                .help("Collect mail about a project, person or company from every account")
            }
            ForEach(model.spaces.spaces) { space in
                SpaceRow(space: space, count: model.spaces.counts[space.id])
                    .tag(SidebarSelection.space(space.id))
                    .contextMenu { menu(for: space) }
                    .dropDestination(for: String.self) { items, _ in
                        let threads = SpaceLook.threadIDs(fromDrop: items)
                        guard !threads.isEmpty else { return false }
                        Task {
                            await model.spaces.add(threads: threads, to: space.id)
                            model.browser.clearMarks()
                            await model.browser.reload()
                        }
                        return true
                    }
            }
            .onMove { offsets, destination in
                Task { await model.spaces.move(from: offsets, to: destination) }
            }
            if !model.spaces.unreadableFiles.isEmpty {
                Text("\(model.spaces.unreadableFiles.count) space \(model.spaces.unreadableFiles.count == 1 ? "file" : "files") in the Mail folder couldn’t be read and were left as they are.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .selectionDisabled()
            }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { space in
            Button("Delete Space", role: .destructive) {
                Task {
                    if model.selection == .space(space.id) { await model.select(.allMail) }
                    await model.spaces.delete(space.id)
                }
            }
        } message: { _ in
            Text("Only the space goes. Its messages stay in your Mail folder and at your mail provider.")
        }
    }

    @ViewBuilder private func menu(for space: MailSpace) -> some View {
        Button("Edit Space…") { sheet = .edit(space) }
        Button("Export Space…") { Task { await Platform.export(.space(space.id), what: space.name, model: model) } }
        Divider()
        Button("Delete Space…", role: .destructive) { deleting = space }
    }
}

private struct SpaceRow: View {
    let space: MailSpace
    let count: SpaceCount?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: space.icon)
                .font(.body)
                .foregroundStyle(SpaceLook.color(space.color))
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(space.name).font(.body).lineLimit(1)
            Spacer(minLength: 4)
            if let count, count.unread > 0 {
                Text("\(count.unread)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(count.unread) unread")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .help(space.rules.isEmpty ? "Add conversations by dragging them here" : space.rules.map(\.summary).joined(separator: "\n"))
    }
}
