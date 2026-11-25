import GitKanbanKit
import GitKittieKit
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Changes the provider refused, wherever they show. Every one offers the same three
// things: Retry, Discard, and Show What It Was, so a change is never dropped without the
// person seeing what it carried.

/// One refused change: what it was, why it was refused, and what can be done.
struct SyncFailureRow: View {
    @Environment(AppModel.self) private var model
    let item: OutboxOperation
    @State private var shown: QueuedChange?
    @State private var confirmsDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.message)
                    Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    if let note = item.note {
                        Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(spacing: 16) {
                Button("Retry") { Task { await model.retrySync(item) } }
                    .accessibilityIdentifier("syncRetry")
                Button("Show What It Was") { Task { shown = await model.queuedChange(item) } }
                    .accessibilityIdentifier("syncShow")
                Button("Discard", role: .destructive) { confirmsDiscard = true }
                    .accessibilityIdentifier("syncDiscard")
            }
            .font(.callout)
            .buttonStyle(.borderless)
        }
        .confirmationDialog("Discard this change?", isPresented: $confirmsDiscard) {
            Button("Discard", role: .destructive) { Task { await model.discardSync(item) } }
        } message: {
            Text("It will not be sent, and it is removed from this device. Use Show What It Was first to keep a copy.")
        }
        .sheet(item: $shown) { change in QueuedChangeView(change: change) }
    }
}

/// Every refused change, for when there is more than one.
struct SyncFailureList: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if model.failedSyncItems.isEmpty {
                    Label("Everything is sent", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
                ForEach(model.failedSyncItems) { item in SyncFailureRow(item: item) }
            }
            .navigationTitle("Not Sent")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if model.failedSyncItems.count > 1 {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Retry All") { Task { await model.retryAllFailedSync() } }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 360)
        #endif
    }
}

/// Shown under a screen while something could not be sent: the change itself when there
/// is one, a count with the list behind it when there are more.
struct SyncFailuresBanner: View {
    @Environment(AppModel.self) private var model
    @State private var showsAll = false

    var body: some View {
        let failed = model.failedSyncItems
        if !failed.isEmpty {
            Group {
                if failed.count == 1, let item = failed.first {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Not sent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        SyncFailureRow(item: item)
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("\(failed.count) changes were not sent")
                        Spacer(minLength: 8)
                        Button("Retry All") { Task { await model.retryAllFailedSync() } }
                        Button("Show…") { showsAll = true }
                    }
                    .font(.callout)
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .accessibilityIdentifier("syncFailuresBanner")
            .sheet(isPresented: $showsAll) { SyncFailureList().environment(model) }
        }
    }
}

/// What a queued change carries: the reviewer's decisions, answers and comments for a
/// review request, and the file as it would have been written. Selectable and copyable.
struct QueuedChangeView: View {
    let change: QueuedChange
    @Environment(\.dismiss) private var dismiss

    private var copyText: String {
        var parts: [String] = []
        if !change.edits.isEmpty { parts.append(change.editLines.joined(separator: "\n")) }
        if case .text(let text) = change.content { parts.append(text) }
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(change.operation.message).font(.headline)
                        Text(change.operation.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Made \(change.operation.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !change.edits.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("What you did").font(.subheadline.weight(.semibold))
                            ForEach(Array(change.editLines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                    content
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("What It Was")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if !copyText.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Copy", systemImage: "doc.on.doc") { copy(copyText) }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 440)
        #endif
    }

    @ViewBuilder private var content: some View {
        switch change.content {
        case .text(let text):
            VStack(alignment: .leading, spacing: 6) {
                Text(change.edits.isEmpty ? "The file as it would be written" : "The file as it looked with your changes")
                    .font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        case .binary(let bytes):
            Text("A file of \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) that is not text (an image, say).")
                .foregroundStyle(.secondary)
        case .deletion:
            Text("This change removes the file.").foregroundStyle(.secondary)
        case .missing:
            Text("Nothing was stored on this device for this change. It was probably made while the disk was full, so what it carried is gone and it cannot be sent. Discard it and make the change again.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}
