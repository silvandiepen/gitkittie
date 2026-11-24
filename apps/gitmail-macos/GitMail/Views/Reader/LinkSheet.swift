import AppKit
import MailReader
import SwiftUI

/// Where a link really goes, before anything opens (ThreatModel §2): the full destination
/// with the part worth reading in bold, what is off about it, and an explicit choice.
struct LinkSheet: View {
    let link: LinkAssessment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(link.openURL == nil ? "This link can’t be opened" : "Open this link?")
                .font(.title3.weight(.semibold))
            if !link.link.text.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("SHOWN AS").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                    Text(link.link.text).font(.callout).lineLimit(3).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("GOES TO").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                Text(destination)
                    .font(.callout.monospaced())
                    .lineLimit(6)
                    .textSelection(.enabled)
            }
            if !link.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(link.warnings, id: \.self) { warning in
                        Notice(systemImage: warning.isSuspicious ? "exclamationmark.triangle" : "info.circle",
                               tint: warning.isSuspicious ? .orange : .secondary, text: warning.message)
                    }
                }
            }
            HStack {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.openURL?.absoluteString ?? link.displayDestination, forType: .string)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if let url = link.openURL {
                    // A suspicious link is never the default: Return cancels.
                    if link.isSuspicious {
                        Button("Open Anyway", role: .destructive) { NSWorkspace.shared.open(url); dismiss() }
                    } else {
                        Button("Open in Browser") { NSWorkspace.shared.open(url); dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 460)
    }

    /// The destination with its registrable domain in bold.
    private var destination: AttributedString {
        var text = AttributedString(link.displayDestination)
        if let domain = link.registrableDomain, let range = text.range(of: domain) {
            text[range].font = .callout.monospaced().weight(.bold)
            text[range].foregroundColor = .primary
        }
        return text
    }
}
