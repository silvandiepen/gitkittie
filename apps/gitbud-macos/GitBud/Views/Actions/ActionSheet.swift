import GitBudCore
import GitKittieKit
import SwiftUI

/// Renders whatever a `GitBudAction` needs before it runs: a value, a yes, or a typed
/// phrase for the operations that rewrite published history.
struct ActionSheet: View {
    let action: GitBudAction
    let onDismiss: () -> Void

    @State private var text = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch action.interaction {
            case .immediate:
                EmptyView()

            case let .input(title, placeholder, _, verb):
                header(title, message: nil)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFieldFocused)
                    .onSubmit { run(verb: verb) }
                buttons(verb: verb, isEnabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            case let .confirm(title, message, verb):
                header(title, message: message)
                buttons(verb: verb, isEnabled: true)

            case let .confirmTyped(title, message, phrase, verb):
                header(title, message: message)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type \(phrase) to confirm")
                        .font(.caption)
                        .foregroundStyle(GitBudTheme.secondaryText)
                    TextField(phrase, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .focused($isFieldFocused)
                }
                buttons(verb: verb, isEnabled: text.trimmingCharacters(in: .whitespacesAndNewlines) == phrase)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(GitBudTheme.panel)
        .foregroundStyle(GitBudTheme.primaryText)
        .onAppear {
            if case let .input(_, _, defaultValue, _) = action.interaction {
                text = defaultValue
            }
            isFieldFocused = true
        }
    }

    private func header(_ title: String, message: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Image(systemName: action.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(action.isDestructive ? .red : Color.accentColor)
                Text(title)
                    .font(.headline.weight(.semibold))
            }
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(GitBudTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func buttons(verb: String, isEnabled: Bool) -> some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { onDismiss() }
                .keyboardShortcut(.cancelAction)
            Button(verb, role: action.isDestructive ? .destructive : nil) { run(verb: verb) }
                .keyboardShortcut(.defaultAction)
                .disabled(!isEnabled)
        }
    }

    private func run(verb: String) {
        action.perform(text)
        onDismiss()
    }
}

/// Attaches action handling to any view: renders the menu items and hosts the sheet
/// whichever action needs one.
struct ActionMenuItems: View {
    let actions: [GitBudAction]
    @Binding var pending: GitBudAction?

    var body: some View {
        ForEach(actions) { action in
            Button {
                if action.needsSheet {
                    pending = action
                } else {
                    action.perform("")
                }
            } label: {
                Label(action.title, systemImage: action.icon)
            }
            .disabled(!action.isEnabled)
            .help(action.disabledReason ?? "")
        }
    }
}

extension View {
    /// Hosts the sheet for whichever action is pending.
    func actionSheet(pending: Binding<GitBudAction?>) -> some View {
        sheet(item: pending) { action in
            ActionSheet(action: action) { pending.wrappedValue = nil }
        }
    }
}
