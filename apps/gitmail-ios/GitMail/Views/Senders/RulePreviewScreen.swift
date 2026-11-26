import MailStore
import SwiftUI

/// The dry run of a sender rule change on iPhone and iPad (GKM-072): Always Junk or Always Trash
/// from a row's menu, or removing one in Settings. Every message it could touch, where it is now
/// and where it would go, and what stays where it is and why. Nothing changes until Apply; the
/// Undo that follows takes back the rule and the mail it moved.
struct RulePreviewScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var applying = false

    var body: some View {
        NavigationStack {
            if let pending = model.senders.pending {
                let rule = pending.ruleID.flatMap { id in pending.rules.first { $0.id == id } }
                List {
                    Section {
                        if let rule { Text(SenderRuleText.explanation(rule.action)) }
                        ForEach(pending.notes, id: \.self) { note in
                            Label(note, systemImage: "xmark.bin").foregroundStyle(.primary)
                        }
                        Text("Dry run: nothing has changed yet.").foregroundStyle(.secondary)
                    }
                    let moving = pending.preview.changed.filter { !$0.isInTrashOrJunk }
                    Section(moving.isEmpty ? "Nothing moves" : "Moves (\(moving.count))") {
                        ForEach(moving) { item in
                            PreviewItemRow(item: item, rules: pending.rules, canExclude: rule != nil)
                        }
                    }
                    let kept = pending.preview.items.filter { !$0.changes && ($0.protection != nil || $0.isExcluded) }
                    if !kept.isEmpty {
                        Section("Stays where it is (\(kept.count))") {
                            ForEach(kept) { item in
                                PreviewItemRow(item: item, rules: pending.rules, canExclude: rule != nil && item.isExcluded)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.window.ignoresSafeArea())
                .navigationTitle(pending.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            model.senders.cancel()
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Apply") {
                            applying = true
                            Task {
                                await model.senders.apply()
                                applying = false
                                dismiss()
                            }
                        }
                        .disabled(applying)
                        .accessibilityIdentifier("applyRule")
                    }
                }
            }
        }
    }
}

private struct PreviewItemRow: View {
    @Environment(AppModel.self) private var model
    let item: SenderRulePreview.Item
    let rules: [SenderRule]
    let canExclude: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if canExclude {
                Button {
                    Task { await model.senders.toggleExclusion(item) }
                } label: {
                    Image(systemName: item.isExcluded ? "circle" : "checkmark.circle.fill")
                        .foregroundStyle(item.isExcluded ? Color.secondary : Theme.accentText)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(item.isExcluded ? "Put this message back in the rule" : "Keep this message out of the rule")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.subject?.isEmpty == false ? item.subject! : "(No subject)").lineLimit(2)
                Text("\(item.date.formatted(date: .abbreviated, time: .omitted)) · \(SenderRuleText.placement(item.before))"
                     + (item.changes ? " → \(SenderRuleText.placement(item.after, rules: rules))" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let protection = item.protection {
                    Text(SenderRuleText.protection(protection)).font(.caption).foregroundStyle(.secondary)
                } else if item.isExcluded {
                    Text("Kept out of the rule by you.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
