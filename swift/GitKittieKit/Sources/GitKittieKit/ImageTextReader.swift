import CoreGraphics
import Foundation
#if canImport(Vision)
import Vision
#endif

/// A line of text found in an image. `box` is normalized (0…1) with a top-left origin.
public struct ImageTextLine: Sendable, Equatable {
    public let text: String
    public let box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// Reads the visible text out of an image (a screenshot) on-device with Vision, so a
/// text-only model can work from it. It reads text only: it does not judge layout,
/// colour or anything else about how the image looks.
public enum ImageTextReader {
    public static func lines(in imageData: Data) async -> [ImageTextLine] {
        #if canImport(Vision)
        await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(data: imageData)
            guard (try? handler.perform([request])) != nil else { return [] }
            return (request.results ?? []).compactMap { observation in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                // Vision's origin is bottom-left; flip to the top-left origin views use.
                let b = observation.boundingBox
                return ImageTextLine(text: text, box: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height))
            }
        }.value
        #else
        return []
        #endif
    }

    public static func text(in imageData: Data) async -> String {
        await lines(in: imageData).map(\.text).joined(separator: "\n")
    }

    /// What the picture appears to show, as a few plain labels ("outdoor", "animal"), from
    /// Vision's on-device classifier. Coarse, but it is the only idea a text-only model
    /// gets of an image that has no text in it.
    public static func labels(in imageData: Data, limit: Int = 6) async -> [String] {
        #if canImport(Vision)
        await Task.detached(priority: .userInitiated) {
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(data: imageData)
            guard (try? handler.perform([request])) != nil else { return [] }
            return (request.results ?? [])
                .filter { $0.confidence >= 0.35 }
                .prefix(limit)
                .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        }.value
        #else
        return []
        #endif
    }

    /// The text inside a selected region (normalized, top-left origin), top to bottom.
    public static func text(in region: CGRect, of lines: [ImageTextLine]) -> String {
        lines.filter { region.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) }
            .sorted { $0.box.minY < $1.box.minY }
            .map(\.text)
            .joined(separator: " ")
    }
}
