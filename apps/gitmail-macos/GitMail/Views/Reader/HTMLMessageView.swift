import MailHTML
import MailReader
import MailReaderWeb
import MailStore
import SwiftUI

/// The rule lists the reader's web views share, compiled once per run.
@MainActor
@Observable
final class ReaderWebResources {
    static let shared = ReaderWebResources()
    private(set) var ruleLists: MailWebView.RuleLists?
    private(set) var failure: String?
    private var loading = false

    func load() async {
        guard ruleLists == nil, !loading else { return }
        loading = true
        do { ruleLists = try await MailWebView.ruleLists() } catch { failure = String(describing: error) }
        loading = false
    }
}

/// A sanitized HTML message in the locked-down web view (MailReaderWeb), as tall as its
/// content. Nothing shows until the content rule lists are compiled: there is no unprotected
/// moment. Link clicks come back as an index; the card shows where the link really goes.
struct HTMLMessageView: View {
    @Environment(AppModel.self) private var model
    let html: SanitizedHTML
    let content: ReaderContent
    let remoteImagesLoaded: Bool
    let onLink: (Int) -> Void
    @State private var height: CGFloat = 120
    @State private var parts: [String: InlinePart]?
    private var resources: ReaderWebResources { .shared }

    var body: some View {
        Group {
            if let ruleLists = resources.ruleLists, let parts {
                WebViewHost(html: html, parts: parts, ruleLists: ruleLists, allowRemoteImages: remoteImagesLoaded,
                            height: $height, onLink: onLink)
                    .frame(height: height)
                    // A new rule list means a new web view.
                    .id(remoteImagesLoaded)
            } else if let failure = resources.failure {
                Notice(systemImage: "exclamationmark.triangle", tint: .orange, text: "The HTML version can’t be shown safely: \(failure)")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task { await resources.load() }
        .task(id: content.inlineParts.keys.sorted()) {
            var loaded: [String: InlinePart] = [:]
            for (cid, reference) in content.inlineParts {
                if let data = try? await model.browser.attachmentData(reference) {
                    loaded[cid] = InlinePart(mediaType: reference.mediaType, data: data)
                }
            }
            parts = loaded
        }
    }
}

private struct WebViewHost: NSViewRepresentable {
    let html: SanitizedHTML
    let parts: [String: InlinePart]
    let ruleLists: MailWebView.RuleLists
    let allowRemoteImages: Bool
    @Binding var height: CGFloat
    let onLink: (Int) -> Void

    func makeNSView(context: Context) -> MailWebView {
        let view = MailWebView(ruleLists: ruleLists, allowRemoteImages: allowRemoteImages)
        view.onLinkActivated = onLink
        view.onContentHeight = { value in
            Task { @MainActor in height = max(60, value) }
        }
        view.show(html, parts: parts)
        context.coordinator.shown = html.document
        return view
    }

    func updateNSView(_ view: MailWebView, context: Context) {
        view.onLinkActivated = onLink
        guard context.coordinator.shown != html.document else { return }
        context.coordinator.shown = html.document
        view.show(html, parts: parts)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown: String?
    }
}
