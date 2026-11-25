import MailSync
import SwiftUI

/// "On the server" under the search results (GKM-041): older mail at the provider that matches
/// and is not downloaded. Tapping one downloads it and opens it; it is then one of the results
/// above.
struct ServerResultsSection: View {
    @Environment(AppModel.self) private var model

    private var browser: MailBrowser { model.browser }

    var body: some View {
        Section {
            if browser.rows.isEmpty {
                Text("No downloaded messages match.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
            if let note = browser.server.note {
                HStack(spacing: 8) {
                    if browser.server == .searching { ProgressView().controlSize(.small) }
                    Text(note).font(.subheadline).foregroundStyle(.secondary)
                }
                .selectionDisabled()
                .accessibilityIdentifier("serverSearchNote")
            }
            ForEach(browser.server.hits) { hit in
                Button {
                    Task { await browser.openServerHit(hit) }
                } label: {
                    ServerHitRow(hit: hit, isOpening: browser.openingServerHit == hit.id,
                                 accountName: model.accounts.count > 1
                                     ? model.accounts.first { $0.id == hit.account }?.displayName : nil)
                }
                .buttonStyle(.plain)
                .disabled(browser.openingServerHit != nil)
                .listRowBackground(Theme.window)
                .selectionDisabled()
            }
        } header: {
            Text("On the server")
        }
    }
}

/// One message at the provider: sender, subject, where it is. A cloud marks it as not
/// downloaded; while it downloads, a spinner.
private struct ServerHitRow: View {
    let hit: ServerSearchHit
    let isOpening: Bool
    let accountName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if isOpening {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "icloud.and.arrow.down").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 12, height: 12)
            .padding(.top, 4)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(hit.senderLine)
                        .font(.body.weight(hit.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if hit.isFlagged { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange) }
                    Text(hit.dateLine)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(hit.subjectLine)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(hit.whereLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let accountName {
                    Text(accountName).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hit.accessibilityText)
        .accessibilityHint("Downloads the message and opens it")
        .accessibilityIdentifier("serverHitRow")
    }
}
