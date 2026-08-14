import SwiftUI
import WebKit

/// WKWebView subclass that doesn't scroll internally - passes scroll events to parent.
private class NonScrollingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) {
        // Pass scroll events to the next responder (parent ScrollView)
        nextResponder?.scrollWheel(with: event)
    }
}

/// Renders a card's markdown via Nizel in a WKWebView. Shows a loader and keeps
/// the web view hidden until the first render is done, so there's no white flash.
/// Automatically sizes to fit content.
struct MarkdownWebView: View {
    let markdown: String
    var compact: Bool = false
    @State private var isReady = false
    @State private var contentHeight: CGFloat = 100

    var body: some View {
        ZStack {
            Representable(markdown: markdown, compact: compact, onReady: { isReady = true }, onHeightChange: { contentHeight = $0 })
                .opacity(isReady ? 1 : 0)
            if !isReady {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 60)
            }
        }
        .frame(height: isReady ? contentHeight : 60)
        .animation(.easeOut(duration: 0.15), value: isReady)
    }

    private struct Representable: NSViewRepresentable {
        let markdown: String
        let compact: Bool
        let onReady: () -> Void
        let onHeightChange: (CGFloat) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(onReady: onReady, onHeightChange: onHeightChange) }

        func makeNSView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            let webView = NonScrollingWebView(frame: .zero, configuration: config)
            webView.navigationDelegate = context.coordinator
            webView.underPageBackgroundColor = .clear
            webView.setValue(false, forKey: "drawsBackground")
            context.coordinator.webView = webView
            context.coordinator.compact = compact
            if let url = Bundle.main.url(forResource: "markdown-renderer", withExtension: "html") {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
            return webView
        }

        func updateNSView(_ nsView: WKWebView, context: Context) {
            context.coordinator.onReady = onReady
            context.coordinator.onHeightChange = onHeightChange
            context.coordinator.compact = compact
            context.coordinator.render(markdown)
        }

        final class Coordinator: NSObject, WKNavigationDelegate {
            weak var webView: WKWebView?
            var onReady: () -> Void
            var onHeightChange: (CGFloat) -> Void
            var compact: Bool = false
            private var isLoaded = false
            private var didSignalReady = false
            private var pending: String?

            init(onReady: @escaping () -> Void, onHeightChange: @escaping (CGFloat) -> Void) {
                self.onReady = onReady
                self.onHeightChange = onHeightChange
            }

            func render(_ markdown: String) {
                pending = markdown
                if isLoaded { flush() }
            }

            private func flush() {
                guard let markdown = pending, let webView else { return }
                pending = nil
                let json = (try? JSONEncoder().encode(markdown))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
                webView.evaluateJavaScript("window.setMarkdown(\(json))") { [weak self] _, _ in
                    self?.measureHeight()
                }
            }

            private func measureHeight() {
                guard let webView else { return }
                webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
                    if let height = result as? CGFloat, height > 0 {
                        DispatchQueue.main.async {
                            self?.onHeightChange(height + (self?.compact == true ? 0 : 20))
                        }
                    }
                    self?.signalReady()
                }
            }

            private func signalReady() {
                guard !didSignalReady else { return }
                didSignalReady = true
                let callback = onReady
                DispatchQueue.main.async { callback() }
            }

            func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
                isLoaded = true
                flush()
            }
        }
    }
}
