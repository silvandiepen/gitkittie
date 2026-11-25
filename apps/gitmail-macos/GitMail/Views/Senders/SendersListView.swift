import MailClassifier
import MailStore
import SwiftUI

/// The sidebar row under All Mail and Attachments.
struct SendersSidebarRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.2")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("Senders").font(.body)
        }
        .padding(.vertical, 3)
        .tag(SidebarSelection.senders)
    }
}

/// Every sender and list (GKM-019): who sends you what, how much, and where it lands. Select
/// one to see its details, rules and unsubscribe on the right.
struct SendersListView: View {
    @Environment(AppModel.self) private var model
    @State private var showsRuleOrder = false

    var body: some View {
        @Bindable var senders = model.senders
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter senders", text: $senders.filter)
                    .textFieldStyle(.roundedBorder)
                Picker("Sort", selection: $senders.sort) {
                    ForEach(SendersModel.Sort.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if senders.visible.isEmpty {
                ContentUnavailableView(senders.senders.isEmpty ? "No senders yet" : "No matches",
                                       systemImage: "person.2",
                                       description: Text(senders.senders.isEmpty ? "Senders appear once mail is sorted." : "Try another name, address or domain."))
                    .frame(maxHeight: .infinity)
            } else {
                List(selection: $senders.selectedID) {
                    ForEach(senders.visible) { sender in
                        SenderRow(sender: sender, ruleCount: senders.rules(for: sender).count,
                                  unsubscribe: senders.unsubscribe.request(for: sender))
                            .tag(sender.id)
                    }
                }
                .scrollContentBackground(.hidden)
            }
            Text("“Opened here” counts only what you open in this app on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .background(Theme.window)
        .navigationTitle("Senders")
        .toolbar {
            ToolbarItem {
                Button("Rule Order", systemImage: "list.number") { showsRuleOrder = true }
                    .help("All your sender rules, in the order they’re tried")
                    .disabled(senders.rules.isEmpty)
            }
        }
        .sheet(isPresented: $showsRuleOrder) { RuleOrderSheet() }
        .sheet(item: $senders.pending) { _ in RulePreviewSheet() }
        .alert("Couldn’t do that", isPresented: Binding(get: { senders.notice != nil }, set: { if !$0 { senders.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(senders.notice ?? "")
        }
        .task { await senders.refresh() }
    }
}

private struct SenderRow: View {
    let sender: SenderSummary
    let ruleCount: Int
    let unsubscribe: UnsubscribeRequest?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: sender.isList ? "newspaper" : "person")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sender.displayName).font(.body.weight(sender.unread > 0 ? .semibold : .regular)).lineLimit(1)
                    if ruleCount > 0 {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                            .help(ruleCount == 1 ? "1 rule" : "\(ruleCount) rules")
                            .accessibilityLabel(ruleCount == 1 ? "1 rule" : "\(ruleCount) rules")
                    }
                    if let unsubscribe {
                        Text(unsubscribe.state.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(sender.scope.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(sender.messages)").font(.callout.monospacedDigit())
                    .accessibilityLabel("\(sender.messages) messages")
                Text(sender.lastSeen, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

/// Every rule in the order it is tried; the first that matches a message wins. Moving a rule
/// shows what changes before it is applied, like any other rule change.
struct RuleOrderSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Rule Order",
                        detail: "Rules are tried from the top. The first one that matches a message decides; the others are listed as “also matched” in the reader.")
            SettingsPanel {
                ForEach(Array(model.senders.rules.enumerated()), id: \.element.id) { index, rule in
                    if index > 0 { SettingsDivider() }
                    HStack(spacing: 10) {
                        Text("\(index + 1)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SenderRuleText.title(rule.action)).font(.body.weight(.medium))
                            Text(rule.scope.name).font(.caption).foregroundStyle(.secondary)
                        }
                        if !rule.isEnabled { Text("Off").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button("Move Up", systemImage: "chevron.up") { Task { await move(rule, by: -1) } }
                            .labelStyle(.iconOnly)
                            .disabled(index == 0)
                        Button("Move Down", systemImage: "chevron.down") { Task { await move(rule, by: 1) } }
                            .labelStyle(.iconOnly)
                            .disabled(index == model.senders.rules.count - 1)
                    }
                    .buttonStyle(.borderless)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .background(Theme.window)
        // Escape closes it, as Done does.
        .onExitCommand { dismiss() }
    }

    private func move(_ rule: SenderRule, by offset: Int) async {
        dismiss()
        await model.senders.proposeMove(rule, by: offset)
    }
}
