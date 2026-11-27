import GitKanbanKit
import GitKittieKit
import ImageIO
import SwiftUI
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

// Pictures in a review request: the files under review and the pictures in its notes.
// Shared by the Mac and iPhone apps. A long request holds dozens of large screenshots;
// each is decoded off the main thread at the size it is shown, once, and kept, so
// scrolling neither stalls on a decode nor loads a picture again when it comes back.

enum ReviewImageDecoder {
    /// Decodes a picture no larger than `maxPixel` on its longest side, away from the main
    /// thread. A full-size decode of every image in a request is what stalls scrolling and,
    /// on iPhone, runs the app out of memory.
    static func image(from data: Data, maxPixel: Int) async -> PlatformImage? {
        let cgImage = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let cgImage else { return nil }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}

/// Decoded review pictures, by request, file and size. Pictures of a request never change
/// under the same name (a redo is a new file), so a decoded one is good until memory is short.
@MainActor
enum ReviewImageCache {
    private static let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        // About 60 screen-sized pictures.
        cache.totalCostLimit = 300 * 1024 * 1024
        return cache
    }()

    private static func key(_ request: ReviewRequest, _ file: String, _ maxPixel: Int) -> NSString {
        "\(request.ref.id)/\(file)@\(maxPixel)" as NSString
    }

    /// The picture if it is decoded already: drawn at once, without a placeholder in between.
    static func cached(_ request: ReviewRequest, file: String, maxPixel: Int) -> PlatformImage? {
        cache.object(forKey: key(request, file, maxPixel))
    }

    static func load(_ model: AppModel, _ request: ReviewRequest, file: String, maxPixel: Int) async -> PlatformImage? {
        if let hit = cached(request, file: file, maxPixel: maxPixel) { return hit }
        guard let data = await model.assetData(request, file: file),
              let image = await ReviewImageDecoder.image(from: data, maxPixel: maxPixel) else { return nil }
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let pixels = Int(image.size.width * image.size.height)
        #else
        let pixels = Int(image.size.width * image.size.height * image.scale * image.scale)
        #endif
        cache.setObject(image, forKey: key(request, file, maxPixel), cost: pixels * 4)
        return image
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

/// A picture of a review request, loaded through the board's source (folders, the folder
/// server and provider repositories alike), decoded at the size it is shown.
struct ReviewImage: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    let file: String
    /// The longest side to decode to, in pixels.
    var maxPixel = 1600
    @State private var image: PlatformImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let shown = image ?? ReviewImageCache.cached(request, file: file, maxPixel: maxPixel) {
                Image(platformImage: shown).resizable().scaledToFit()
            } else if failed {
                // Say which file: a request that points outside its folder (`../../art/…`)
                // otherwise shows a wall of identical broken pictures.
                VStack(spacing: 6) {
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: 32)).foregroundStyle(.tertiary)
                    Text("Can't load \(file)").font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).lineLimit(3).truncationMode(.middle)
                        .padding(.horizontal, 10)
                }
                .accessibilityElement(children: .combine)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(request.ref.id)/\(file)@\(maxPixel)") {
            guard image == nil else { return }
            if let loaded = await ReviewImageCache.load(model, request, file: file, maxPixel: maxPixel) {
                image = loaded
            } else {
                failed = true
            }
        }
    }
}
