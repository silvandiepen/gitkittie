import MailClassifier
import SwiftUI

/// Focused first, then every other category one click away, then All Mail (GKM-018). Focused
/// shows what asks for attention (unread there) in the accent; the other views show their
/// unread count quietly; Promotions and Quarantine show how many there are, never as a call to
/// act. All Mail is always there and always shows everything; the attachment library (GKM-023)
/// follows it.
struct CategorySidebarSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            ForEach(MailCategory.allCases, id: \.self) { category in
                CategoryRow(category: category, count: count(category))
                    .tag(SidebarSelection.category(category))
            }
            CategoryRow(title: "All Mail", systemImage: "tray.full",
                        count: model.totalCount > 0 ? .init(text: "\(model.totalCount)", label: "\(model.totalCount) messages", emphasis: .quiet) : nil)
                .tag(SidebarSelection.allMail)
            AttachmentsSidebarRow()
            CleanupSidebarRow()
            if let error = model.attention.lastError {
                Button {
                    model.attention.clearError()
                } label: {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }
                .buttonStyle(.plain)
                .help("Click to dismiss")
                .selectionDisabled()
            }
            if model.attention.pendingClassification > 0 {
                Text("Sorting \(model.attention.pendingClassification.formatted()) messages…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 30)
                    .selectionDisabled()
            }
        }
    }

    private func count(_ category: MailCategory) -> CategoryRow.Count? {
        let count = model.attention.count(category)
        switch category {
        case .focused:
            guard count.unread > 0 else { return nil }
            return .init(text: "\(count.unread)", label: "\(count.unread) unread", emphasis: .attention)
        case .promotions, .quarantine:
            guard count.total > 0 else { return nil }
            return .init(text: "\(count.total)", label: "\(count.total) messages", emphasis: .quiet)
        case .transactions, .updates, .subscriptions:
            guard count.unread > 0 else { return nil }
            return .init(text: "\(count.unread)", label: "\(count.unread) unread", emphasis: .normal)
        }
    }
}

private struct CategoryRow: View {
    struct Count {
        enum Emphasis { case attention, normal, quiet }
        var text: String
        var label: String
        var emphasis: Emphasis
    }

    let title: String
    let systemImage: String
    let count: Count?

    init(category: MailCategory, count: Count?) {
        self.init(title: category.title, systemImage: category.systemImage, count: count)
    }

    init(title: String, systemImage: String, count: Count?) {
        self.title = title
        self.systemImage = systemImage
        self.count = count
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title).font(.body.weight(.medium))
            Spacer(minLength: 4)
            if let count {
                Text(count.text)
                    .font(.caption.monospacedDigit().weight(count.emphasis == .attention ? .semibold : .regular))
                    .foregroundStyle(style(count.emphasis))
                    .accessibilityLabel(count.label)
            }
        }
        .padding(.vertical, 3)
    }

    private func style(_ emphasis: Count.Emphasis) -> AnyShapeStyle {
        switch emphasis {
        case .attention: AnyShapeStyle(Theme.accent)
        case .normal: AnyShapeStyle(.secondary)
        case .quiet: AnyShapeStyle(.tertiary)
        }
    }
}
