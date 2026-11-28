import GitKanbanKit
import GitKittieKit
import SwiftUI
import WebKit

// The web view of a browser check (ReviewSpec § 3.4, § 3.5), the same on the Mac and the
// iPhone: the page at an exact viewport in CSS pixels, in a forced light or dark appearance
// (what the page's `prefers-color-scheme` sees), with the user agent the size asks for, and a
// screenshot of what it shows.
//
// A viewport larger than the space on screen keeps its true layout size and is drawn smaller
// (`CheckViewportLayout.scale`):
// - Mac: the web view takes the smaller size and its `pageZoom` makes up the difference, so the
//   page lays out at the true width (as when zooming out in Safari) and WebKit itself maps
//   clicks. `CheckWebViewTests` checks `innerWidth` and that a click lands on its element.
// - iPhone / iPad: the web view takes the true size and is scaled down with a transform, so
//   `device-width` is the true width; UIKit maps touches through the transform.
//   `ReviewCheckUITests` taps a button in a scaled page.

/// What a screen asks of a check's web view, and what the view reports back.
@MainActor
@Observable
final class CheckWebController {
    @ObservationIgnored fileprivate(set) weak var webView: WKWebView?
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// The address on show (it can differ from the check's after a link was followed).
    private(set) var currentURL: URL?
    /// Why the page did not load, when it did not.
    private(set) var loadError: String?
    /// The CSS width of the viewport, for a screenshot at full layout width.
    @ObservationIgnored fileprivate var cssWidth: CGFloat = 0

    func reload() { webView?.reload() }
    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }

    /// Run JavaScript in the page (`innerWidth`, a test's checks).
    func evaluate(_ script: String) async -> Any? {
        guard let webView else { return nil }
        // The completion-handler form: the async one traps on a script whose value is undefined.
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result) }
        }
    }

    /// A PNG of the viewport, at its full layout width and the screen's scale.
    func screenshotPNG() async -> Data? {
        guard let webView else { return nil }
        let configuration = WKSnapshotConfiguration()
        if cssWidth > 0 { configuration.snapshotWidth = NSNumber(value: Double(cssWidth)) }
        #if os(macOS)
        guard let image = try? await webView.takeSnapshot(configuration: configuration),
              let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
        #else
        guard let image = try? await webView.takeSnapshot(configuration: configuration) else { return nil }
        return image.pngData()
        #endif
    }

    fileprivate func update(from webView: WKWebView) {
        isLoading = webView.isLoading
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        currentURL = webView.url ?? currentURL
    }

    fileprivate func failed(_ error: Error) {
        let code = (error as NSError).code
        // A navigation replaced by another is not a failure.
        guard code != NSURLErrorCancelled else { return }
        loadError = error.localizedDescription
    }

    fileprivate func started() { loadError = nil }
}

enum CheckUserAgents {
    static let iPhone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static let iPad = "Mozilla/5.0 (iPad; CPU OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static let mac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// The user agent a size asks for: a phone's or tablet's Safari for `mobile`, the Mac's for
    /// `desktop`; `nil` (WebKit's own) for `default`.
    static func forSize(_ size: CheckSize) -> String? {
        switch size.ua {
        case .mobile: return (size.width ?? 0) >= 700 ? iPad : iPhone
        case .desktop: return mac
        case .default: return nil
        }
    }
}

/// Whether the system (not this app, which may force its own look) is in dark mode: what a page
/// sees when the check lists no appearance.
@MainActor
enum SystemAppearance {
    static var isDark: Bool {
        #if os(macOS)
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        #else
        return UIScreen.main.traitCollection.userInterfaceStyle == .dark
        #endif
    }
}

#if os(macOS)
struct CheckWebView: NSViewRepresentable {
    let url: URL
    let layout: CheckViewportLayout
    let appearance: CheckAppearance?
    let userAgent: String?
    let controller: CheckWebController

    func makeCoordinator() -> CheckWebCoordinator { CheckWebCoordinator(controller: controller) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: CGRect(origin: .zero, size: layout.shown), configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        controller.webView = webView
        configure(webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        configure(webView, coordinator: context.coordinator)
    }

    private func configure(_ webView: WKWebView, coordinator: CheckWebCoordinator) {
        // Shown smaller than its layout size: the page zooms out, so it still lays out at the
        // true width and WebKit maps clicks itself.
        let zoom = layout.css.width > 0 ? layout.shown.width / layout.css.width : 1
        if abs(webView.pageZoom - zoom) > 0.0001 { webView.pageZoom = zoom }
        let dark = appearance.map { $0 == .dark } ?? SystemAppearance.isDark
        let wanted = NSAppearance(named: dark ? .darkAqua : .aqua)
        if webView.appearance?.name != wanted?.name { webView.appearance = wanted }
        controller.cssWidth = layout.css.width
        coordinator.load(url, userAgent: userAgent, in: webView)
    }
}
#else
struct CheckWebView: UIViewRepresentable {
    let url: URL
    let layout: CheckViewportLayout
    let appearance: CheckAppearance?
    let userAgent: String?
    let controller: CheckWebController

    func makeCoordinator() -> CheckWebCoordinator { CheckWebCoordinator(controller: controller) }

    func makeUIView(context: Context) -> CheckWebContainer {
        let webView = WKWebView(frame: CGRect(origin: .zero, size: layout.css), configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        let container = CheckWebContainer(webView: webView)
        controller.webView = webView
        configure(container, coordinator: context.coordinator)
        return container
    }

    func updateUIView(_ container: CheckWebContainer, context: Context) {
        configure(container, coordinator: context.coordinator)
    }

    private func configure(_ container: CheckWebContainer, coordinator: CheckWebCoordinator) {
        container.layout = layout
        let dark = appearance.map { $0 == .dark } ?? SystemAppearance.isDark
        let style: UIUserInterfaceStyle = dark ? .dark : .light
        if container.webView.overrideUserInterfaceStyle != style { container.webView.overrideUserInterfaceStyle = style }
        controller.cssWidth = layout.css.width
        coordinator.load(url, userAgent: userAgent, in: container.webView)
    }
}

/// Holds the web view at its true viewport size and scales it down to the space it is given.
final class CheckWebContainer: UIView {
    let webView: WKWebView
    var layout: CheckViewportLayout? { didSet { if layout != oldValue { setNeedsLayout() } } }

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clipsToBounds = true
        addSubview(webView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let layout else { return }
        // Native: the page fills the space it is given, at the device's own viewport.
        let css = layout.isNative ? bounds.size : layout.css
        let scale = layout.isNative || css.width == 0 ? 1 : bounds.width / css.width
        webView.transform = .identity
        webView.frame = CGRect(origin: .zero, size: css)
        webView.transform = CGAffineTransform(scaleX: scale, y: scale)
        webView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
#endif

/// Loads the check's address (again when it or the user agent changes) and reports navigation.
final class CheckWebCoordinator: NSObject, WKNavigationDelegate {
    private let controller: CheckWebController
    private var loaded: URL?
    private var agent: String??

    init(controller: CheckWebController) { self.controller = controller }

    @MainActor
    func load(_ url: URL, userAgent: String?, in webView: WKWebView) {
        let agentChanged = agent != .some(userAgent)
        if agentChanged { webView.customUserAgent = userAgent; agent = .some(userAgent) }
        guard loaded != url else {
            // Another size asks for another user agent: the page is asked for again with it.
            if agentChanged, webView.url != nil { webView.reload() }
            return
        }
        loaded = url
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            controller.started()
            controller.update(from: webView)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { controller.update(from: webView) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            controller.failed(error)
            controller.update(from: webView)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            controller.failed(error)
            controller.update(from: webView)
        }
    }
}
