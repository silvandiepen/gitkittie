import MailClassifier
import MailCore
import SwiftUI

/// The filter chips under the search field (GKM-016): account, category (GKM-018), person,
/// date, attachments, folder, unread, flagged. An active chip is a tinted fill; nothing has an outline.
struct SearchFilterBar: View {
    @Environment(AppModel.self) private var model
    @State private var person = ""
    @State private var editingPerson = false

    private var filters: SearchFilters { model.browser.filters }

    private func update(_ change: (inout SearchFilters) -> Void) {
        var next = filters
        change(&next)
        Task { await model.browser.setFilters(next) }
    }

    /// Folders of the chosen account, or of every account.
    private var folderNames: [String] {
        let lists = filters.account.map { [model.folders[$0] ?? []] } ?? Array(model.folders.values)
        return Array(Set(lists.flatMap { $0 })).sorted()
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // "See All Mail from…" (GKM-071): exactly this address; closing it goes back.
                if let sender = filters.sender {
                    Button { Task { await model.leaveSenderView() } } label: {
                        Chip(title: "From \(SenderText.name(sender))", systemImage: "xmark.circle.fill", isActive: true)
                    }
                    .buttonStyle(.plain)
                    .help("Only mail from \(sender.address). Click or press Escape to go back.")
                    .accessibilityLabel("From \(sender.address)")
                    .accessibilityHint("Shows all mail again")
                    .accessibilityIdentifier("senderChip")
                }
                if model.accounts.count > 1 {
                    Menu {
                        Button("Any Account") { update { $0.account = nil; $0.folder = nil } }
                        Divider()
                        ForEach(model.accounts) { account in
                            Button(account.displayName) { update { $0.account = account.id; $0.folder = nil } }
                        }
                    } label: {
                        Chip(title: filters.account.flatMap { id in model.accounts.first { $0.id == id }?.displayName } ?? "Account",
                             systemImage: "person.crop.circle", isActive: filters.account != nil)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                Menu {
                    Button("Any Category") { update { $0.category = nil } }
                    Divider()
                    ForEach(MailCategory.allCases, id: \.self) { category in
                        Button(category.title) { update { $0.category = category } }
                    }
                } label: {
                    Chip(title: filters.category?.title ?? "Category", systemImage: filters.category?.systemImage ?? "square.stack",
                         isActive: filters.category != nil)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                Button { editingPerson = true } label: {
                    Chip(title: filters.participant.isEmpty ? "Person" : filters.participant, systemImage: "at",
                         isActive: !filters.participant.isEmpty)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $editingPerson, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("From or to").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("Name or address", text: $person)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit {
                                update { $0.participant = person }
                                editingPerson = false
                            }
                        HStack {
                            Button("Clear") { person = ""; update { $0.participant = "" }; editingPerson = false }
                            Spacer()
                            Button("Apply") { update { $0.participant = person }; editingPerson = false }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(14)
                    .onAppear { person = filters.participant }
                }

                Menu {
                    ForEach(DateFilter.allCases) { option in
                        Button(option.title) { update { $0.date = option } }
                    }
                } label: {
                    Chip(title: filters.date == .any ? "Date" : filters.date.title, systemImage: "calendar", isActive: filters.date != .any)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()

                Button { update { $0.hasAttachment.toggle() } } label: {
                    Chip(title: "Attachments", systemImage: "paperclip", isActive: filters.hasAttachment)
                }
                .buttonStyle(.plain)

                if !folderNames.isEmpty {
                    Menu {
                        Button("Any Folder") { update { $0.folder = nil } }
                        Divider()
                        ForEach(folderNames, id: \.self) { name in
                            Button(name) { update { $0.folder = name } }
                        }
                    } label: {
                        Chip(title: filters.folder ?? "Folder", systemImage: "folder", isActive: filters.folder != nil)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }

                Button { update { $0.unreadOnly.toggle() } } label: {
                    Chip(title: "Unread", systemImage: "envelope.badge", isActive: filters.unreadOnly)
                }
                .buttonStyle(.plain)

                Button { update { $0.flaggedOnly.toggle() } } label: {
                    Chip(title: "Flagged", systemImage: "flag", isActive: filters.flaggedOnly)
                }
                .buttonStyle(.plain)

                if !filters.isEmpty {
                    Button("Clear") { Task { await model.browser.setFilters(SearchFilters()) } }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
            }
        }
    }
}

struct Chip: View {
    let title: String
    let systemImage: String
    let isActive: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            // On, the text is primary on the tint: the accent on its own tint is under 4.5:1.
            .foregroundStyle(isActive ? .primary : .secondary)
            .background(Capsule().fill(isActive ? Theme.accent.opacity(0.2) : Theme.panel))
            .contentShape(Capsule())
            .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
