#if canImport(AppKit)
import AppKit
import XCTest
@testable import GitKittieKit

final class MarkdownSourceStylerTests: XCTestCase {
    private let palette = MarkdownSourceStyler.Palette(
        baseFont: .systemFont(ofSize: 13), textColor: .labelColor, accentColor: .systemBlue)

    private func styled(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        MarkdownSourceStyler.apply(to: storage, palette: palette)
        return storage
    }

    private func font(_ storage: NSTextStorage, at location: Int) -> NSFont {
        storage.attribute(.font, at: location, effectiveRange: nil) as! NSFont
    }

    func testTextIsNeverChangedOnlyStyled() {
        let text = "# Title\n\nSome **bold**, *slanted* and `code`.\n\n- [x] item\n\n```\nlet a = 1\n```\n"
        XCTAssertEqual(styled(text).string, text)
    }

    func testHeadingsGrowAndBoldReadsBoldInTheSameFamily() {
        let storage = styled("# Title\nplain **bold** plain\n")
        XCTAssertEqual(font(storage, at: 3).pointSize, 13 * 1.5, accuracy: 0.01)
        XCTAssertTrue(font(storage, at: 3).fontDescriptor.symbolicTraits.contains(.bold))
        let boldAt = ("# Title\nplain **bold** plain\n" as NSString).range(of: "bold").location
        XCTAssertTrue(font(storage, at: boldAt).fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(font(storage, at: boldAt).fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertFalse(font(storage, at: 9).fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testMarkersFade() {
        let storage = styled("# Title\n")
        let hash = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as! NSColor
        let word = storage.attribute(.foregroundColor, at: 3, effectiveRange: nil) as! NSColor
        XCTAssertLessThan(hash.alphaComponent, 0.5)
        XCTAssertNotEqual(hash, word)
    }
}
#endif
