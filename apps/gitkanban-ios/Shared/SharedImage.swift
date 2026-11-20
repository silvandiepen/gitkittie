import GitKittieKit
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A region the user marked on a screenshot, with their comment. `rect` is normalized
/// (0…1, top-left origin) so it holds at any display or pixel size.
struct ImageAnnotation: Identifiable, Equatable {
    let id = UUID()
    var rect: CGRect
    var comment: String
}

/// An image handed to the share extension, ready to be written as a card attachment.
struct SharedImage: Identifiable {
    let id = UUID()
    let data: Data
    let fileExtension: String
    let thumbnail: UIImage?
    var annotations: [ImageAnnotation] = []

    var mimeType: String { fileExtension == "png" ? "image/png" : "image/jpeg" }

    /// The image's size in pixels, read from its header without decoding it.
    var pixelSize: CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: width, height: height)
    }

    /// Load every image from the share sheet's item providers, in order.
    @MainActor
    static func load(from providers: [NSItemProvider]) async -> [SharedImage] {
        var images: [SharedImage] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            if let image = await load(provider) { images.append(image) }
        }
        return images
    }

    @MainActor
    private static func load(_ provider: NSItemProvider) async -> SharedImage? {
        // Keep PNG and JPEG as they are (the board contract asks for those two); anything
        // else, such as HEIC, is re-encoded as JPEG so every client can show it.
        for (type, ext) in [(UTType.png, "png"), (UTType.jpeg, "jpg")]
        where provider.hasItemConformingToTypeIdentifier(type.identifier) {
            if let data = await data(from: provider, type: type) {
                return SharedImage(data: data, fileExtension: ext, thumbnail: downsampled(data, maxPixel: 480))
            }
        }
        guard let raw = await data(from: provider, type: .image),
              let jpeg = UIImage(data: raw)?.jpegData(compressionQuality: 0.85) else { return nil }
        return SharedImage(data: jpeg, fileExtension: "jpg", thumbnail: downsampled(jpeg, maxPixel: 480))
    }

    @MainActor
    private static func data(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// A downsampled copy: the extension has a tight memory budget, so the full image is
    /// never decoded just to show it.
    static func downsampled(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    /// The bytes to attach: the image itself, or with the numbered annotation boxes drawn
    /// on it when there are any.
    /// Above this size a PNG is sent as JPEG instead: a full-screen PNG is several MB,
    /// which is slow to upload and over the board's 2 MB guideline for attachments.
    private static let largeImageBytes = 1_200_000

    /// What to attach: the image itself, with the numbered annotation boxes drawn on it
    /// when there are any, as JPEG when the original is large.
    func attachment() -> (data: Data, fileExtension: String) {
        let untouched = annotations.isEmpty && data.count <= Self.largeImageBytes
        guard !untouched, let image = UIImage(data: data) else { return (data, fileExtension) }
        let rendered = annotations.isEmpty ? image : Self.draw(annotations, on: image)
        if fileExtension == "png", data.count <= Self.largeImageBytes, let png = rendered.pngData() {
            return (png, "png")
        }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.85) else { return (data, fileExtension) }
        return (jpeg, "jpg")
    }

    /// A smaller JPEG (annotations included) for a cloud model to look at.
    func analysisAttachment() -> AIImageAttachment? {
        guard let small = Self.downsampled(data, maxPixel: 1568) else { return nil }
        let image = annotations.isEmpty ? small : Self.draw(annotations, on: small)
        guard let jpeg = image.jpegData(compressionQuality: 0.8) else { return nil }
        return AIImageAttachment(data: jpeg, mimeType: "image/jpeg")
    }

    static let annotationColor = UIColor(red: 0.93, green: 0.2, blue: 0.25, alpha: 1)

    private static func draw(_ annotations: [ImageAnnotation], on image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let line = max(3, max(size.width, size.height) / 320)
        let badge = line * 9
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            for (index, annotation) in annotations.enumerated() {
                let rect = CGRect(x: annotation.rect.minX * size.width, y: annotation.rect.minY * size.height,
                                  width: annotation.rect.width * size.width, height: annotation.rect.height * size.height)
                annotationColor.setStroke()
                let box = UIBezierPath(roundedRect: rect, cornerRadius: line * 2)
                box.lineWidth = line
                box.stroke()

                // Numbered badge on the box's top-left corner, kept inside the image.
                var circle = CGRect(x: rect.minX - badge / 2, y: rect.minY - badge / 2, width: badge, height: badge)
                circle.origin.x = min(max(circle.origin.x, 0), size.width - badge)
                circle.origin.y = min(max(circle.origin.y, 0), size.height - badge)
                annotationColor.setFill()
                context.cgContext.fillEllipse(in: circle)
                let number = "\(index + 1)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: badge * 0.6, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
                let textSize = number.size(withAttributes: attributes)
                number.draw(at: CGPoint(x: circle.midX - textSize.width / 2, y: circle.midY - textSize.height / 2),
                            withAttributes: attributes)
            }
        }
    }
}
