import CryptoKit
import Foundation
import os

/// Attachment text inside the app's own process, for platforms without XPC services for apps
/// (iOS; MAIL-052). The macOS app keeps using `IsolatedTextExtractor`.
///
/// Without a separate process, a crash or a hang in the PDF engine is the app's, so this
/// narrows what reaches it instead:
///
/// - `Limits.inProcess` by default: smaller inputs, fewer pages, less text, and a time budget
///   checked between pages.
/// - One extraction at a time, at utility priority, off the caller's actor.
/// - A caller-side timeout: past it the caller gets "no text" and moves on (the parse itself
///   cannot be interrupted and finishes in the background).
/// - A crash record: with `attemptsFolder`, a marker named after the bytes' SHA-256 is written
///   before parsing and removed after. If the process dies mid-parse (a crash, or iOS ending it
///   for memory), the marker stays and those bytes are never parsed again, so one hostile
///   attachment cannot crash the app on every launch.
public actor InProcessTextExtractor: AttachmentTextExtracting {
    private let limits: AttachmentTextExtractor.Limits
    private let timeout: Duration
    private let attemptsFolder: URL?
    private var tail: Task<Void, Never>?

    /// `attemptsFolder` should be device-local and outside the mail folder, for example
    /// `<Application Support>/Mail/cache/attachment-text-attempts/`.
    public init(limits: AttachmentTextExtractor.Limits = .inProcess, timeout: Duration = .seconds(10), attemptsFolder: URL? = nil) {
        self.limits = limits
        self.timeout = timeout
        self.attemptsFolder = attemptsFolder
    }

    public func extract(_ data: Data, mediaType: String) async -> String? {
        guard AttachmentTextExtractor.supportedMediaTypes.contains(mediaType.lowercased()),
              data.count <= limits.maximumInputBytes else { return nil }
        let marker = attemptsFolder.map { $0.appendingPathComponent(Self.sha256Hex(data) + ".inflight") }
        if let marker, FileManager.default.fileExists(atPath: marker.path) { return nil }

        let previous = tail
        let limits = self.limits
        let work = Task.detached(priority: .utility) { () -> String? in
            await previous?.value
            if let marker {
                // No marker, no parse: an unrecorded attempt could crash the app forever.
                guard (try? Self.writeMarker(marker)) != nil else { return nil }
            }
            let text = AttachmentTextExtractor.extract(data, mediaType: mediaType, limits: limits)
            if let marker { try? FileManager.default.removeItem(at: marker) }
            return text
        }
        tail = Task { _ = await work.value }

        let timeout = self.timeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<String?, Never>?>(initialState: continuation)
            @Sendable func finish(_ value: String?) {
                pending.withLock { current -> CheckedContinuation<String?, Never>? in
                    defer { current = nil }
                    return current
                }?.resume(returning: value)
            }
            Task { finish(await work.value) }
            Task {
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
    }

    private static func writeMarker(_ marker: URL) throws {
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: marker)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
