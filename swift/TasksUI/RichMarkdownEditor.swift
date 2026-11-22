import SwiftUI
import WebKit

/// A task's notes, rendered and editable in place: headings are headings, lists are
/// lists, a checkbox can be ticked, and typing changes the Markdown underneath.
///
/// It is the editor Lezin uses for its preview (`swift/RichEditorWeb`, the Nizel runtime):
/// the page renders the Markdown, the reader edits the page, and the page turns itself
/// back into Markdown. The view is as tall as its content and never scrolls by itself.
struct RichMarkdownEditor: View {
    @Binding var text: String
    var isEditable = true
    var fontSize: CGFloat = 14
    var minHeight: CGFloat = 80
    /// Shown while the notes are empty.
    var placeholder = "Add a description…"
    /// Called when the editor loses the cursor: the moment to save what was typed.
    var onEndEditing: () -> Void = {}

    @State private var height: CGFloat = 0

    var body: some View {
        Representable(text: $text, height: $height, isEditable: isEditable, fontSize: fontSize,
                      minHeight: minHeight, placeholder: placeholder, onEndEditing: onEndEditing)
            .frame(height: max(height, minHeight))
    }
}

#if os(macOS)
private typealias PlatformRepresentable = NSViewRepresentable

/// Hands the scroll wheel to the panel around it: the page is as tall as its content.
private final class EditorWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}
#else
private typealias PlatformRepresentable = UIViewRepresentable
private typealias EditorWebView = WKWebView
#endif

private struct Representable: PlatformRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let isEditable: Bool
    let fontSize: CGFloat
    let minHeight: CGFloat
    let placeholder: String
    let onEndEditing: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // "lezin" is the name the runtime posts to; "tasks" carries this view's own reports.
        configuration.userContentController.add(WeakHandler(coordinator), name: "lezin")
        configuration.userContentController.add(WeakHandler(coordinator), name: "tasks")
        configuration.userContentController.addUserScript(
            WKUserScript(source: Self.reportScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let webView = EditorWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = coordinator
        #if os(macOS)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        #else
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        #endif
        coordinator.webView = webView
        if let url = Bundle.main.url(forResource: "preview", withExtension: "html", subdirectory: "RichEditorWeb") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update(self) }
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.update(self) }
    #endif

    /// Reports the content's height, every edit, and the cursor leaving the page.
    private static let reportScript = """
    (function () {
      const post = (message) => window.webkit.messageHandlers.tasks.postMessage(message);
      const size = () => post({ type: "height", height: Math.ceil(document.body.getBoundingClientRect().height) });
      new ResizeObserver(size).observe(document.body);
      document.addEventListener("input", () => post({ type: "edited" }), true);
      document.addEventListener("change", () => post({ type: "edited" }), true);
      document.addEventListener("focusout", () => post({ type: "blur" }), true);
      size();
    })();
    """

    /// The page's look: the app's colours, no margins of its own, text at the given size.
    fileprivate var themeCSS: String {
        """
        :root { color-scheme: light dark; --lezin-text: #1f2328; --lezin-accent: #2563eb; }
        @media (prefers-color-scheme: dark) { :root { --lezin-text: #e4e8f1; --lezin-accent: #7fb0ff; } }
        html, body { background: transparent !important; overflow: hidden; }
        body { padding: 0 2px 6px !important; font-size: \(Int(fontSize))px; }
        [data-lezin-root] { max-width: none !important; margin: 0 !important; min-height: \(Int(minHeight) - 8)px; }
        [data-lezin-root] > :first-child { margin-top: 0 !important; }
        [data-lezin-root]:empty::before { content: attr(data-placeholder); opacity: 0.4; }
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: Representable
        weak var webView: WKWebView?
        private var isReady = false
        /// The Markdown the page shows now: what was rendered last, or what it last gave back.
        private var shown: String?
        private var pendingRead: Task<Void, Never>?

        init(_ parent: Representable) { self.parent = parent }

        @MainActor func update(_ parent: Representable) {
            let editableChanged = parent.isEditable != self.parent.isEditable
            self.parent = parent
            guard isReady else { return }
            if parent.text != shown { render() } else if editableChanged { applyEditable() }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            Task { @MainActor in
                switch type {
                case "ready":
                    self.isReady = true
                    self.render()
                case "height":
                    if let height = body["height"] as? Double, abs(self.parent.height - height) > 0.5 { self.parent.height = height }
                case "edited":
                    self.scheduleRead()
                case "dirtyChanged":
                    if body["dirty"] as? Bool == true { self.scheduleRead() }
                case "blur":
                    await self.read()
                    // Markdown typed as text (a "## " or "- [ ]") becomes what it means.
                    self.render()
                    self.parent.onEndEditing()
                case "linkActivated":
                    if let raw = body["url"] as? String, let url = URL(string: raw), ["http", "https", "mailto"].contains(url.scheme ?? "") {
                        #if os(macOS)
                        NSWorkspace.shared.open(url)
                        #else
                        await UIApplication.shared.open(url)
                        #endif
                    }
                default: break
                }
            }
        }

        /// Puts the binding's Markdown on the page.
        @MainActor private func render() {
            guard let webView else { return }
            let markdown = parent.text
            shown = markdown
            pendingRead?.cancel()
            let script = """
            let style = document.getElementById("tasks-theme");
            if (!style) { style = document.createElement("style"); style.id = "tasks-theme"; document.head.appendChild(style); }
            style.textContent = css;
            document.querySelector("[data-lezin-root]").dataset.placeholder = placeholder;
            await window.lezinBridge.renderMarkdown(markdown, options);
            window.lezinBridge.setEditable(editable);
            """
            let options: [String: Any] = [
                "frontmatter": false, "template": false,
                "enabledPlugins": ["sanitize", "autolink", "gfm", "task-list"],
                "pluginOptions": ["task-list": ["mode": parent.isEditable ? "edit" : "view"]],
            ]
            webView.callAsyncJavaScript(script, arguments: [
                "css": parent.themeCSS, "placeholder": parent.placeholder, "markdown": markdown,
                "options": options, "editable": parent.isEditable,
            ], in: nil, in: .page) { _ in }
        }

        @MainActor private func applyEditable() {
            webView?.callAsyncJavaScript("window.lezinBridge.setEditable(editable)", arguments: ["editable": parent.isEditable],
                                         in: nil, in: .page) { _ in }
        }

        /// A moment after the last keystroke, not on each one: reading the page back costs a conversion.
        @MainActor private func scheduleRead() {
            pendingRead?.cancel()
            pendingRead = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await self?.read()
            }
        }

        /// Reads the page back as Markdown into the binding.
        @MainActor private func read() async {
            pendingRead?.cancel()
            guard isReady, parent.isEditable, let webView else { return }
            let script = """
            const html = window.lezinBridge.getCleanHtml();
            window.lezinBridge.markClean();
            return window.lezinBridge.htmlToMarkdown(html).markdown;
            """
            guard let value = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page),
                  let markdown = value as? String else { return }
            let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
            // Nothing typed since it was rendered: the binding keeps the text exactly as it was written.
            guard trimmed != (shown ?? "").trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            shown = trimmed
            parent.text = trimmed
        }
    }
}

/// The content controller holds its handlers strongly; this keeps the coordinator free to go.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
