import GitKittieKit
import GitPontCore
import XCTest
@testable import GitBud

/// The whole iOS flow against the demo store: read a commit through the provider contract,
/// choose lines, and open a pull request that undoes or picks them.
final class ChangeComposerTests: XCTestCase {
    private let store = DemoStore()
    private var provider: DemoProvider { DemoProvider(store: store) }
    private let context = GitProviderRequestContext(connection: nil, credential: GitCredential(accessToken: "demo"))

    private func composer() -> ChangeComposer {
        ChangeComposer(provider: provider, context: context, repository: DemoStore.repository)
    }

    private func commit(named subject: String) async throws -> GitCommitDetail {
        let history = try await provider.commits(GitCommitHistoryQuery(repository: DemoStore.repository, ref: "main", perPage: 50), context: context)
        let summary = try XCTUnwrap(history.items.first { $0.subject == subject })
        return try await provider.commit(sha: summary.sha, repository: DemoStore.repository, context: context)
    }

    private func diffs(of detail: GitCommitDetail) -> [GitFileDiff] {
        detail.files.compactMap { file in
            file.patch.map { GitFileDiff(path: file.path, oldPath: file.previousPath, hunksText: $0, isNewFile: file.status == .added, isDeletedFile: file.status == .removed) }
        }
    }

    private func text(_ path: String, at ref: String) async throws -> String {
        String(decoding: try await provider.readFile(GitFileReference(repository: DemoStore.repository, path: path, ref: ref), context: context).content, as: UTF8.self)
    }

    func testUndoingOneLineKeepsALaterEditNextToItAndLeavesMainAlone() async throws {
        let detail = try await commit(named: "Update header, docs and add analytics")
        let diffs = diffs(of: detail)
        let index = try XCTUnwrap(diffs.first { $0.path == "index.html" })
        var selection = GitChangeSelection()
        for hunk in index.hunks {
            for (offset, line) in hunk.lines.enumerated() where line.contains("plausible") { selection.toggle(hunk, line: offset) }
        }
        let mainBefore = try await text("index.html", at: "main")

        let pull = try await composer().openPullRequest(
            commit: detail, diffs: diffs, selection: selection, reverse: true,
            target: "main", branchName: "bud/undo-analytics", title: "Remove analytics", body: "")

        XCTAssertEqual(pull.sourceBranch, "bud/undo-analytics")
        XCTAssertEqual(pull.targetBranch, "main")
        let undone = try await text("index.html", at: "bud/undo-analytics")
        XCTAssertFalse(undone.contains("plausible"))
        XCTAssertTrue(undone.contains("© 2026 Harbor"), "the later footer edit on the next line is kept")
        XCTAssertTrue(undone.contains("/signup"), "unchosen lines of the same commit stay")
        let mainAfter = try await text("index.html", at: "main")
        XCTAssertEqual(mainAfter, mainBefore, "nothing is written to the target")
    }

    func testPickingLinesBringsThemToAnotherBranch() async throws {
        let detail = try await commit(named: "fix: correct the footer year")
        var selection = GitChangeSelection()
        let diffs = diffs(of: detail)
        selection.toggle(try XCTUnwrap(diffs.first))

        _ = try await composer().openPullRequest(
            commit: detail, diffs: diffs, selection: selection, reverse: false,
            target: "feature/testimonials", branchName: "bud/pick-year", title: "Correct the year", body: "")

        let picked = try await text("index.html", at: "bud/pick-year")
        XCTAssertTrue(picked.contains("© 2026 Harbor"))
        XCTAssertTrue(picked.contains("testimonials"), "the target branch's own work is kept")
    }

    func testPickingAChangeTheBranchAlreadyHasMakesNothing() async throws {
        let detail = try await commit(named: "fix: correct the footer year")
        var selection = GitChangeSelection()
        let diffs = diffs(of: detail)
        selection.toggle(try XCTUnwrap(diffs.first))
        // Picking the year change onto main, which has it already, changes nothing: no PR.
        do {
            _ = try await composer().operations(commit: detail, diffs: diffs, selection: selection, reverse: false, onto: "main")
            XCTFail("Expected nothing to change")
        } catch let error as ChangeComposer.ComposeError {
            XCTAssertEqual(error, .nothingChosen)
        }
        let branches = await store.branchList().map(\.name)
        XCTAssertFalse(branches.contains { $0.hasPrefix("bud/") })
    }
}
