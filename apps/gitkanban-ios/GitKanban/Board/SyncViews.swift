import GitKanbanKit
import SwiftUI

/// The small status mark in the corner: a pulsing dot while changes are on their way, a
/// warning when the provider refused one, a check for a moment once everything is sent,
/// and nothing at all when there is nothing to say. Tap it for the activity list.
struct SyncIndicator: View {
    @Environment(AppModel.self) private var model
    @State private var showActivity = false
    @State private var pulsing = false
    /// Briefly true after the last change went out.
    @State private var justFinished = false

    private enum Status { case idle, sending, waiting, failed, done }

    private var status: Status {
        if !model.failedSyncItems.isEmpty { return .failed }
        if model.syncItems.contains(where: { $0.state == .sending }) { return .sending }
        if model.hasUnsentChanges { return model.isSyncing ? .sending : .waiting }
        return justFinished ? .done : .idle
    }

    var body: some View {
        Group {
            if status != .idle {
                Button { showActivity = true } label: { mark }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("syncIndicator")
                    .accessibilityLabel(label)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: status)
        .onChange(of: model.syncItems.isEmpty) { wasEmpty, isEmpty in
            guard isEmpty, !wasEmpty else { return }
            justFinished = true
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                justFinished = false
            }
        }
        .sheet(isPresented: $showActivity) { ActivitySheet().environment(model) }
    }

    private var label: String {
        switch status {
        case .sending: "Sending \(model.syncItems.count) change\(model.syncItems.count == 1 ? "" : "s")"
        case .waiting: "\(model.syncItems.count) change\(model.syncItems.count == 1 ? "" : "s") waiting to be sent"
        case .failed: "\(model.failedSyncItems.count) change\(model.failedSyncItems.count == 1 ? "" : "s") could not be sent"
        case .done: "Everything is sent"
        case .idle: ""
        }
    }

    @ViewBuilder private var mark: some View {
        HStack(spacing: 7) {
            switch status {
            case .sending:
                Circle().fill(Color.blue).frame(width: 10, height: 10)
                    .scaleEffect(pulsing ? 1.35 : 0.8)
                    .opacity(pulsing ? 0.55 : 1)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
                    .onDisappear { pulsing = false }
                Text("\(model.syncItems.count)").font(.caption.weight(.semibold).monospacedDigit())
            case .waiting:
                Image(systemName: "icloud.slash").font(.caption.weight(.semibold))
                Text("\(model.syncItems.count)").font(.caption.weight(.semibold).monospacedDigit())
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                Text("\(model.failedSyncItems.count)").font(.caption.weight(.semibold).monospacedDigit())
            case .done:
                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.green)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .themedBar(in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .contentShape(Capsule())
    }
}

/// Everything on its way to the provider, what was refused, and what went out recently.
struct ActivitySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var waiting: [OutboxOperation] { model.syncItems.filter { $0.state != .failed } }

    var body: some View {
        NavigationStack {
            List {
                if model.syncItems.isEmpty {
                    Section {
                        Label("Everything is sent", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    }
                }
                if !model.failedSyncItems.isEmpty {
                    Section {
                        ForEach(model.failedSyncItems) { item in SyncFailureRow(item: item) }
                    } header: {
                        Text("Not sent")
                    } footer: {
                        Text("Discarding drops that change. It stays on this device until you do; Show What It Was lets you copy it first.")
                    }
                }
                if !waiting.isEmpty {
                    Section("On their way") {
                        ForEach(waiting) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                row(item, systemImage: item.state == .sending ? "arrow.up.circle.fill" : "clock", tint: .blue)
                                if let note = item.note {
                                    Text(note).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                if !model.syncReceipts.isEmpty {
                    Section("Sent") {
                        ForEach(model.syncReceipts) { receipt in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(receipt.message)
                                    Text(receipt.sentAt.formatted(.relative(presentation: .named)))
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let note = receipt.note {
                                        Text(note).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                await model.refreshSyncItems()
                await model.flushOutbox()
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if !model.retryableFailedSyncItems.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Retry All") { Task { await model.retryAllFailedSync() } }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ item: OutboxOperation, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.message)
                Text(item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
}
