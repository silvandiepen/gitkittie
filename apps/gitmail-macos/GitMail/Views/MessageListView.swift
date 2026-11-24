import MailCore
import MailStore
import SwiftUI

/// The messages of the selected account (or all), newest first, or what matches the search.
struct MessageListView: View {
    @Environment(AppModel.self) private var model

    private var selection: Binding<MailMessageID?> {
        Binding(
            get: { model.selectedMessageID },
            set: { id in Task { await model.selectMessage(id) } }
        )
    }

    private var searchText: Binding<String> {
        Binding(
            get: { model.searchText },
            set: { text in Task { await model.search(text) } }
        )
    }

    var body: some View {
        Group {
            if model.isEmpty {
                NoMailView()
            } else if model.messages.isEmpty {
                QuietNote(model.isSearching ? "No messages match “\(model.searchText)”." : "No messages here yet.")
            } else {
                List(selection: selection) {
                    ForEach(model.messages) { summary in
                        MessageRow(summary: summary).tag(summary.id)
                    }
                }
                .themedList()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .navigationTitle(model.selectedAccount?.displayName ?? "All Mail")
        .searchable(text: searchText, placement: .toolbar, prompt: "Search mail")
    }
}

private struct MessageRow: View {
    let summary: MessageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(summary.from?.displayName ?? "Unknown sender")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if summary.hasAttachments {
                    Image(systemName: "paperclip")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Has attachments")
                }
                Text(MessageDate.short(summary.date))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(summary.subject?.isEmpty == false ? summary.subject! : "(No subject)")
                .font(.callout)
                .lineLimit(1)
            if !summary.snippet.isEmpty {
                Text(summary.snippet)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}

/// The first-run state: nothing stored, no account. Says what the app does with mail and where
/// it goes, and is honest that adding an account is the step this build does not have yet.
private struct NoMailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.open")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text("No mail yet")
                .font(.title2.weight(.semibold))
            Text("GitKittie Mail keeps every message as a file you own, in your Mail folder. Adding an iCloud or IMAP account is the next step, and isn’t available in this build yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let folder = model.mailFolder {
                Button("Show Mail Folder") { Platform.reveal(folder) }
                    .padding(.top, 4)
            }
        }
        .padding(32)
    }
}

/// A single quiet line in the middle of an empty column.
struct QuietNote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .padding(24)
    }
}
