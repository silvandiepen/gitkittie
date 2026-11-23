import XCTest
@testable import GitKittieKit

final class MarkdownBlocksTests: XCTestCase {
    func testBlocks() {
        let text = """
        ## Context

        The runbook runs
        a tool.

        ```bash
        ./rb tool.rb > "$STATE/x.json"
        - [ ] not a checkbox
        ```

        > [!NOTE]
        > The midnight run lost
        > its baseline.

        > Plain quote

        ## Next steps

        - [x] Confirm the path
        - [ ] Update the runbook
          over two lines
            - nested

        1. First
        2. Second

        ---

        | A | B |
        |---|---|
        | 1 | 2 |
        """
        let blocks = MarkdownBlocks.parse(text)
        XCTAssertEqual(blocks[0], .heading(level: 2, text: "Context"))
        XCTAssertEqual(blocks[1], .paragraph("The runbook runs a tool."))
        XCTAssertEqual(blocks[2], .code(language: "bash", text: "./rb tool.rb > \"$STATE/x.json\"\n- [ ] not a checkbox"))
        XCTAssertEqual(blocks[3], .quote(kind: "NOTE", text: "The midnight run lost its baseline."))
        XCTAssertEqual(blocks[4], .quote(kind: nil, text: "Plain quote"))
        guard case .list(let tasks) = blocks[6] else { return XCTFail("no task list") }
        // A numbered list right after a bulleted one stays in the same block; each item says which it is.
        XCTAssertEqual(tasks.map(\.checked), [true, false, nil, nil, nil])
        XCTAssertEqual(tasks.map(\.checkIndex), [0, 1, nil, nil, nil])
        XCTAssertEqual(tasks[1].text, "Update the runbook over two lines")
        XCTAssertGreaterThan(tasks[2].indent, tasks[1].indent)
        XCTAssertEqual(tasks.map(\.number), [nil, nil, nil, "1.", "2."])
        XCTAssertEqual(blocks[7], .rule)
        XCTAssertEqual(blocks[8], .table(header: ["A", "B"], rows: [["1", "2"]]))
    }
}
