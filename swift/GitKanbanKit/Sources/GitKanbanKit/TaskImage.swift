import CoreGraphics
import CoreText
import Foundation
import GitKittieKit
import ImageIO
import UniformTypeIdentifiers

/// A region the user marked on a screenshot, with their comment. `rect` is normalized
/// (0…1, top-left origin) so it holds at any display or pixel size.
public struct ImageAnnotation: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var rect: CGRect
    public var comment: String

    public init(id: UUID = UUID(), rect: CGRect, comment: String) {
        self.id = id
        self.rect = rect
        self.comment = comment
    }
}

/// An image a task is being made from — shared from another app on iOS, dropped on the
/// board on the Mac — with the marks made on it, ready to be written as a card attachment.
///
/// Platform-neutral (Core Graphics and Image I/O only) so the iPhone's share sheet and the
/// Mac's board make the same files.
public struct TaskImage: Identifiable, Sendable {
    public let id: UUID
    public let data: Data
    /// `png` or `jpg`: the two formats the board contract asks for.
    public let fileExtension: String
    public var annotations: [ImageAnnotation]

    public init(id: UUID = UUID(), data: Data, fileExtension: String, annotations: [ImageAnnotation] = []) {
        self.id = id
        self.data = data
        self.fileExtension = fileExtension
        self.annotations = annotations
    }

    public var mimeType: String { fileExtension == "png" ? "image/png" : "image/jpeg" }

    /// The image's size in pixels, read from its header without decoding it.
    public var pixelSize: CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: width, height: height)
    }

    // MARK: Reading images in

    /// The image in `data` as an attachment: PNG and JPEG are kept as they are (the board
    /// contract asks for those two); anything else, such as HEIC or TIFF, is re-encoded as
    /// JPEG so every client can show it. `nil` when `data` is not an image.
    public static func from(_ data: Data) -> TaskImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let typeID = CGImageSourceGetType(source) as String?,
              let type = UTType(typeID) else { return nil }
        if type.conforms(to: .png) { return TaskImage(data: data, fileExtension: "png") }
        if type.conforms(to: .jpeg) { return TaskImage(data: data, fileExtension: "jpg") }
        guard let image = oriented(source), let jpeg = encode(image, as: .jpeg, quality: 0.85) else { return nil }
        return TaskImage(data: jpeg, fileExtension: "jpg")
    }

    /// The image file at `url`, or `nil` when it is not an image or cannot be read.
    public static func from(fileURL url: URL) -> TaskImage? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return from(data)
    }

    /// Whether a drag or share offers something `load(from:)` can read: image data, or a
    /// file (which is checked to be an image when it is read).
    public static func canLoad(from providers: [NSItemProvider]) -> Bool {
        providers.contains(where: isCandidate)
    }

    private static func isCandidate(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
    }

    /// Every image from a share sheet's or a drop's item providers, in order. Providers
    /// that hold no image (a dragged PDF, a URL) are skipped.
    @MainActor
    public static func load(from providers: [NSItemProvider]) async -> [TaskImage] {
        var images: [TaskImage] = []
        for provider in providers where isCandidate(provider) {
            if let image = await load(provider) { images.append(image) }
        }
        return images
    }

    @MainActor
    private static func load(_ provider: NSItemProvider) async -> TaskImage? {
        // The image as it is, when the provider offers PNG or JPEG bytes.
        for type in [UTType.png, .jpeg] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await data(from: provider, type: type), let image = from(data) { return image }
        }
        // A file: dragged from Finder, the desktop or the screenshot thumbnail.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await fileURL(from: provider), let image = from(fileURL: url) {
            return image
        }
        // Image data in another format (TIFF from another app, HEIC from Photos).
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await data(from: provider, type: .image) {
            return from(data)
        }
        return nil
    }

    @MainActor
    private static func data(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    @MainActor
    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                let url = data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                continuation.resume(returning: url?.isFileURL == true ? url : nil)
            }
        }
    }

    // MARK: Writing images out

    /// Above this size a PNG is sent as JPEG instead: a full-screen PNG is several MB,
    /// which is slow to upload and over the board's 2 MB guideline for attachments.
    public static let largeImageBytes = 1_200_000

    /// What to attach: the image itself, with the numbered annotation boxes drawn on it
    /// when there are any, as JPEG when the original is large.
    public func attachment() -> (data: Data, fileExtension: String) {
        let untouched = annotations.isEmpty && data.count <= Self.largeImageBytes
        guard !untouched, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = Self.oriented(source) else { return (data, fileExtension) }
        let rendered = annotations.isEmpty ? image : (Self.draw(annotations, on: image) ?? image)
        if fileExtension == "png", data.count <= Self.largeImageBytes, let png = Self.encode(rendered, as: .png) {
            return (png, "png")
        }
        guard let jpeg = Self.encode(rendered, as: .jpeg, quality: 0.85) else { return (data, fileExtension) }
        return (jpeg, "jpg")
    }

    /// A smaller JPEG (annotations included) for a cloud model to look at.
    public func analysisAttachment() -> AIImageAttachment? {
        guard let small = Self.downsampled(data, maxPixel: 1568) else { return nil }
        let image = annotations.isEmpty ? small : (Self.draw(annotations, on: small) ?? small)
        guard let jpeg = Self.encode(image, as: .jpeg, quality: 0.8) else { return nil }
        return AIImageAttachment(data: jpeg, mimeType: "image/jpeg")
    }

    /// The file name an image gets on a card: `screenshot-<stamp>.png`, numbered when a
    /// task gets more than one.
    public static func attachmentName(stamp: String, index: Int, count: Int, fileExtension: String) -> String {
        "screenshot-\(stamp)\(count > 1 ? "-\(index + 1)" : "").\(fileExtension)"
    }

    /// The stamp in attachment names: `yyyyMMdd-HHmmss`.
    public static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    // MARK: Pixels

    /// The colour of the marks: on screen while marking, and drawn into the attachment.
    public static let annotationColor = CGColor(srgbRed: 0.93, green: 0.2, blue: 0.25, alpha: 1)

    /// A downsampled, upright copy: the full image is never decoded just to show it.
    public static func downsampled(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The full image, turned upright when its metadata says it was taken rotated.
    private static func oriented(_ source: CGImageSource) -> CGImage? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        guard orientation != 1 else { return CGImageSourceCreateImageAtIndex(source, 0, nil) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double? = nil) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// The image with each annotation drawn on it: a rounded box and a numbered badge on
    /// its top-left corner, kept inside the image.
    static func draw(_ annotations: [ImageAnnotation], on image: CGImage) -> CGImage? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = CGSize(width: width, height: height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        let line = max(3, max(size.width, size.height) / 320)
        let badge = line * 9
        // Annotations are top-left based; Core Graphics counts from the bottom.
        func flipped(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX, y: size.height - rect.maxY, width: rect.width, height: rect.height)
        }
        for (index, annotation) in annotations.enumerated() {
            let rect = CGRect(x: annotation.rect.minX * size.width, y: annotation.rect.minY * size.height,
                              width: annotation.rect.width * size.width, height: annotation.rect.height * size.height)
            context.setStrokeColor(annotationColor)
            context.setLineWidth(line)
            context.addPath(CGPath(roundedRect: flipped(rect), cornerWidth: line * 2, cornerHeight: line * 2, transform: nil))
            context.strokePath()

            var circle = CGRect(x: rect.minX - badge / 2, y: rect.minY - badge / 2, width: badge, height: badge)
            circle.origin.x = min(max(circle.origin.x, 0), size.width - badge)
            circle.origin.y = min(max(circle.origin.y, 0), size.height - badge)
            let badgeRect = flipped(circle)
            context.setFillColor(annotationColor)
            context.fillEllipse(in: badgeRect)

            let font = CTFontCreateUIFontForLanguage(.emphasizedSystem, badge * 0.6, nil)
                ?? CTFontCreateWithName("Helvetica-Bold" as CFString, badge * 0.6, nil)
            let text = NSAttributedString(string: "\(index + 1)", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
            ])
            let ctLine = CTLineCreateWithAttributedString(text)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let textWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: badgeRect.midX - textWidth / 2, y: badgeRect.midY - (ascent - descent) / 2)
            CTLineDraw(ctLine, context)
        }
        return context.makeImage()
    }
}
