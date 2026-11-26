import MailStore
import SwiftUI

/// The dry run of a rule change (GKM-019): every message it could touch, where it is now and
/// where it would be, which ones a rule leaves alone and why. Untick a message to keep it out
/// of the rule. Nothing changes until you choose Apply, and Edit ▸ Undo takes it back.
struct RulePreviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showsUnchanged = false

    var body: some View {
        if let pending = model.senders.pending {
            let preview = pending.preview
            let rule = pending.ruleID.flatMap { id in pending.rules.first { $0.id == id } }
            VStack(alignment: .leading, spacing: 14) {
                SheetHeader(title: pending.title, detail: detail(preview, rule: rule))
                if let rule, rule.archiveAtProvider {
                    Notice(systemImage: "arrow.up.bin", tint: .orange, text: providerNote(preview, rule: rule))
                }
                ForEach(pending.notes, id: \.self) { note in
                    Notice(systemImage: "xmark.bin", tint: .orange, text: note)
                }
                List {
                    Section(preview.changed.isEmpty ? "Nothing moves" : "Moves (\(preview.changed.count))") {
                        ForEach(preview.changed) { item in PreviewRow(item: item, rules: pending.rules, canExclude: rule != nil) }
                    }
                    let kept = preview.items.filter { !$0.changes && ($0.protection != nil || $0.isExcluded) }
                    if !kept.isEmpty {
                        Section("Stays where it is (\(kept.count))") {
                            ForEach(kept) { item in PreviewRow(item: item, rules: pending.rules, canExclude: rule != nil && item.isExcluded) }
                        }
                    }
                    let unchanged = preview.items.filter { !$0.changes && $0.protection == nil && !$0.isExcluded }
                    if !unchanged.isEmpty {
                        Section {
                            if showsUnchanged {
                                ForEach(unchanged) { item in PreviewRow(item: item, rules: pending.rules, canExclude: false) }
                            }
                        } header: {
                            Button(showsUnchanged ? "Hide \(unchanged.count) unchanged" : "Show \(unchanged.count) unchanged") {
                                showsUnchanged.toggle()
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
                .frame(minHeight: 260)
                HStack {
                    Text("Dry run: nothing has changed yet.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        model.senders.cancel()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    Button("Apply") {
                        Task {
                            await model.senders.apply()
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
            .frame(width: 620)
            .frame(maxHeight: 720)
            .background(Theme.window)
        }
    }

    /// What the rule's archive at the provider does (GKM-031): only with active mode on.
    private func providerNote(_ preview: SenderRulePreview, rule: SenderRule) -> String {
        guard model.organisation.isActive(rule.account) else {
            return "Active organisation is off for this account, so nothing is archived at your mail provider until you turn it on in Settings ▸ Organisation."
        }
        let silenced = preview.items.filter { $0.after.rule == rule.id && ($0.after.disposition == .archived || $0.after.disposition == .muted) && !$0.isExcluded }.count
        let count = silenced == 1 ? "1 message" : "\(silenced) messages"
        return "This rule also archives the mail it silences at your mail provider: up to \(count) now (those in the inbox), and new mail after each check. It’s listed in Settings ▸ Organisation ▸ History, where you can undo it."
    }

    private func detail(_ preview: SenderRulePreview, rule: SenderRule?) -> String {
        var parts: [String] = []
        if let rule { parts.append(SenderRuleText.explanation(rule.action)) }
        let count = preview.changed.count
        parts.append(count == 0 ? "No message moves." : count == 1 ? "1 message moves." : "\(count) messages move.")
        if rule?.action.blocks != true {
            parts.append("New mail is sorted the same way. Your mail provider isn’t changed\(rule?.archiveAtProvider == true ? " except for the archive" : "").")
        }
        return parts.joined(separator: " ")
    }
}

private struct PreviewRow: View {
    @Environment(AppModel.self) private var model
    let item: SenderRulePreview.Item
    let rules: [SenderRule]
    let canExclude: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if canExclude {
                Toggle("Include", isOn: Binding(get: { !item.isExcluded }, set: { _ in Task { await model.senders.toggleExclusion(item) } }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(item.isExcluded ? "Put this message back in the rule" : "Keep this message out of the rule")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.subject?.isEmpty == false ? item.subject! : "(No subject)").lineLimit(1)
                HStack(spacing: 6) {
                    Text(item.date, format: .dateTime.day().month().year())
                    Text(SenderRuleText.placement(item.before))
                    if item.changes {
                        Image(systemName: "arrow.right").accessibilityLabel("becomes")
                        Text(SenderRuleText.placement(item.after, rules: rules)).foregroundStyle(Theme.accent)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let protection = item.protection {
                    Text(SenderRuleText.protection(protection)).font(.caption).foregroundStyle(.secondary)
                } else if item.isExcluded {
                    Text("Kept out of the rule by you.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
