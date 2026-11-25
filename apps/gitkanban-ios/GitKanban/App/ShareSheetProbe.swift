#if DEBUG
import UIKit
import UniformTypeIdentifiers

/// Test hook: launch with `-shareSheetProbe <kind>` and the app opens the system share
/// sheet on one way another app can share an image (or not an image), so
/// `UITests/ShareTargetUITests` can check that Tasks is offered exactly when it should be.
/// The share sheet decides from the extensions' `NSExtensionActivationRule`, which only
/// sees the type identifiers each representation registers, so every kind here is a real
/// shape seen from other apps, not a stand-in.
enum ShareSheetProbe {
    static var kind: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-shareSheetProbe"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @MainActor
    static func presentIfRequested() {
        guard let kind, let items = items(for: kind) else { return }
        guard var root = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow?.rootViewController }).first else { return }
        while let presented = root.presentedViewController { root = presented }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = root.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1)
        root.present(sheet, animated: false)
    }

    /// The activity items for a kind; nil for an unknown kind.
    static func items(for kind: String) -> [Any]? {
        let image = sampleImage()
        guard let png = image.pngData(), let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
        switch kind {
        case "uiimage": return [image]
        case "png-data": return [png]
        case "jpeg-data": return [jpeg]
        case "png-file": return file("probe.png", png).map { [$0] }
        case "jpeg-file": return file("probe.jpg", jpeg).map { [$0] }
        // A file named without an image extension: registered as `dyn.…` + `public.file-url`.
        case "file-without-extension": return file("file-7a1c2e", png).map { [$0] }
        // An item source that says only "data": registered as `public.data`.
        case "untyped-data": return [UntypedItem(data: png)]
        case "link-and-image": return [URL(string: "https://chatgpt.com/c/probe")!, image]
        case "text-and-image": return ["Look at this", image]
        case "text": return ["Just some text"]
        case "link": return [URL(string: "https://example.com")!]
        case "text-and-link": return ["Read this", URL(string: "https://example.com")!]
        case "pdf-file": return file("probe.pdf", pdf()).map { [$0] }
        default: return nil
        }
    }

    /// Hands the share sheet image bytes declared only as `public.data`.
    private final class UntypedItem: NSObject, UIActivityItemSource {
        let data: Data
        init(data: Data) { self.data = data }
        func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { data }
        func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? { data }
        func activityViewController(_ controller: UIActivityViewController, dataTypeIdentifierForActivityType type: UIActivity.ActivityType?) -> String {
            UTType.data.identifier
        }
    }

    private static func sampleImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
    }

    private static func pdf() -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 200, height: 200)).pdfData { context in
            context.beginPage()
            ("Probe" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: nil)
        }
    }

    private static func file(_ name: String, _ data: Data) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try data.write(to: url) } catch { return nil }
        return url
    }
}
#endif
