import MailCore
import MailStore
import SwiftUI

/// Creates or edits a space: name, icon, colour, and the rules that fill it, each with a live
/// preview of what it matches before anything is saved (GKM-022).
struct SpaceEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// nil: a new space.
    let space: MailSpace?

    @State private var name = ""
    @State private var icon = SpaceAppearance.defaultIcon
    @State private var color = SpaceAppearance.defaultColor
    @State private var rules: [SpaceRule] = []
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: space == nil ? "New Space" : "Edit Space",
                        detail: "A space collects mail about one project, person or company from every account. Messages are never copied or moved: the space only lists them.")
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsPanel {
                        FieldRow(label: "Name") {
                            TextField("Garden project", text: $name)
                        }
                        SettingsDivider()
                        FieldRow(label: "Colour") { colourPicker }
                        SettingsDivider()
                        FieldRow(label: "Icon") { iconPicker }
                    }
                    rulesSection
                }
            }
            .frame(minHeight: 280)
            if let error { SheetError(message: error) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(space == nil ? "Create Space" : "Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
        }
        .padding(22)
        .frame(width: 560)
        .frame(maxHeight: 720)
        .background(Theme.window)
        .onAppear {
            guard let space else { return }
            name = space.name
            icon = space.icon
            color = space.color
            rules = space.rules
        }
    }

    private var colourPicker: some View {
        HStack(spacing: 6) {
            ForEach(SpaceAppearance.colors, id: \.self) { option in
                Button {
                    color = option
                } label: {
                    Circle()
                        .fill(SpaceLook.color(option))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.white.opacity(option == color ? 0.9 : 0), lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.capitalized)
                .accessibilityAddTraits(option == color ? .isSelected : [])
            }
        }
    }

    private var iconPicker: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 4), count: 12), alignment: .leading, spacing: 4) {
            ForEach(SpaceAppearance.icons, id: \.self) { option in
                Button {
                    icon = option
                } label: {
                    Image(systemName: option)
                        .frame(width: 24, height: 24)
                        .foregroundStyle(option == icon ? SpaceLook.color(color) : .secondary)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(option == icon ? SpaceLook.color(color).opacity(0.2) : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option)
            }
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Rules").font(.headline)
                Spacer()
                Button("Add Rule", systemImage: "plus") { rules.append(SpaceRule()) }
                    .buttonStyle(.borderless)
            }
            Text("New and existing mail that matches any rule is added. A message you take out of the space stays out.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach($rules) { $rule in
                RuleEditor(rule: $rule, space: space?.id) { rules.removeAll { $0.id == rule.id } }
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let kept = rules.filter { !$0.isEmpty }
        if kept.count != rules.count {
            error = "Each rule needs a sender, a domain, a list or words in the subject. Fill it in or remove it."
            return
        }
        if let space {
            guard await model.spaces.update(space.id, name: name, icon: icon, color: color, rules: kept) else {
                error = model.spaces.actionError
                model.spaces.actionError = nil
                return
            }
        } else {
            guard let created = await model.spaces.create(name: name, icon: icon, color: color, rules: kept) else {
                error = model.spaces.actionError
                model.spaces.actionError = nil
                return
            }
            await model.select(.space(created.id))
        }
        await model.browser.reload()
        dismiss()
    }
}

/// One rule: its conditions, and what it matches right now.
private struct RuleEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var rule: SpaceRule
    let space: MailSpaceID?
    let remove: () -> Void
    @State private var preview: SpaceRulePreview?
    @State private var previewError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsPanel {
                FieldRow(label: "Sender") { TextField("ada@example.com", text: text(\.sender)) }
                SettingsDivider()
                FieldRow(label: "Domain") { TextField("example.com", text: text(\.domain)) }
                SettingsDivider()
                FieldRow(label: "Mailing list") { TextField("news.example.org", text: text(\.list)) }
                SettingsDivider()
                FieldRow(label: "Subject words") { TextField("invoice garden", text: text(\.subjectWords)) }
                SettingsDivider()
                FieldRow(label: "Account") {
                    Picker("Account", selection: $rule.account) {
                        Text("Any Account").tag(MailAccountID?.none)
                        ForEach(model.accounts) { Text($0.displayName).tag(MailAccountID?.some($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            HStack(alignment: .firstTextBaseline) {
                previewText
                Spacer()
                Button("Remove Rule", role: .destructive, action: remove)
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
        }
        .padding(.bottom, 6)
        .task(id: rule) {
            // Waits for typing to pause, then asks the index.
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            do {
                preview = try await model.spaces.preview(rule, for: space)
                previewError = nil
            } catch {
                preview = nil
                previewError = String(describing: error)
            }
        }
    }

    @ViewBuilder private var previewText: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let previewError {
                Text(previewError).font(.caption).foregroundStyle(.orange)
            } else if rule.isEmpty {
                Text("Fill in at least one condition.").font(.caption).foregroundStyle(.tertiary)
            } else if let preview {
                Text(preview.matchCount == 1 ? "Matches 1 message" : "Matches \(preview.matchCount) messages")
                    .font(.caption.weight(.medium))
                    + Text(preview.newCount == preview.matchCount ? "" : " (\(preview.newCount) new to this space)")
                    .font(.caption)
                ForEach(preview.samples) { sample in
                    Text("\(sample.from?.displayName ?? "Unknown") — \(sample.subject ?? "(No subject)")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func text(_ key: WritableKeyPath<SpaceRule, String?>) -> Binding<String> {
        Binding(get: { rule[keyPath: key] ?? "" }, set: { rule[keyPath: key] = $0.isEmpty ? nil : $0 })
    }
}
