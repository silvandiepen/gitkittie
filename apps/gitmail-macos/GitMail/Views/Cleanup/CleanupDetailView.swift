import MailClassifier
import MailCore
import MailStore
import SwiftUI

/// The selected group: its samples, the actions you can preview, and the exact preview — every
/// message a batch changes (tick one off to keep it), every message it leaves alone and why.
struct CleanupDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cleanup = model.cleanup
        Group {
            if cleanup.isReadingSample {
                VStack(spacing: 0) {
                    HStack {
                        Button("Back to Clean Up", systemImage: "chevron.left") { cleanup.isReadingSample = false }
                            .buttonStyle(.borderless)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    ReaderView()
                }
            } else if let group = cleanup.group {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        GroupHeader(group: group)
                        if let run = cleanup.lastRun { RunResult(run: run) }
                        Samples(group: group)
                        if let preview = cleanup.preview {
                            PreviewSection(preview: preview)
                        } else {
                            Actions(group: group)
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(spacing: 12) {
                    if let run = cleanup.lastRun { RunResult(run: run) }
                    QuietNote("Choose a group to see its messages")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
    }
}

private struct GroupHeader: View {
    let group: CleanupGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.title)
                .font(.title.weight(.semibold))
                .tracking(-0.3)
                .textSelection(.enabled)
            if let detail = group.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(CleanupText.stats(group)).font(.callout.monospacedDigit()).foregroundStyle(.tertiary)
        }
    }
}

private struct Samples: View {
    @Environment(AppModel.self) private var model
    let group: CleanupGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Heading("Samples")
            ForEach(group.samples) { sample in
                MessageLine(message: sample, note: nil) { Task { await model.cleanup.open(sample) } }
            }
        }
    }
}

/// What you can preview. Previewing changes nothing.
private struct Actions: View {
    @Environment(AppModel.self) private var model
    let group: CleanupGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Heading("Suggested actions")
            Text("Suggestions can be wrong. Each one shows you exactly which messages it would change before anything happens.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Preview Archive…") { Task { await model.cleanup.preview(.archive) } }
                Button("Preview Move to Trash…") { Task { await model.cleanup.preview(.trash) } }
                Menu("Preview Move To") {
                    ForEach(model.cleanup.moveTargets(account: group.id.account), id: \.self) { folder in
                        Button(folder) { Task { await model.cleanup.preview(.move(to: folder)) } }
                    }
                }
                .fixedSize()
            }
            if group.id.isSenderOrList {
                HStack(spacing: 8) {
                    Button("Mute…") { Task { await model.proposeSenderRule(.mute, for: group.id) } }
                    Menu("Always List Under") {
                        Button(MailCategory.promotions.title) { Task { await model.proposeSenderRule(.category(.promotion), for: group.id) } }
                        Button(MailCategory.subscriptions.title) { Task { await model.proposeSenderRule(.category(.subscription), for: group.id) } }
                    }
                    .fixedSize()
                }
                .help("A rule for this sender or list, previewed in Senders. It changes where mail shows here, not at your provider.")
            }
        }
    }
}

/// The exact preview of a batch.
private struct PreviewSection: View {
    @Environment(AppModel.self) private var model
    let preview: CleanupPreview

    var body: some View {
        let cleanup = model.cleanup
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(CleanupText.verb(preview.operation, count: cleanup.runCount)).font(.title3.weight(.semibold))
                Text(CleanupText.consequence(preview.operation)).font(.callout).foregroundStyle(.secondary)
            }

            if !cleanup.changedSincePreview.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Nothing ran: \(CleanupText.messages(cleanup.changedSincePreview.count)) changed since the preview. This is the new preview.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                    ForEach(cleanup.changedSincePreview, id: \.self) { difference in
                        Text(difference.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if preview.options.includeTransactions || preview.protected.contains(where: { $0.protections == [.transaction] }) {
                Toggle("Include receipts, orders and invoices", isOn: Binding(
                    get: { preview.options.includeTransactions },
                    set: { include in Task { await cleanup.setIncludesTransactions(include) } }
                ))
                .toggleStyle(.checkbox)
            }

            VStack(alignment: .leading, spacing: 2) {
                Heading("Will change (\(preview.included.count.formatted()))")
                if preview.included.isEmpty {
                    Text("Nothing in this group can be changed this way.").font(.callout).foregroundStyle(.tertiary)
                }
                ForEach(preview.included) { item in
                    HStack(spacing: 8) {
                        Toggle("", isOn: Binding(
                            get: { !cleanup.excluded.contains(item.id) },
                            set: { _ in cleanup.toggleExclusion(item.id) }
                        ))
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                        .accessibilityLabel("Include “\(item.summary.subject ?? "(No subject)")”")
                        MessageLine(message: item.summary, note: item.note) { Task { await cleanup.open(item.summary) } }
                    }
                }
            }

            if !preview.protected.isEmpty {
                DisclosureGroup {
                    ForEach(preview.protected) { item in
                        MessageLine(message: item.summary, note: item.protections.map(CleanupText.protection).joined(separator: " · ")) {
                            Task { await cleanup.open(item.summary) }
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Left alone (\(preview.protected.count.formatted()))").font(.callout.weight(.medium))
                        Text(protectionSummary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if !preview.skipped.isEmpty {
                DisclosureGroup {
                    ForEach(preview.skipped) { item in
                        MessageLine(message: item.summary, note: item.skip.map(CleanupText.skip)) { Task { await cleanup.open(item.summary) } }
                    }
                } label: {
                    Text("Not affected (\(preview.skipped.count.formatted()))").font(.callout.weight(.medium))
                }
            }

            HStack {
                Button("Cancel") { cleanup.cancelPreview() }
                Spacer()
                Button(CleanupText.verb(preview.operation, count: cleanup.runCount) + "…") { cleanup.requestRun() }
                    .buttonStyle(.borderedProminent)
                    .disabled(cleanup.runCount == 0)
            }
        }
        .confirmationDialog(CleanupText.verb(preview.operation, count: cleanup.runCount) + "?", isPresented: Binding(
            get: { cleanup.confirming != nil },
            set: { if !$0 { cleanup.cancelRun() } }
        )) {
            Button(CleanupText.verb(preview.operation, count: cleanup.runCount)) { Task { await cleanup.confirmRun() } }
            Button("Cancel", role: .cancel) { cleanup.cancelRun() }
        } message: {
            Text(CleanupText.consequence(preview.operation) + " If anything changed since this preview, nothing runs.")
        }
    }

    private var protectionSummary: String {
        let counts = preview.protectionCounts
        return CleanupProtection.allCases.compactMap { reason in
            counts[reason].map { "\(CleanupText.protection(reason)): \($0)" }
        }.joined(separator: " · ")
    }
}

private struct RunResult: View {
    @Environment(AppModel.self) private var model
    let run: (run: CleanupRun, title: String)

    var body: some View {
        HStack(spacing: 10) {
            Text(CleanupText.done(run.title, count: run.run.batch.count)).font(.callout)
            if model.cleanup.canUndoLastRun {
                Button("Undo") { Task { await model.cleanup.undoLastRun() } }
                    .buttonStyle(.borderless)
            }
        }
    }
}

private struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .padding(.bottom, 4)
    }
}

/// A message on one line: sender, subject, date, and why it is listed. Click to read it.
private struct MessageLine: View {
    let message: MessageSummary
    let note: String?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(message.from?.displayName ?? "Unknown sender")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.subject?.isEmpty == false ? message.subject! : "(No subject)").font(.callout).lineLimit(1)
                    if let note { Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                Text(MessageDate.short(message.date)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open this message")
    }
}

extension CleanupGroupID {
    /// A sender or a list: a category rule can be made for it.
    var isSenderOrList: Bool {
        switch kind {
        case .sender, .list: true
        default: false
        }
    }
}
