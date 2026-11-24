import Foundation
import os
#if canImport(PDFKit)
import PDFKit
#endif

/// Text out of attachments, for search (GKM-016): PDF and plain text. Parsing a PDF is parsing
/// attacker-controlled input with a large engine, so the macOS app never calls this in its own
/// process: it runs in `GitMailExtractor.xpc`, a sandboxed XPC service with no network, no file
/// access and a watchdog (ThreatModel §4). This type is the code that runs there. iOS has no
/// XPC services for apps, so there `InProcessTextExtractor` runs it with stricter limits
/// (MAIL-052).
public enum AttachmentTextExtractor {
    public static let supportedMediaTypes: Set<String> = [
        "application/pdf", "text/plain", "text/csv", "text/markdown", "text/x-markdown", "text/calendar",
    ]

    public struct Limits: Sendable {
        /// Larger inputs are not read at all.
        public var maximumInputBytes = 25 * 1024 * 1024
        public var maximumPages = 300
        public var maximumOutputCharacters = 500_000
        /// Stop reading further PDF pages once this much time has passed (checked between
        /// pages). `nil`: no limit — the XPC service has a watchdog that ends the process.
        public var maximumDuration: Duration?
        public init() {}

        /// For extraction inside the app's own process (iOS, MAIL-052): a hostile or huge PDF
        /// there costs the app's memory and time, so less of it is read.
        public static var inProcess: Limits {
            var limits = Limits()
            limits.maximumInputBytes = 10 * 1024 * 1024
            limits.maximumPages = 100
            limits.maximumOutputCharacters = 200_000
            limits.maximumDuration = .seconds(5)
            return limits
        }
    }

    /// The text, or nil when the type is unsupported, the input is over the limits, the PDF is
    /// encrypted, or nothing readable is in it.
    public static func extract(_ data: Data, mediaType: String, limits: Limits = Limits()) -> String? {
        guard data.count <= limits.maximumInputBytes else { return nil }
        let type = mediaType.lowercased()
        let text: String?
        switch type {
        case "application/pdf": text = pdfText(data, limits: limits)
        case _ where supportedMediaTypes.contains(type): text = plainText(data)
        default: text = nil
        }
        guard let text else { return nil }
        let cleaned = String(text.unicodeScalars.filter { $0 != "\0" }.map(Character.init)).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(limits.maximumOutputCharacters))
    }

    static func plainText(_ data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    static func pdfText(_ data: Data, limits: Limits) -> String? {
        #if canImport(PDFKit)
        guard data.starts(with: Array("%PDF-".utf8)) || data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil,
              let document = PDFDocument(data: data), !document.isLocked else { return nil }
        var pages: [String] = []
        var length = 0
        let deadline = limits.maximumDuration.map { ContinuousClock.now + $0 }
        for index in 0..<min(document.pageCount, limits.maximumPages) {
            if let deadline, ContinuousClock.now >= deadline { break }
            guard let text = document.page(at: index)?.string else { continue }
            pages.append(text)
            length += text.count
            if length >= limits.maximumOutputCharacters { break }
        }
        return pages.joined(separator: "\n")
        #else
        return nil
        #endif
    }
}

/// Something that turns attachment bytes into text for search: `IsolatedTextExtractor` (the XPC
/// service, macOS) or `InProcessTextExtractor` (iOS). Any failure is "no text", never an error.
public protocol AttachmentTextExtracting: Sendable {
    func extract(_ data: Data, mediaType: String) async -> String?
}

/// The XPC interface between the app and `GitMailExtractor.xpc`. Bytes in, text out: the
/// service is never given a path, so it needs no file access.
@objc public protocol AttachmentTextExtractionXPC {
    func extractText(_ data: Data, mediaType: String, reply: @escaping (String?) -> Void)
}

/// What the XPC service exports. With `watchdog`, a request that runs longer than that ends the
/// whole process (the app sees an interrupted connection and records no text): a hostile PDF
/// that sends the parser into a loop costs one helper process, never the app.
public final class ExtractionService: NSObject, AttachmentTextExtractionXPC {
    private let watchdog: TimeInterval?
    private let limits: AttachmentTextExtractor.Limits

    public init(watchdog: TimeInterval?, limits: AttachmentTextExtractor.Limits = .init()) {
        self.watchdog = watchdog
        self.limits = limits
    }

    public func extractText(_ data: Data, mediaType: String, reply: @escaping (String?) -> Void) {
        let finished = OSAllocatedUnfairLock(initialState: false)
        if let watchdog {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + watchdog) {
                if !finished.withLock({ $0 }) { exit(EXIT_FAILURE) }
            }
        }
        let text = AttachmentTextExtractor.extract(data, mediaType: mediaType, limits: limits)
        finished.withLock { $0 = true }
        reply(text)
    }
}

#if os(macOS)
/// The app's side: sends attachment bytes to the extraction service and waits, at most
/// `timeout`, for text. Any failure — the service crashed, timed out, or is missing — is
/// "no text", never an error in the app.
public actor IsolatedTextExtractor: AttachmentTextExtracting {
    private let makeConnection: @Sendable () -> NSXPCConnection
    private let timeout: Duration
    private var connection: NSXPCConnection?

    /// The bundled service, by its bundle identifier.
    public init(serviceName: String, timeout: Duration = .seconds(30)) {
        self.makeConnection = { NSXPCConnection(serviceName: serviceName) }
        self.timeout = timeout
    }

    /// Any listener: tests use an anonymous one to exercise the same XPC path in process.
    public init(endpoint: NSXPCListenerEndpoint, timeout: Duration = .seconds(30)) {
        self.makeConnection = { NSXPCConnection(listenerEndpoint: endpoint) }
        self.timeout = timeout
    }

    public func extract(_ data: Data, mediaType: String) async -> String? {
        let connection = currentConnection()
        let timeout = self.timeout
        let result: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let pending = OSAllocatedUnfairLock<CheckedContinuation<String?, Never>?>(initialState: continuation)
            @Sendable func finish(_ value: String?) {
                pending.withLock { current -> CheckedContinuation<String?, Never>? in
                    defer { current = nil }
                    return current
                }?.resume(returning: value)
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish(nil) } as? AttachmentTextExtractionXPC
            guard let proxy else { return finish(nil) }
            proxy.extractText(data, mediaType: mediaType) { text in finish(text) }
            Task {
                try? await Task.sleep(for: timeout)
                finish(nil)
            }
        }
        return result
    }

    /// Drops the connection; the next request makes a new one (and launches a fresh service).
    public func reset() {
        connection?.invalidate()
        connection = nil
    }

    private func currentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let connection = makeConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: AttachmentTextExtractionXPC.self)
        connection.invalidationHandler = {}
        connection.interruptionHandler = {}
        connection.resume()
        self.connection = connection
        return connection
    }
}
#endif
