import GitPontCore
import GitPontGitHub
import XCTest
@testable import GitKanbanKit

/// Runs against a real GitHub branch, so only when one is named:
/// `BATCH_REPO=owner/name BATCH_BRANCH=scratch BATCH_TOKEN=… swift test --filter BatchWriteLiveTests`.
final class BatchWriteLiveTests: XCTestCase {
    func testSeveralFilesBecomeOneCommit() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let repo = env["BATCH_REPO"]?.split(separator: "/"), repo.count == 2,
              let branch = env["BATCH_BRANCH"], let token = env["BATCH_TOKEN"] else {
            throw XCTSkip("No scratch branch named")
        }
        let source = GitPontFileSource.gitHub(owner: String(repo[0]), repo: String(repo[1]), branch: branch, token: token)
        let readme = try await source.readText("README.md")
        let stamp = "batch \(UUID().uuidString)"
        let done = try await source.writeTexts(
            ["README.md": readme + "\n<!-- \(stamp) -->\n", "zz-batch-test/new file.md": "# \(stamp)\n"], message: "Batch write test")
        XCTAssertTrue(done)
        let after = try await source.readText("README.md")
        XCTAssertTrue(after.hasSuffix("<!-- \(stamp) -->\n"))
        let created = try await source.readText("zz-batch-test/new file.md")
        XCTAssertEqual(created, "# \(stamp)\n")
    }

    /// A blind delete of a file written just before, and a webhook made and removed again.
    func testBlindDeleteAndWebhookRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let repo = env["BATCH_REPO"], repo.split(separator: "/").count == 2,
              let branch = env["BATCH_BRANCH"], let token = env["BATCH_TOKEN"] else {
            throw XCTSkip("No scratch branch named")
        }
        let parts = repo.split(separator: "/").map(String.init)
        let source = GitPontFileSource.gitHub(owner: parts[0], repo: parts[1], branch: branch, token: token)
        try await source.write(path: "zz-batch-test/delete-me.md", text: "bye\n", message: "Write a file to delete")
        try await source.delete(path: "zz-batch-test/delete-me.md", message: "Delete it again")
        do {
            _ = try await source.readText("zz-batch-test/delete-me.md")
            XCTFail("the file is still there")
        } catch {}

        let connection = ProviderConnection(
            choice: .github, instance: .github, provider: GitHubProvider(httpClient: UncachedHTTPClient()), token: token, login: parts[0])
        let id = try await ProviderWebhook.create(with: connection, repo: repo, url: "https://example.com/gitkittie-webhook-test", secret: "test-secret")
        XCTAssertGreaterThan(id, 0)
        await ProviderWebhook.remove(id, with: connection, repo: repo)
    }
}

final class LinkedDocsLiveTests: XCTestCase {
    /// `DOCS_REPO=owner/name DOCS_TOKEN=… swift test --filter LinkedDocsLiveTests`: list a real docs folder.
    func testListingARealDocsFolder() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let repo = env["DOCS_REPO"], let token = env["DOCS_TOKEN"] else { throw XCTSkip("No repository named") }
        let linked = try XCTUnwrap(DocSource(written: "\(repo):docs"))
        let provider = GitHubProvider(httpClient: UncachedHTTPClient())
        let started = Date()
        let context = ProviderConnection(choice: .github, instance: .github, provider: provider, token: token, login: linked.owner).requestContext
        let found = try await provider.repository(GitRepositoryReference(instance: .github, namespace: linked.owner, name: linked.name), context: context)
        print("DOCS default branch: \(found.reference.defaultBranch ?? "nil") after \(Date().timeIntervalSince(started)) s")
        let source = GitPontFileSource(provider: provider, instance: .github, owner: linked.owner, repo: linked.name,
                                       branch: found.reference.defaultBranch ?? "main", token: token)
        let pages = await BoardDocs.list(linked, through: source)
        print("DOCS listed \(pages.count) pages in \(Date().timeIntervalSince(started)) s; folders: \(Set(pages.map(\.group)).sorted())")
        let all = await BoardDocs.readAll(pages, of: linked, through: source)
        print("DOCS read \(all.filter(\.isLoaded).count) pages in \(Date().timeIntervalSince(started)) s")
        XCTAssertFalse(pages.isEmpty)
    }
}
