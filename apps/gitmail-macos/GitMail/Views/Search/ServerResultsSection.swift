import MailSync
import SwiftUI

/// "On the server" under the search results (GKM-041): mail at the provider that matches and
/// is not downloaded. Only there when this Mac leaves mail at the provider (a history window or
/// storage budget); clicking one downloads it and opens it, and it is then one of the results
/// above.
struct ServerResultsSection: View {
    @Environment(AppModel.self) private var model

    private var browser: MailBrowser { model.browser }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if browser.rows.isEmpty {
                Text("No downloaded messages match.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            Text("On the server")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 2)
                .accessibilityAddTraits(.isHeader)
            if let note = browser.server.note {
                HStack(spacing: 6) {
                    if browser.server == .searching { ProgressView().controlSize(.small) }
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            ForEach(browser.server.hits) { hit in
                ServerHitRow(hit: hit, isOpening: browser.openingServerHit == hit.id,
                             accountName: model.accounts.count > 1 ? model.accounts.first { $0.id == hit.account }?.displayName : nil)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard browser.openingServerHit == nil else { return }
                        Task { await browser.openServerHit(hit) }
                    }
                    .help("Download this message and open it")
                    // VoiceOver: VO-Space does what a click does (GKM-061).
                    .accessibilityAction {
                        guard browser.openingServerHit == nil else { return }
                        Task { await browser.openServerHit(hit) }
                    }
            }
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
        HStack(alignment: .top, spacing: 8) {
            Group {
                if isOpening {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "icloud.and.arrow.down").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 12, height: 12)
            .padding(.top, 3)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(hit.senderLine)
                        .font(.body.weight(hit.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if hit.isFlagged { Image(systemName: "flag.fill").font(.caption).foregroundStyle(.orange) }
                    Text(hit.dateLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(hit.subjectLine)
                    .font(.callout)
                    .lineLimit(1)
                Text(hit.whereLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let accountName {
                    Text(accountName).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(hit.accessibilityText)
        .accessibilityHint("Downloads the message and opens it")
        .accessibilityAddTraits(.isButton)
    }
}
