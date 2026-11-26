import MailCompose
import MailCore
import SwiftUI

/// The compose window's scene, opened with a draft's id.
enum ComposeScene {
    static let id = "compose"
}

/// The drafts in the mail folder, newest first. Opening one opens its compose window.
struct DraftsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var selection: DraftID?

    var body: some View {
        Group {
            if let sending = app.sending, !sending.drafts.isEmpty {
                // Return or a double-click opens the selected draft (GKM-061: the keyboard too).
                List(selection: $selection) {
                    ForEach(sending.drafts) { draft in
                        DraftRow(draft: draft).tag(draft.id)
                    }
                }
                .contextMenu(forSelectionType: DraftID.self) { ids in
                    if let id = ids.first {
                        Button("Open") { openWindow(id: ComposeScene.id, value: id) }
                        Button("Delete Draft", role: .destructive) { Task { await sending.discard(id) } }
                    }
                } primaryAction: { ids in
                    for id in ids { openWindow(id: ComposeScene.id, value: id) }
                }
                .themedList()
            } else {
                QuietNote("No drafts.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .navigationTitle("Drafts")
        .task { await app.sending?.refreshDrafts() }
    }
}

private struct DraftRow: View {
    let draft: ComposeDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(recipients)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(MessageDate.short(draft.updatedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(draft.subject.isEmpty ? "(No subject)" : draft.subject)
                .font(.callout)
                .lineLimit(1)
            if draft.conflictOf != nil {
                Text("A second version, kept when two edits met")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the draft")
    }

    private var recipients: String {
        let names = (draft.to + draft.cc).map(\.displayName)
        return names.isEmpty ? "No recipients" : names.joined(separator: ", ")
    }
}

/// Drafts and Outbox in the sidebar.
struct SendingSidebarSection: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let sending = app.sending {
            Section {
                SidebarCountRow(title: "Drafts", symbol: "doc.text", count: sending.drafts.count, warning: false)
                    .tag(SidebarSelection.drafts)
                SidebarCountRow(title: "Outbox", symbol: "tray.and.arrow.up", count: sending.pending.count,
                                warning: !sending.needsAttention.isEmpty)
                    .tag(SidebarSelection.outbox)
            }
        }
    }
}

private struct SidebarCountRow: View {
    let title: String
    let symbol: String
    let count: Int
    /// Something in it needs the person: a failed or possibly-sent message.
    let warning: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: warning ? "exclamationmark.triangle" : symbol)
                .font(.body)
                .foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title).font(.body)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(warning ? "\(count), needs attention" : "\(count)")
            }
        }
        .padding(.vertical, 3)
    }
}
