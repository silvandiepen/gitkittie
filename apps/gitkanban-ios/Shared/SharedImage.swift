import GitKanbanKit
import UIKit

/// An image handed to the share extension or picked for a new task, ready to be written as
/// a card attachment. The image and its marks are a `TaskImage` (GitKanbanKit), which the
/// Mac uses too; this adds the small preview the iPhone's lists show.
struct SharedImage: Identifiable {
    var image: TaskImage
    let thumbnail: UIImage?

    init(image: TaskImage, thumbnail: UIImage?) {
        self.image = image
        self.thumbnail = thumbnail
    }

    init(data: Data, fileExtension: String, thumbnail: UIImage?) {
        self.init(image: TaskImage(data: data, fileExtension: fileExtension), thumbnail: thumbnail)
    }

    var id: TaskImage.ID { image.id }
    var data: Data { image.data }
    var fileExtension: String { image.fileExtension }
    var annotations: [ImageAnnotation] {
        get { image.annotations }
        set { image.annotations = newValue }
    }
    /// The image's size in pixels, read from its header without decoding it.
    var pixelSize: CGSize? { image.pixelSize }

    /// Load every image from the share sheet's item providers, in order.
    @MainActor
    static func load(from providers: [NSItemProvider]) async -> [SharedImage] {
        await TaskImage.load(from: providers).map { SharedImage(image: $0, thumbnail: downsampled($0.data, maxPixel: 480)) }
    }

    /// A downsampled copy: the extension has a tight memory budget, so the full image is
    /// never decoded just to show it.
    static func downsampled(_ data: Data, maxPixel: Int) -> UIImage? {
        TaskImage.downsampled(data, maxPixel: maxPixel).map { UIImage(cgImage: $0) }
    }

    /// What to attach: the image itself, with the numbered annotation boxes drawn on it
    /// when there are any, as JPEG when the original is large.
    func attachment() -> (data: Data, fileExtension: String) { image.attachment() }

    static let annotationColor = UIColor(cgColor: TaskImage.annotationColor)
}

extension Array where Element == SharedImage {
    /// The images as the shared drafting and saving code takes them.
    var taskImages: [TaskImage] { map(\.image) }
}
