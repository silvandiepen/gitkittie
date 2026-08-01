import XCTest
@testable import GitKittieKit

final class GitHubPullRequestServiceTests: XCTestCase {
    override func tearDown() {
        PullRequestURLProtocol.handler = nil
        super.tearDown()
    }

    func testCreatePullRequestPostsExpectedGitHubRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PullRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = GitHubPullRequestService(
            session: session,
            apiBaseURL: URL(string: "https://api.example.test")!,
            userAgent: "GitKittieKitTests"
        )

        PullRequestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/repos/sil/gitbud/pulls")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GitKittieKitTests")

            let body = try XCTUnwrap(request.httpBodyStream.flatMap(Self.data(from:)))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["title"] as? String, "feat: prepare cleanup")
            XCTAssertEqual(json?["body"] as? String, "Rewrite reviewed in GitBud.")
            XCTAssertEqual(json?["head"] as? String, "feature/cleanup")
            XCTAssertEqual(json?["base"] as? String, "main")
            XCTAssertEqual(json?["draft"] as? Bool, true)

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data("""
            {
              "number": 42,
              "title": "feat: prepare cleanup",
              "html_url": "https://github.com/sil/gitbud/pull/42",
              "head": { "ref": "feature/cleanup" },
              "base": { "ref": "main" }
            }
            """.utf8)
            return (response, data)
        }

        let pullRequest = try await service.createPullRequest(
            GitHubPullRequestDraft(
                repositoryFullName: "sil/gitbud",
                title: "feat: prepare cleanup",
                body: "Rewrite reviewed in GitBud.",
                head: "feature/cleanup",
                base: "main"
            ),
            token: "test-token"
        )

        XCTAssertEqual(pullRequest.number, 42)
        XCTAssertEqual(pullRequest.url, URL(string: "https://github.com/sil/gitbud/pull/42"))
        XCTAssertEqual(pullRequest.head, "feature/cleanup")
        XCTAssertEqual(pullRequest.base, "main")
    }

    func testCreatePullRequestRejectsInvalidRepositoryName() async {
        let service = GitHubPullRequestService(
            session: URLSession(configuration: .ephemeral),
            apiBaseURL: URL(string: "https://api.example.test")!,
            userAgent: "GitKittieKitTests"
        )

        do {
            _ = try await service.createPullRequest(
                GitHubPullRequestDraft(
                    repositoryFullName: "missing-owner",
                    title: "Title",
                    body: "",
                    head: "feature",
                    base: "main"
                ),
                token: "test-token"
            )
            XCTFail("Expected invalid repository error")
        } catch {
            XCTAssertEqual(error as? GitHubPullRequestError, .invalidRepository)
        }
    }

    func testListPullRequestsGetsExpectedGitHubRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PullRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = GitHubPullRequestService(
            session: session,
            apiBaseURL: URL(string: "https://api.example.test")!,
            userAgent: "GitKittieKitTests"
        )

        PullRequestURLProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://api.example.test/repos/sil/gitbud/pulls?state=open&per_page=25&sort=updated&direction=desc"
            )
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GitKittieKitTests")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data("""
            [
              {
                "number": 12,
                "title": "feat: review rewritten stack",
                "html_url": "https://github.com/sil/gitbud/pull/12",
                "head": { "ref": "feature/rewrite" },
                "base": { "ref": "main" },
                "state": "open",
                "draft": true
              }
            ]
            """.utf8)
            return (response, data)
        }

        let pullRequests = try await service.listPullRequests(
            repositoryFullName: "sil/gitbud",
            token: "test-token"
        )

        XCTAssertEqual(pullRequests.count, 1)
        XCTAssertEqual(pullRequests.first?.number, 12)
        XCTAssertEqual(pullRequests.first?.title, "feat: review rewritten stack")
        XCTAssertEqual(pullRequests.first?.head, "feature/rewrite")
        XCTAssertEqual(pullRequests.first?.base, "main")
        XCTAssertEqual(pullRequests.first?.state, "open")
        XCTAssertEqual(pullRequests.first?.isDraft, true)
    }

    func testPullRequestReviewSummaryLoadsDetailAndReviews() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PullRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = GitHubPullRequestService(
            session: session,
            apiBaseURL: URL(string: "https://api.example.test")!,
            userAgent: "GitKittieKitTests"
        )

        PullRequestURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GitKittieKitTests")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!

            switch request.url?.absoluteString {
            case "https://api.example.test/repos/sil/gitbud/pulls/12":
                let data = Data("""
                {
                  "number": 12,
                  "title": "feat: review rewritten stack",
                  "html_url": "https://github.com/sil/gitbud/pull/12",
                  "head": { "ref": "feature/rewrite", "sha": "abc123" },
                  "base": { "ref": "main" },
                  "state": "open",
                  "draft": false,
                  "mergeable": true,
                  "mergeable_state": "clean",
                  "comments": 2,
                  "review_comments": 4,
                  "commits": 3,
                  "additions": 44,
                  "deletions": 8,
                  "changed_files": 5
                }
                """.utf8)
                return (response, data)
            case "https://api.example.test/repos/sil/gitbud/pulls/12/reviews?per_page=100":
                let data = Data("""
                [
                  { "state": "APPROVED" },
                  { "state": "CHANGES_REQUESTED" },
                  { "state": "COMMENTED" },
                  { "state": "APPROVED" }
                ]
                """.utf8)
                return (response, data)
            case "https://api.example.test/repos/sil/gitbud/pulls/12/files?per_page=100":
                let data = Data("""
                [
                  {
                    "filename": "Sources/AppModel.swift",
                    "status": "modified",
                    "additions": 30,
                    "deletions": 4,
                    "changes": 34,
                    "patch": "@@ -1 +1 @@"
                  },
                  {
                    "filename": "Sources/NewPanel.swift",
                    "previous_filename": "Sources/OldPanel.swift",
                    "status": "renamed",
                    "additions": 14,
                    "deletions": 4,
                    "changes": 18
                  }
                ]
                """.utf8)
                return (response, data)
            case "https://api.example.test/repos/sil/gitbud/pulls/12/comments?per_page=100":
                let data = Data("""
                [
                  {
                    "id": 901,
                    "path": "Sources/AppModel.swift",
                    "body": "This split reads better now.",
                    "html_url": "https://github.com/sil/gitbud/pull/12#discussion_r901",
                    "user": { "login": "reviewer" },
                    "line": 42,
                    "original_line": 40,
                    "side": "RIGHT",
                    "diff_hunk": "@@ -40,2 +40,2 @@"
                  },
                  {
                    "id": 902,
                    "path": "Sources/NewPanel.swift",
                    "body": "Check this renamed panel.",
                    "user": { "login": "sil" },
                    "original_line": 7,
                    "side": "LEFT"
                  }
                ]
                """.utf8)
                return (response, data)
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "<nil>")")
                return (response, Data("{}".utf8))
            }
        }

        let summary = try await service.pullRequestReviewSummary(
            repositoryFullName: "sil/gitbud",
            number: 12,
            token: "test-token"
        )

        XCTAssertEqual(summary.pullRequest.number, 12)
        XCTAssertEqual(summary.pullRequest.head, "feature/rewrite")
        XCTAssertEqual(summary.pullRequest.headSHA, "abc123")
        XCTAssertEqual(summary.pullRequest.base, "main")
        XCTAssertEqual(summary.changedFiles, 5)
        XCTAssertEqual(summary.commitCount, 3)
        XCTAssertEqual(summary.additions, 44)
        XCTAssertEqual(summary.deletions, 8)
        XCTAssertEqual(summary.issueComments, 2)
        XCTAssertEqual(summary.reviewComments, 4)
        XCTAssertEqual(summary.mergeable, true)
        XCTAssertEqual(summary.mergeableState, "clean")
        XCTAssertEqual(summary.approvals, 2)
        XCTAssertEqual(summary.requestedChanges, 1)
        XCTAssertEqual(summary.reviewCommentThreads, 1)
        XCTAssertEqual(summary.files.count, 2)
        XCTAssertEqual(summary.files.first?.path, "Sources/AppModel.swift")
        XCTAssertEqual(summary.files.first?.status, "modified")
        XCTAssertEqual(summary.files.first?.additions, 30)
        XCTAssertEqual(summary.files.first?.patch, "@@ -1 +1 @@")
        XCTAssertEqual(summary.files.last?.path, "Sources/NewPanel.swift")
        XCTAssertEqual(summary.files.last?.previousPath, "Sources/OldPanel.swift")
        XCTAssertEqual(summary.inlineComments.count, 2)
        XCTAssertEqual(summary.inlineComments.first?.id, 901)
        XCTAssertEqual(summary.inlineComments.first?.path, "Sources/AppModel.swift")
        XCTAssertEqual(summary.inlineComments.first?.authorLogin, "reviewer")
        XCTAssertEqual(summary.inlineComments.first?.line, 42)
        XCTAssertEqual(summary.inlineComments.first?.side, "RIGHT")
        XCTAssertEqual(summary.inlineComments.first?.url, URL(string: "https://github.com/sil/gitbud/pull/12#discussion_r901"))
        XCTAssertEqual(summary.inlineComments(for: summary.files[0]).map(\.id), [901])
        XCTAssertEqual(summary.inlineComments(for: summary.files[1]).map(\.id), [902])
    }

    func testReplyToPullRequestInlineCommentPostsExpectedGitHubRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PullRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = GitHubPullRequestService(
            session: session,
            apiBaseURL: URL(string: "https://api.example.test")!,
            userAgent: "GitKittieKitTests"
        )

        PullRequestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/repos/sil/gitbud/pulls/12/comments/901/replies")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GitKittieKitTests")

            let body = try XCTUnwrap(request.httpBodyStream.flatMap(Self.data(from:)))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["body"] as? String, "Handled in the rewritten stack.")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data("""
            {
              "id": 903,
              "path": "Sources/AppModel.swift",
              "body": "Handled in the rewritten stack.",
              "html_url": "https://github.com/sil/gitbud/pull/12#discussion_r903",
              "user": { "login": "sil" },
              "line": 44,
              "side": "RIGHT"
            }
            """.utf8)
            return (response, data)
        }

        let reply = try await service.replyToPullRequestInlineComment(
            repositoryFullName: "sil/gitbud",
            number: 12,
            commentID: 901,
            body: "Handled in the rewritten stack.",
            token: "test-token"
        )

        XCTAssertEqual(reply.id, 903)
        XCTAssertEqual(reply.path, "Sources/AppModel.swift")
        XCTAssertEqual(reply.body, "Handled in the rewritten stack.")
        XCTAssertEqual(reply.authorLogin, "sil")
        XCTAssertEqual(reply.line, 44)
    }

    func testCreatePullRequestInlineCommentPostsExpectedGitHubRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PullRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = GitHubPullRequestService(
            session: session,
            apiBaseURL: URL(string: "https://api.example.test")!,
            userAgent: "GitKittieKitTests"
        )

        PullRequestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/repos/sil/gitbud/pulls/12/comments")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GitKittieKitTests")

            let body = try XCTUnwrap(request.httpBodyStream.flatMap(Self.data(from:)))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["body"] as? String, "This line still needs a guard.")
            XCTAssertEqual(json?["commit_id"] as? String, "abc123")
            XCTAssertEqual(json?["path"] as? String, "Sources/AppModel.swift")
            XCTAssertEqual(json?["line"] as? Int, 42)
            XCTAssertEqual(json?["side"] as? String, "RIGHT")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 201,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data("""
            {
              "id": 904,
              "path": "Sources/AppModel.swift",
              "body": "This line still needs a guard.",
              "html_url": "https://github.com/sil/gitbud/pull/12#discussion_r904",
              "user": { "login": "sil" },
              "line": 42,
              "side": "RIGHT"
            }
            """.utf8)
            return (response, data)
        }

        let comment = try await service.createPullRequestInlineComment(
            repositoryFullName: "sil/gitbud",
            number: 12,
            draft: GitHubPullRequestInlineCommentDraft(
                body: "This line still needs a guard.",
                commitID: "abc123",
                path: "Sources/AppModel.swift",
                line: 42
            ),
            token: "test-token"
        )

        XCTAssertEqual(comment.id, 904)
        XCTAssertEqual(comment.path, "Sources/AppModel.swift")
        XCTAssertEqual(comment.body, "This line still needs a guard.")
        XCTAssertEqual(comment.authorLogin, "sil")
        XCTAssertEqual(comment.line, 42)
    }

    func testSubmitPullRequestReviewPostsExpectedGitHubRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PullRequestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = GitHubPullRequestService(
            session: session,
            apiBaseURL: URL(string: "https://api.example.test")!,
            userAgent: "GitKittieKitTests"
        )

        PullRequestURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.example.test/repos/sil/gitbud/pulls/12/reviews")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

            let body = try XCTUnwrap(request.httpBodyStream.flatMap(Self.data(from:)))
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(json?["body"] as? String, "This rewrite is ready.")
            XCTAssertEqual(json?["event"] as? String, "APPROVE")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data("""
            {
              "id": 5001,
              "state": "APPROVED",
              "body": "This rewrite is ready.",
              "html_url": "https://github.com/sil/gitbud/pull/12#pullrequestreview-5001",
              "user": { "login": "sil" }
            }
            """.utf8)
            return (response, data)
        }

        let review = try await service.submitPullRequestReview(
            repositoryFullName: "sil/gitbud",
            number: 12,
            event: .approve,
            body: "This rewrite is ready.",
            token: "test-token"
        )

        XCTAssertEqual(review.id, 5001)
        XCTAssertEqual(review.state, "APPROVED")
        XCTAssertEqual(review.body, "This rewrite is ready.")
        XCTAssertEqual(review.authorLogin, "sil")
        XCTAssertEqual(review.url, URL(string: "https://github.com/sil/gitbud/pull/12#pullrequestreview-5001"))
    }

    private static func data(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}

private final class PullRequestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: GitHubPullRequestError.invalidResponse)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
