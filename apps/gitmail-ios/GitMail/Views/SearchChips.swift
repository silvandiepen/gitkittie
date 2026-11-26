import MailClassifier
import MailCore
import SwiftUI

/// The chips under the search field (GKM-016): each narrows the search, together with what the
/// search text says (`from:`, `is:unread`, …). A chip that is on is a tinted fill.
struct SearchChips: View {
    @Environment(AppModel.self) private var model

    private var filters: SearchFilters { model.browser.filters }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "See All Mail from…" (GKM-071): exactly this address; tapping it goes back.
                if let sender = filters.sender {
                    Button { Task { await model.leaveSenderView() } } label: {
                        Chip(title: "From \(SenderText.name(sender))", systemImage: "xmark.circle.fill", isOn: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("From \(sender.address)")
                    .accessibilityHint("Shows all mail again")
                    .accessibilityIdentifier("senderChip")
                }
                toggle("Unread", systemImage: "envelope.badge", isOn: filters.unreadOnly) { $0.unreadOnly.toggle() }
                toggle("Flagged", systemImage: "flag", isOn: filters.flaggedOnly) { $0.flaggedOnly.toggle() }
                toggle("Attachments", systemImage: "paperclip", isOn: filters.hasAttachment) { $0.hasAttachment.toggle() }
                Menu {
                    ForEach(DateFilter.allCases) { date in
                        Button(date.title) { change { $0.date = date } }
                    }
                } label: {
                    Chip(title: filters.date == .any ? "Date" : filters.date.title, systemImage: "calendar", isOn: filters.date != .any)
                }
                .chipState(label: "Date", value: filters.date == .any ? "Any" : filters.date.title, isOn: filters.date != .any)
                Menu {
                    Button("Every View") { change { $0.category = nil } }
                    ForEach(MailCategory.allCases, id: \.self) { category in
                        Button(category.title) { change { $0.category = category } }
                    }
                } label: {
                    Chip(title: filters.category?.title ?? "View", systemImage: "tray", isOn: filters.category != nil)
                }
                .chipState(label: "View", value: filters.category?.title ?? "Every View", isOn: filters.category != nil)
                if model.accounts.count > 1 {
                    Menu {
                        Button("Every Account") { change { $0.account = nil } }
                        ForEach(model.accounts, id: \.id) { account in
                            Button(account.displayName) { change { $0.account = account.id } }
                        }
                    } label: {
                        Chip(title: accountName ?? "Account", systemImage: "person.crop.circle", isOn: filters.account != nil)
                    }
                    .chipState(label: "Account", value: accountName ?? "Every Account", isOn: filters.account != nil)
                }
                if !filters.isEmpty {
                    Button("Clear") { Task { await model.browser.setFilters(SearchFilters()) } }
                        .font(.subheadline)
                        .padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, 16)
        }
        .accessibilityIdentifier("searchChips")
    }

    private var accountName: String? {
        filters.account.flatMap { id in model.accounts.first { $0.id == id }?.displayName }
    }

    private func toggle(_ title: String, systemImage: String, isOn: Bool, _ apply: @escaping (inout SearchFilters) -> Void) -> some View {
        Button { change(apply) } label: { Chip(title: title, systemImage: systemImage, isOn: isOn) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func change(_ apply: (inout SearchFilters) -> Void) {
        var next = filters
        apply(&next)
        Task { await model.browser.setFilters(next) }
    }
}

private struct Chip: View {
    let title: String
    let systemImage: String
    let isOn: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(isOn ? .semibold : .regular))
            // The text stays primary: the accent on its own tint is under 4.5:1 (GKM-061).
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isOn ? Theme.accent.opacity(0.2) : Theme.panel, in: Capsule())
    }
}

private extension View {
    /// A menu chip says what it filters and what it is set to, and is selected when it narrows.
    func chipState(label: String, value: String, isOn: Bool) -> some View {
        accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
