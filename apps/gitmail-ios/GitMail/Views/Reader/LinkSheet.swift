import MailReader
import SwiftUI
import UIKit

/// Where a link really goes, before anything opens (ThreatModel §2): the full destination
/// with the part worth reading in bold, what is off about it, and an explicit choice.
struct LinkSheet: View {
    let link: LinkAssessment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !link.link.text.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SHOWN AS").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                            Text(link.link.text).font(.callout).lineLimit(6).textSelection(.enabled)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("GOES TO").font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                            .accessibilityAddTraits(.isHeader)
                        // All of it, at any text size: the part that gives a link away can be
                        // at the end. The sheet scrolls.
                        Text(destination)
                            .font(.callout.monospaced())
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("linkDestination")
                    }
                    ForEach(link.warnings, id: \.self) { warning in
                        NoticeLine(systemImage: warning.isSuspicious ? "exclamationmark.triangle" : "info.circle",
                                   tint: warning.isSuspicious ? .orange : .secondary, text: warning.message)
                    }
                    VStack(spacing: 10) {
                        if let url = link.openURL {
                            // A suspicious link is never the prominent choice.
                            if link.isSuspicious {
                                Button("Open Anyway", role: .destructive) { openURL(url); dismiss() }
                                    .frame(maxWidth: .infinity)
                            } else {
                                Button { openURL(url); dismiss() } label: {
                                    Text("Open in Browser").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.accentFill)
                            }
                        }
                        Button("Copy Link") {
                            UIPasteboard.general.string = link.openURL?.absoluteString ?? link.displayDestination
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.top, 6)
                }
                .padding(20)
            }
            .navigationTitle(link.openURL == nil ? "This link can’t be opened" : "Open this link?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
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
