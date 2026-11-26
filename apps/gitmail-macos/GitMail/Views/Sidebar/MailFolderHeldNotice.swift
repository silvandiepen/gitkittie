import SwiftUI

/// The sync is held back because the mail folder is in iCloud Drive or a folder another app
/// syncs (GKM-103, MAIL-126): said plainly at the foot of the sidebar, beside the low-disk notice,
/// with the way to Settings ▸ Storage, where another folder or the default one can be chosen.
/// Draws nothing for a folder on this Mac.
struct MailFolderHeldNotice: View {
    let hold: MailFolderPlacement?
    let openStorage: () -> Void

    var body: some View {
        if let text = hold?.text {
            VStack(alignment: .leading, spacing: 6) {
                Label("Sync paused", systemImage: "icloud.slash")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Storage Settings…", action: openStorage)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("mailFolderHeldStorage")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("mailFolderHeld")
        }
    }
}
