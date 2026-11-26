import SwiftUI

/// Downloading paused because the Mac's disk is nearly full (MAIL-106, GKM-090): said plainly
/// at the foot of the sidebar, with the way to Settings ▸ Storage (Free Up Space, how far back).
/// It goes by itself when there is room again; draws nothing while there is.
struct DownloadPausedNotice: View {
    let pause: DownloadPause?
    let openStorage: () -> Void

    var body: some View {
        if let pause {
            VStack(alignment: .leading, spacing: 6) {
                Label("Downloading paused", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(pause.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Storage Settings…", action: openStorage)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("downloadPausedStorage")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("downloadPaused")
        }
    }
}
