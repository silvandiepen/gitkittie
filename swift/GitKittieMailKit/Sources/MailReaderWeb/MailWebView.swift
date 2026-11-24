import Foundation
import MailHTML
import WebKit

/// The bytes of one inline part, served to the web view under `gkm-mail://message/cid/<id>`.
public struct InlinePart: Sendable {
    public var mediaType: String
    public var data: Data
    public init(mediaType: String, data: Data) {
        self.mediaType = mediaType
        self.data = data
    }
}

/// The locked-down web view the reader shows HTML mail in (ThreatModel §1). Four layers, each
/// enough on its own to stop a remote load:
///
/// 1. MailHTML's sanitizer removes scripts, frames, forms, event handlers and remote references.
/// 2. JavaScript is off for content (`allowsContentJavaScript = false`) and no script message
///    handler exists, so there is no bridge into the app.
/// 3. A content rule list blocks every load except the reader's own `gkm-mail:` scheme (and,
///    when the user allowed it, `http(s)` images only), and the document carries a
///    `default-src 'none'` Content-Security-Policy, as a meta tag and a response header.
/// 4. The navigation delegate allows exactly one navigation, the message document itself, and
///    turns link clicks into a callback; the web view never navigates anywhere.
///
/// It uses a non-persistent data store: no cookies, cache or storage outlive the view.
@MainActor
public final class MailWebView: WKWebView {
    /// Called with the index of a clicked link (`HTMLLink.index`). The app shows the real
    /// destination; nothing opens unless the user confirms there.
    public var onLinkActivated: ((Int) -> Void)?
    /// Called once the document has finished loading, with its content height in points.
    public var onContentHeight: ((CGFloat) -> Void)?

    private let guardDelegate = NavigationGuard()
    private let schemeHandler: PartSchemeHandler

    /// Makes a web view. `ruleLists` come from `MailWebView.ruleLists()`, compiled once.
    public init(ruleLists: RuleLists, allowRemoteImages: Bool) {
        let handler = PartSchemeHandler()
        schemeHandler = handler
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(handler, forURLScheme: ReaderURLs.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.suppressesIncrementalRendering = true
        configuration.userContentController.add(allowRemoteImages ? ruleLists.remoteImagesOnly : ruleLists.blockAll)
        #if os(iOS)
        // No phone numbers, addresses or dates turned into tappable links the sanitizer never saw.
        configuration.dataDetectorTypes = []
        #endif
        super.init(frame: .zero, configuration: configuration)
        navigationDelegate = guardDelegate
        uiDelegate = guardDelegate
        allowsBackForwardNavigationGestures = false
        allowsLinkPreview = false
        #if os(macOS)
        allowsMagnification = true
        #endif
        guardDelegate.owner = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows a sanitized document. Only this document may load; everything it refers to comes
    /// from `parts` (inline images) or, with remote images allowed, from `http(s)` images.
    public func show(_ html: SanitizedHTML, parts: [String: InlinePart]) {
        schemeHandler.document = Data(html.document.utf8)
        schemeHandler.contentSecurityPolicy = html.contentSecurityPolicy
        schemeHandler.parts = parts
        guardDelegate.documentAllowed = true
        load(URLRequest(url: URL(string: ReaderURLs.document)!))
    }

    #if os(macOS)
    /// Context menu items kept: reading actions only. No "Open Link", "Download Image",
    /// "Open Image in New Window" or "Reload".
    static let keptMenuItems: Set<String> = [
        "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp", "WKMenuItemIdentifierTranslate",
        "WKMenuItemIdentifierSearchWeb", "WKMenuItemIdentifierShareMenu", "WKMenuItemIdentifierSpeechMenu",
    ]

    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.items.removeAll { item in
            guard let identifier = item.identifier?.rawValue else { return false }
            return !Self.keptMenuItems.contains(identifier)
        }
        super.willOpenMenu(menu, with: event)
    }
    #endif

    // MARK: Content rule lists

    /// The compiled rule lists. Compile once per app run and share.
    public struct RuleLists {
        public let blockAll: WKContentRuleList
        public let remoteImagesOnly: WKContentRuleList
    }

    /// Block every load (any scheme, any resource type) except `gkm-mail:`.
    public static let blockAllRules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^gkm-mail:"},"action":{"type":"ignore-previous-rules"}}]
        """

    /// As `blockAllRules`, but `http(s)` images may load (the user chose "Load remote images").
    public static let remoteImagesRules = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^gkm-mail:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^https?://","resource-type":["image"]},"action":{"type":"ignore-previous-rules"}}]
        """

    public static func ruleLists(store: WKContentRuleListStore? = nil) async throws -> RuleLists {
        guard let store = store ?? WKContentRuleListStore.default() else { throw MailWebViewError.ruleListFailed }
        let blockAll = try await compile(store, "gkm-mail-block-all-v1", blockAllRules)
        let images = try await compile(store, "gkm-mail-remote-images-v1", remoteImagesRules)
        return RuleLists(blockAll: blockAll, remoteImagesOnly: images)
    }

    private static func compile(_ store: WKContentRuleListStore, _ identifier: String, _ rules: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { list, error in
                if let list { continuation.resume(returning: list) } else { continuation.resume(throwing: error ?? MailWebViewError.ruleListFailed) }
            }
        }
    }

    // MARK: Delegates

    fileprivate func linkActivated(_ index: Int) { onLinkActivated?(index) }

    fileprivate func didFinishDocument() {
        guard onContentHeight != nil else { return }
        // Measured with an app-side script, which runs even though content scripts are off.
        evaluateJavaScript("document.documentElement.scrollHeight", in: nil, in: .defaultClient) { [weak self] result in
            if case .success(let value) = result, let height = value as? Double { self?.onContentHeight?(CGFloat(height)) }
        }
    }
}

public enum MailWebViewError: Error { case ruleListFailed }

/// Allows the message document and nothing else; reports link clicks; refuses new windows,
/// downloads and every other navigation.
@MainActor
final class NavigationGuard: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var owner: MailWebView?
    /// Set by `show(_:)`: the one load the guard lets through.
    var documentAllowed = false

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = false
        decisionHandler(policy(for: action), preferences)
    }

    func policy(for action: WKNavigationAction) -> WKNavigationActionPolicy {
        let url = action.request.url
        if action.targetFrame?.isMainFrame == true, url?.absoluteString == ReaderURLs.document, documentAllowed,
           action.navigationType == .other || action.navigationType == .reload {
            documentAllowed = false
            return .allow
        }
        if let url, let index = ReaderURLs.linkIndex(in: url), action.navigationType == .linkActivated {
            owner?.linkActivated(index)
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.response.url?.absoluteString == ReaderURLs.document && response.canShowMIMEType ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        owner?.didFinishDocument()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url, let index = ReaderURLs.linkIndex(in: url) { owner?.linkActivated(index) }
        return nil
    }

    #if os(iOS)
    /// No long-press menu or link preview on iOS (the macOS menu is trimmed in `willOpenMenu`):
    /// its "Open" and "Open in New Tab" would bypass the app's link check. Text selection and
    /// copy stay available through the selection menu.
    func webView(_ webView: WKWebView, contextMenuConfigurationFor elementInfo: WKContextMenuElementInfo) async -> UIContextMenuConfiguration? {
        nil
    }
    #endif
}

/// Serves the reader's scheme: the sanitized document (with its CSP as a header) and the
/// message's inline images. Anything else is a 404. Never reads the file system or network.
@MainActor
final class PartSchemeHandler: NSObject, WKURLSchemeHandler {
    var document = Data()
    var contentSecurityPolicy = ""
    var parts: [String: InlinePart] = [:]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return task.didFailWithError(URLError(.badURL)) }
        let body: Data
        let type: String
        if url.absoluteString == ReaderURLs.document {
            body = document
            type = "text/html; charset=utf-8"
        } else if let cid = ReaderURLs.contentID(in: url), let part = parts[cid], part.mediaType.lowercased().hasPrefix("image/"),
                  part.mediaType.lowercased() != "image/svg+xml" {
            body = part.data
            type = part.mediaType
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
            task.didReceive(response)
            task.didFinish()
            return
        }
        let headers = [
            "Content-Type": type, "Content-Length": String(body.count), "Content-Security-Policy": contentSecurityPolicy,
            "X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer", "Cache-Control": "no-store",
        ]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(body)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
