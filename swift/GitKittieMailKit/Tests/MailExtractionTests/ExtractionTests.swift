import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import MailExtraction

/// GKM-016: attachment text for search, and the XPC path the app uses to run it isolated.
final class ExtractionTests: XCTestCase {
    func testTextFromARealPDF() throws {
        let pdf = try Self.makePDF(lines: ["Garden plan for spring", "Raised beds and compost"])
        let text = try XCTUnwrap(AttachmentTextExtractor.extract(pdf, mediaType: "application/pdf"))
        XCTAssertTrue(text.contains("Raised beds and compost"), text)
    }

    func testPlainTextAndLimits() {
        XCTAssertEqual(AttachmentTextExtractor.extract(Data("Notes\0 for the trip\n".utf8), mediaType: "text/plain"), "Notes for the trip")
        XCTAssertEqual(AttachmentTextExtractor.extract(Data([0x43, 0x61, 0x66, 0xE9]), mediaType: "TEXT/PLAIN"), "Café", "Latin-1 fallback")
        XCTAssertNil(AttachmentTextExtractor.extract(Data("x".utf8), mediaType: "application/zip"), "unsupported types are not read")
        XCTAssertNil(AttachmentTextExtractor.extract(Data("not a pdf at all".utf8), mediaType: "application/pdf"))
        var limits = AttachmentTextExtractor.Limits()
        limits.maximumInputBytes = 4
        XCTAssertNil(AttachmentTextExtractor.extract(Data("too long".utf8), mediaType: "text/plain", limits: limits))
        limits = AttachmentTextExtractor.Limits()
        limits.maximumOutputCharacters = 5
        XCTAssertEqual(AttachmentTextExtractor.extract(Data("abcdefghij".utf8), mediaType: "text/plain", limits: limits), "abcde")
    }

    func testTruncatedAndGarbagePDFsYieldNothingRatherThanCrash() throws {
        let pdf = try Self.makePDF(lines: ["Some text"])
        for cut in [10, 100, pdf.count / 2, pdf.count - 20] {
            _ = AttachmentTextExtractor.extract(pdf.prefix(cut), mediaType: "application/pdf")
        }
        var garbage = Data("%PDF-1.7\n".utf8)
        garbage.append(Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
        XCTAssertNil(AttachmentTextExtractor.extract(garbage, mediaType: "application/pdf"))
    }

    /// The same XPC interface, client and service object the app uses, over an anonymous
    /// listener in this process (the bundled service itself only exists inside GitMail.app).
    func testTheXPCRoundTrip() async throws {
        let delegate = ListenerDelegate()
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let extractor = IsolatedTextExtractor(endpoint: listener.endpoint, timeout: .seconds(10))
        let pdf = try Self.makePDF(lines: ["Quarterly numbers attached"])
        let text = await extractor.extract(pdf, mediaType: "application/pdf")
        XCTAssertTrue(text?.contains("Quarterly numbers attached") == true, text ?? "nil")
        let none = await extractor.extract(Data("x".utf8), mediaType: "application/zip")
        XCTAssertNil(none)
    }

    func testAServiceThatNeverAnswersTimesOutAsNoText() async throws {
        let delegate = ListenerDelegate(service: SilentService())
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer { listener.invalidate() }
        let extractor = IsolatedTextExtractor(endpoint: listener.endpoint, timeout: .milliseconds(300))
        let started = Date()
        let text = await extractor.extract(Data("hello".utf8), mediaType: "text/plain")
        XCTAssertNil(text)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    // MARK: Helpers

    final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
        let service: NSObject & AttachmentTextExtractionXPC
        init(service: NSObject & AttachmentTextExtractionXPC = ExtractionService(watchdog: nil)) { self.service = service }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: AttachmentTextExtractionXPC.self)
            connection.exportedObject = service
            connection.resume()
            return true
        }
    }

    final class SilentService: NSObject, AttachmentTextExtractionXPC {
        func extractText(_ data: Data, mediaType: String, reply: @escaping (String?) -> Void) {}
    }

    /// A one-page PDF with real text runs, drawn with Core Graphics and Core Text.
    static func makePDF(lines: [String]) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for (offset, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 72, y: 760 - CGFloat(offset) * 24)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
