import XCTest
@testable import GitKittieKit

final class GitDiffLayoutTests: XCTestCase {
    private let hunk = GitHunk(id: "f.txt:0", header: "@@ -10,4 +10,4 @@ func", lines: [
        " keep", "-old one", "-old two", "+new one", " keep too", "+added", "\\ No newline at end of file", "",
    ])

    func testLinesAreNumberedPerSide() {
        let lines = GitDiffLayout.lines(of: hunk)
        XCTAssertEqual(lines.map(\.text), ["keep", "old one", "old two", "new one", "keep too", "added"])
        XCTAssertEqual(lines.map(\.oldNumber), [10, 11, 12, nil, 13, nil])
        XCTAssertEqual(lines.map(\.newNumber), [10, nil, nil, 11, 12, 13])
    }

    func testSideBySidePairsRemovalsWithTheAdditionsThatReplaceThem() {
        let rows = GitDiffLayout.rows(of: hunk)
        XCTAssertEqual(rows.map { $0.left?.text }, ["keep", "old one", "old two", "keep too", nil])
        XCTAssertEqual(rows.map { $0.right?.text }, ["keep", "new one", nil, "keep too", "added"])
    }

    func testSelectionSurvivesReadingTheCommitWithMoreContext() {
        let narrow = [GitFileDiff(path: "f.txt", hunks: [hunk])]
        let wide = [GitFileDiff(path: "f.txt", hunks: [GitHunk(id: "f.txt:0", header: "@@ -1,13 +1,13 @@", lines:
            (1...9).map { " line \($0)" } + [" keep", "-old one", "-old two", "+new one", " keep too", "+added"])])]
        var selection = GitChangeSelection()
        selection.toggle(hunk, line: 2) // "-old two"
        selection.toggle(hunk, line: 5) // "+added"

        let moved = selection.remapped(from: narrow, to: wide)
        XCTAssertEqual(moved.lines["f.txt:0"], [11, 14])
    }
}

final class GitPatchApplyTests: XCTestCase {
    func testAppliesInsertionsRemovalsAndKeepsTheRest() throws {
        let patch = "--- a/f\n+++ b/f\n@@ -2,2 +2,2 @@\n b\n-c\n+C\n"
        XCTAssertEqual(try GitPatchBuilder.applying(patch, to: "a\nb\nc\nd\n"), "a\nb\nC\nd\n")
    }

    func testCreatesAndRemovesFiles() throws {
        XCTAssertEqual(try GitPatchBuilder.applying("--- /dev/null\n+++ b/f\n@@ -0,0 +1,2 @@\n+x\n+y\n", to: nil), "x\ny\n")
        XCTAssertNil(try GitPatchBuilder.applying("--- a/f\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-x\n", to: "x\n"))
    }

    func testKeepsAMissingFinalNewline() throws {
        let patch = "--- a/f\n+++ b/f\n@@ -1,1 +1,1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n"
        XCTAssertEqual(try GitPatchBuilder.applying(patch, to: "a"), "b")
    }

    func testRefusesTextThatDoesNotMatch() {
        let patch = "--- a/f\n+++ b/f\n@@ -1,1 +1,1 @@\n-a\n+b\n"
        XCTAssertThrowsError(try GitPatchBuilder.applying(patch, to: "z\n"))
    }
}

final class GitLineMergeTests: XCTestCase {
    func testTakesChangesThatOnlyTouch() {
        let merged = GitLineMerge.merge(
            base: "main\nfooter 2025\nscript\nbody\n",
            ours: "main\nfooter 2026\nscript\nbody\n",
            theirs: "main\nfooter 2025\nbody\n")
        XCTAssertEqual(merged, "main\nfooter 2026\nbody\n")
    }

    func testRefusesTheSameLineChangedOnBothSides() {
        XCTAssertNil(GitLineMerge.merge(base: "a\nb\nc\n", ours: "a\nB\nc\n", theirs: "a\nbee\nc\n"))
    }

    func testRefusesInsertionsAtTheSameSpot() {
        XCTAssertNil(GitLineMerge.merge(base: "a\nc\n", ours: "a\nours\nc\n", theirs: "a\ntheirs\nc\n"))
    }

    func testTheSameChangeOnBothSidesIsNotAConflict() {
        let merged = GitLineMerge.merge(
            base: "a\nfooter 2025\nz\n",
            ours: "a\nfooter 2026\nz\nours\n",
            theirs: "a\nfooter 2026\nz\n")
        XCTAssertEqual(merged, "a\nfooter 2026\nz\nours\n")
    }

    func testKeepsEditsFarApart() {
        let merged = GitLineMerge.merge(base: "1\n2\n3\n4\n5\n", ours: "one\n2\n3\n4\n5\n", theirs: "1\n2\n3\n4\nfive\n")
        XCTAssertEqual(merged, "one\n2\n3\n4\nfive\n")
    }
}

final class GitProviderPatchTests: XCTestCase {
    func testHunksTextBecomesHunksWithStableIDs() {
        let diff = GitFileDiff(path: "a.txt", hunksText: "@@ -1,2 +1,2 @@\n x\n-y\n+Y\n@@ -9 +9 @@\n-z\n+Z\n")
        XCTAssertEqual(diff.hunks.map(\.id), ["a.txt:0", "a.txt:1"])
        XCTAssertEqual(diff.hunks[0].lines, [" x", "-y", "+Y"])
    }

    func testFullFileSplicesTheHunksIntoTheWholeText() throws {
        let hunks = GitFileDiff(path: "a.txt", hunksText: "@@ -2,1 +2,1 @@\n-two\n+TWO\n").hunks
        let full = try XCTUnwrap(GitDiffLayout.fullFile(newText: "one\nTWO\nthree\n", hunks: hunks, path: "a.txt"))
        XCTAssertEqual(full.lines, [" one", "-two", "+TWO", " three"])
        XCTAssertEqual(full.header, "@@ -1,3 +1,3 @@")
        // It still applies as a patch to the old text.
        let patch = "--- a/a.txt\n+++ b/a.txt\n" + ([full.header] + full.lines).joined(separator: "\n") + "\n"
        XCTAssertEqual(try GitPatchBuilder.applying(patch, to: "one\ntwo\nthree\n"), "one\nTWO\nthree\n")
    }

    func testFullFileRefusesTextThatMovedOn() {
        let hunks = GitFileDiff(path: "a.txt", hunksText: "@@ -1 +1 @@\n-a\n+b\n").hunks
        XCTAssertNil(GitDiffLayout.fullFile(newText: "c\n", hunks: hunks, path: "a.txt"))
    }
}

final class GitDiffWriterTests: XCTestCase {
    func testWritesHunksThatApplyBack() throws {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        var lines = (1...20).map { "line \($0)" }
        lines[1] = "line TWO"
        lines.insert("added", at: 15)
        let new = lines.joined(separator: "\n") + "\n"

        let hunks = GitDiffWriter.hunks(from: old, to: new)
        XCTAssertEqual(hunks.components(separatedBy: "\n").filter { $0.hasPrefix("@@") }.count, 2)
        let patch = "--- a/f\n+++ b/f\n" + hunks
        XCTAssertEqual(try GitPatchBuilder.applying(patch, to: old), new)
    }

    func testNewAndRemovedFiles() throws {
        XCTAssertEqual(GitDiffWriter.hunks(from: nil, to: "a\nb\n"), "@@ -0,0 +1,2 @@\n+a\n+b\n")
        XCTAssertEqual(GitDiffWriter.hunks(from: "a\n", to: nil), "@@ -1,1 +0,0 @@\n-a\n")
        XCTAssertEqual(GitDiffWriter.hunks(from: "same\n", to: "same\n"), "")
    }
}
