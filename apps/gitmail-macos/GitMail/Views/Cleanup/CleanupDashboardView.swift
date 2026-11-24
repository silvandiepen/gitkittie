import MailClassifier
import MailCore
import MailStore
import SwiftUI

/// The sidebar row for the cleanup dashboard (GKM-021).
struct CleanupSidebarRow: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.sparkles")
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("Clean Up").font(.body)
        }
        .padding(.vertical, 3)
        .tag(SidebarSelection.cleanup)
    }
}

/// What clutters the mailbox, read from this Mac's index: nothing here changes any mail. Pick a
/// group to see its messages and preview what an action would do.
struct CleanupDashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let cleanup = model.cleanup
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let overview = cleanup.overview {
                    composition(overview)
                    section("Noisy senders and lists", overview.noisy, empty: "No sender or list sends you a lot of bulk mail.")
                    section("Offers that have ended", overview.expiredOffers, empty: "No old or ended offers.")
                    section("Recurring digests", overview.digests, empty: "No digests with older issues.")
                    section("Large attachments", overview.largeMessages, empty: "No large messages.")
                } else if cleanup.isAnalysing {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .background(Theme.window)
        .navigationTitle("Clean Up")
        .task { if cleanup.overview == nil { await cleanup.analyse() } }
        .alert("Something went wrong", isPresented: Binding(
            get: { cleanup.notice != nil },
            set: { if !$0 { cleanup.notice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(cleanup.notice ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Looking changes nothing. A batch runs only after you preview it and confirm.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Analyse Again") { Task { await model.cleanup.analyse() } }
                    .disabled(model.cleanup.isAnalysing)
                if let overview = model.cleanup.overview {
                    Text("Read \(overview.analysedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func composition(_ overview: CleanupOverview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Your mail")
            ForEach(overview.composition, id: \.account) { account in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(model.accounts.first { $0.id == account.account }?.displayName ?? account.account.rawValue)
                            .font(.body.weight(.medium))
                        Spacer()
                        Text(CleanupText.messages(account.total)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ForEach(MailCategory.allCases, id: \.self) { category in
                        if let count = account.categories[category], count.total > 0 {
                            HStack {
                                Text(category.title).font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(count.total.formatted()) · \(count.unread.formatted()) unread")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            if overview.unclassified > 0 {
                Text("\(CleanupText.messages(overview.unclassified)) not sorted yet; they’re never suggested.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func section(_ title: String, _ groups: [CleanupGroup], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title)
            if groups.isEmpty {
                Text(empty).font(.callout).foregroundStyle(.tertiary)
            }
            ForEach(groups) { group in
                CleanupGroupRow(group: group, accountName: accountName(group.id.account),
                                isSelected: model.cleanup.selectedGroup == group.id) {
                    Task { await model.cleanup.select(group.id) }
                }
            }
        }
    }

    private func accountName(_ id: MailAccountID) -> String? {
        guard model.accounts.count > 1 else { return nil }
        return model.accounts.first { $0.id == id }?.displayName
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

private struct CleanupGroupRow: View {
    let group: CleanupGroup
    let accountName: String?
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.title).font(.body.weight(.medium)).lineLimit(1)
                if let detail = group.detail ?? accountName {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Text(CleanupText.stats(group)).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isSelected ? Theme.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
