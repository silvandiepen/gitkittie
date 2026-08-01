import Foundation

public struct GitHubPullRequestDraft: Equatable, Sendable {
    public var repositoryFullName: String
    public var title: String
    public var body: String
    public var head: String
    public var base: String
    public var draft: Bool

    public init(
        repositoryFullName: String,
        title: String,
        body: String,
        head: String,
        base: String,
        draft: Bool = true
    ) {
        self.repositoryFullName = repositoryFullName
        self.title = title
        self.body = body
        self.head = head
        self.base = base
        self.draft = draft
    }
}

public struct GitHubPullRequest: Equatable, Sendable, Identifiable {
    public var number: Int
    public var title: String
    public var url: URL
    public var head: String
    public var headSHA: String?
    public var base: String
    public var state: String
    public var isDraft: Bool

    public var id: Int { number }

    public init(
        number: Int,
        title: String,
        url: URL,
        head: String,
        headSHA: String? = nil,
        base: String,
        state: String = "open",
        isDraft: Bool = false
    ) {
        self.number = number
        self.title = title
        self.url = url
        self.head = head
        self.headSHA = headSHA
        self.base = base
        self.state = state
        self.isDraft = isDraft
    }
}

public struct GitHubPullRequestReviewSummary: Equatable, Sendable {
    public var pullRequest: GitHubPullRequest
    public var additions: Int
    public var deletions: Int
    public var changedFiles: Int
    public var commitCount: Int
    public var issueComments: Int
    public var reviewComments: Int
    public var mergeable: Bool?
    public var mergeableState: String?
    public var approvals: Int
    public var requestedChanges: Int
    public var reviewCommentThreads: Int
    public var files: [GitHubPullRequestFile]
    public var inlineComments: [GitHubPullRequestInlineComment]

    public init(
        pullRequest: GitHubPullRequest,
        additions: Int,
        deletions: Int,
        changedFiles: Int,
        commitCount: Int,
        issueComments: Int,
        reviewComments: Int,
        mergeable: Bool?,
        mergeableState: String?,
        approvals: Int,
        requestedChanges: Int,
        reviewCommentThreads: Int,
        files: [GitHubPullRequestFile] = [],
        inlineComments: [GitHubPullRequestInlineComment] = []
    ) {
        self.pullRequest = pullRequest
        self.additions = additions
        self.deletions = deletions
        self.changedFiles = changedFiles
        self.commitCount = commitCount
        self.issueComments = issueComments
        self.reviewComments = reviewComments
        self.mergeable = mergeable
        self.mergeableState = mergeableState
        self.approvals = approvals
        self.requestedChanges = requestedChanges
        self.reviewCommentThreads = reviewCommentThreads
        self.files = files
        self.inlineComments = inlineComments
    }

    public func inlineComments(for file: GitHubPullRequestFile) -> [GitHubPullRequestInlineComment] {
        inlineComments.filter { $0.path == file.path }
    }
}

public struct GitHubPullRequestFile: Equatable, Sendable, Identifiable {
    public var path: String
    public var status: String
    public var additions: Int
    public var deletions: Int
    public var changes: Int
    public var previousPath: String?
    public var patch: String?

    public var id: String { path }

    public init(
        path: String,
        status: String,
        additions: Int,
        deletions: Int,
        changes: Int,
        previousPath: String? = nil,
        patch: String? = nil
    ) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.changes = changes
        self.previousPath = previousPath
        self.patch = patch
    }
}

public struct GitHubPullRequestInlineComment: Equatable, Sendable, Identifiable {
    public var id: Int
    public var path: String
    public var body: String
    public var authorLogin: String
    public var url: URL?
    public var line: Int?
    public var originalLine: Int?
    public var side: String?
    public var diffHunk: String?

    public init(
        id: Int,
        path: String,
        body: String,
        authorLogin: String,
        url: URL? = nil,
        line: Int? = nil,
        originalLine: Int? = nil,
        side: String? = nil,
        diffHunk: String? = nil
    ) {
        self.id = id
        self.path = path
        self.body = body
        self.authorLogin = authorLogin
        self.url = url
        self.line = line
        self.originalLine = originalLine
        self.side = side
        self.diffHunk = diffHunk
    }
}

public struct GitHubPullRequestInlineCommentDraft: Equatable, Sendable {
    public var body: String
    public var commitID: String
    public var path: String
    public var line: Int
    public var side: String

    public init(body: String, commitID: String, path: String, line: Int, side: String = "RIGHT") {
        self.body = body
        self.commitID = commitID
        self.path = path
        self.line = line
        self.side = side
    }
}

public enum GitHubPullRequestReviewEvent: String, Equatable, Sendable, CaseIterable {
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"
    case comment = "COMMENT"
}

public struct GitHubPullRequestSubmittedReview: Equatable, Sendable, Identifiable {
    public var id: Int
    public var state: String
    public var body: String
    public var authorLogin: String
    public var url: URL?

    public init(id: Int, state: String, body: String, authorLogin: String, url: URL? = nil) {
        self.id = id
        self.state = state
        self.body = body
        self.authorLogin = authorLogin
        self.url = url
    }
}

public struct GitHubPullRequestService: Sendable {
    private let session: URLSession
    private let apiBaseURL: URL
    private let userAgent: String

    public init(
        session: URLSession = .shared,
        apiBaseURL: URL = URL(string: "https://api.github.com")!,
        userAgent: String = "GitKittie"
    ) {
        self.session = session
        self.apiBaseURL = apiBaseURL
        self.userAgent = userAgent
    }

    public func createPullRequest(_ draft: GitHubPullRequestDraft, token: String) async throws -> GitHubPullRequest {
        let repository = try parseRepositoryFullName(draft.repositoryFullName)
        let url = apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repository.owner)
            .appendingPathComponent(repository.name)
            .appendingPathComponent("pulls")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(CreatePullRequestBody(
            title: draft.title,
            body: draft.body,
            head: draft.head,
            base: draft.base,
            draft: draft.draft
        ))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubPullRequestError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw GitHubPullRequestError.requestFailed(status: httpResponse.statusCode)
        }

        do {
            let decoded = try JSONDecoder().decode(CreatePullRequestResponse.self, from: data)
            guard let url = URL(string: decoded.htmlURL) else {
                throw GitHubPullRequestError.invalidResponse
            }
            return GitHubPullRequest(
                number: decoded.number,
                title: decoded.title,
                url: url,
                head: decoded.head.ref,
                headSHA: decoded.head.sha,
                base: decoded.base.ref,
                state: decoded.state ?? "open",
                isDraft: decoded.draft ?? draft.draft
            )
        } catch let error as GitHubPullRequestError {
            throw error
        } catch {
            throw GitHubPullRequestError.invalidResponse
        }
    }

    public func listPullRequests(repositoryFullName: String, token: String, state: String = "open") async throws -> [GitHubPullRequest] {
        let repository = try parseRepositoryFullName(repositoryFullName)
        var components = URLComponents(
            url: apiBaseURL
                .appendingPathComponent("repos")
                .appendingPathComponent(repository.owner)
                .appendingPathComponent(repository.name)
                .appendingPathComponent("pulls"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "per_page", value: "25"),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "direction", value: "desc"),
        ]
        guard let url = components?.url else {
            throw GitHubPullRequestError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubPullRequestError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw GitHubPullRequestError.requestFailed(status: httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode([CreatePullRequestResponse].self, from: data).compactMap { decoded in
                guard let url = URL(string: decoded.htmlURL) else { return nil }
                return GitHubPullRequest(
                    number: decoded.number,
                    title: decoded.title,
                    url: url,
                    head: decoded.head.ref,
                    headSHA: decoded.head.sha,
                    base: decoded.base.ref,
                    state: decoded.state ?? state,
                    isDraft: decoded.draft ?? false
                )
            }
        } catch {
            throw GitHubPullRequestError.invalidResponse
        }
    }

    public func pullRequestReviewSummary(repositoryFullName: String, number: Int, token: String) async throws -> GitHubPullRequestReviewSummary {
        let repository = try parseRepositoryFullName(repositoryFullName)
        async let detail = pullRequestDetail(repository: repository, number: number, token: token)
        async let reviews = pullRequestReviews(repository: repository, number: number, token: token)
        async let files = pullRequestFiles(repository: repository, number: number, token: token)
        async let inlineComments = pullRequestInlineComments(repository: repository, number: number, token: token)
        let (decoded, decodedReviews, decodedFiles, decodedInlineComments) = try await (detail, reviews, files, inlineComments)
        guard let url = URL(string: decoded.htmlURL) else {
            throw GitHubPullRequestError.invalidResponse
        }
        let pullRequest = GitHubPullRequest(
            number: decoded.number,
            title: decoded.title,
            url: url,
            head: decoded.head.ref,
            headSHA: decoded.head.sha,
            base: decoded.base.ref,
            state: decoded.state ?? "open",
            isDraft: decoded.draft ?? false
        )
        return GitHubPullRequestReviewSummary(
            pullRequest: pullRequest,
            additions: decoded.additions ?? 0,
            deletions: decoded.deletions ?? 0,
            changedFiles: decoded.changedFiles ?? 0,
            commitCount: decoded.commits ?? 0,
            issueComments: decoded.comments ?? 0,
            reviewComments: decoded.reviewComments ?? 0,
            mergeable: decoded.mergeable,
            mergeableState: decoded.mergeableState,
            approvals: decodedReviews.filter { $0.state == "APPROVED" }.count,
            requestedChanges: decodedReviews.filter { $0.state == "CHANGES_REQUESTED" }.count,
            reviewCommentThreads: decodedReviews.filter { $0.state == "COMMENTED" }.count,
            files: decodedFiles.map {
                GitHubPullRequestFile(
                    path: $0.filename,
                    status: $0.status,
                    additions: $0.additions,
                    deletions: $0.deletions,
                    changes: $0.changes,
                    previousPath: $0.previousFilename,
                    patch: $0.patch
                )
            },
            inlineComments: decodedInlineComments.compactMap {
                try? decodeInlineComment($0)
            }
        )
    }

    public func replyToPullRequestInlineComment(
        repositoryFullName: String,
        number: Int,
        commentID: Int,
        body: String,
        token: String
    ) async throws -> GitHubPullRequestInlineComment {
        let repository = try parseRepositoryFullName(repositoryFullName)
        let url = apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repository.owner)
            .appendingPathComponent(repository.name)
            .appendingPathComponent("pulls")
            .appendingPathComponent(String(number))
            .appendingPathComponent("comments")
            .appendingPathComponent(String(commentID))
            .appendingPathComponent("replies")
        let data = try await request(
            url: url,
            token: token,
            method: "POST",
            body: ReplyToPullRequestCommentBody(body: body)
        )
        do {
            return try decodeInlineComment(data)
        } catch {
            throw GitHubPullRequestError.invalidResponse
        }
    }

    public func createPullRequestInlineComment(
        repositoryFullName: String,
        number: Int,
        draft: GitHubPullRequestInlineCommentDraft,
        token: String
    ) async throws -> GitHubPullRequestInlineComment {
        let repository = try parseRepositoryFullName(repositoryFullName)
        let url = apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repository.owner)
            .appendingPathComponent(repository.name)
            .appendingPathComponent("pulls")
            .appendingPathComponent(String(number))
            .appendingPathComponent("comments")
        let data = try await request(
            url: url,
            token: token,
            method: "POST",
            body: CreatePullRequestInlineCommentBody(
                body: draft.body,
                commitID: draft.commitID,
                path: draft.path,
                line: draft.line,
                side: draft.side
            )
        )
        do {
            return try decodeInlineComment(data)
        } catch {
            throw GitHubPullRequestError.invalidResponse
        }
    }

    public func submitPullRequestReview(
        repositoryFullName: String,
        number: Int,
        event: GitHubPullRequestReviewEvent,
        body: String,
        token: String
    ) async throws -> GitHubPullRequestSubmittedReview {
        let repository = try parseRepositoryFullName(repositoryFullName)
        let url = apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repository.owner)
            .appendingPathComponent(repository.name)
            .appendingPathComponent("pulls")
            .appendingPathComponent(String(number))
            .appendingPathComponent("reviews")
        let data = try await request(
            url: url,
            token: token,
            method: "POST",
            body: SubmitPullRequestReviewBody(body: body, event: event.rawValue)
        )
        do {
            let decoded = try JSONDecoder().decode(SubmitPullRequestReviewResponse.self, from: data)
            return GitHubPullRequestSubmittedReview(
                id: decoded.id,
                state: decoded.state,
                body: decoded.body ?? "",
                authorLogin: decoded.user?.login ?? "unknown",
                url: decoded.htmlURL.flatMap(URL.init(string:))
            )
        } catch {
            throw GitHubPullRequestError.invalidResponse
        }
    }

    private func parseRepositoryFullName(_ fullName: String) throws -> (owner: String, name: String) {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw GitHubPullRequestError.invalidRepository
        }
        return (parts[0], parts[1])
    }

    private func pullRequestDetail(repository: (owner: String, name: String), number: Int, token: String) async throws -> PullRequestDetailResponse {
        let url = apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repository.owner)
            .appendingPathComponent(repository.name)
            .appendingPathComponent("pulls")
            .appendingPathComponent(String(number))
        let data = try await request(url: url, token: token)
        do {
            return try JSONDecoder().decode(PullRequestDetailResponse.self, from: data)
        } catch {
            throw GitHubPullRequestError.invalidResponse
        }
    }

    private func pullRequestReviews(repository: (owner: String, name: String), number: Int, token: String) async throws -> [PullRequestReviewResponse] {
        var components = URLComponents(
            url: apiBaseURL
                .appendingPathComponent("repos")
                .appendingPathComponent(repository.owner)
                .appendingPathComponent(repository.name)
                .appendingPathComponent("pulls")
                .appendingPathComponent(String(number))
                .appendingPathComponent("reviews"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        guard let url = components?.url else {
            throw GitHubPullRequestError.invalidResponse
        }
        let data = try await request(url: url, token: token)
        do {
            return try JSONDecoder().decode([PullRequestReviewResponse].self, from: data)
        } catch {
            throw GitHubPullRequestError.invalidResponse
        }
    }

    private func pullRequestFiles(repository: (owner: String, name: String), number: Int, token: String) async throws -> [PullRequestFileResponse] {
        var components = URLComponents(
            url: apiBaseURL
                .appendingPathComponent("repos")
                .appendingPathComponent(repository.owner)
                .appendingPathComponent(repository.name)
                .appendingPathComponent("pulls")
                .appendingPathComponent(String(number))
                .appendingPathComponent("files"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        guard let url = components?.url else {
            throw GitHubPullRequestError.invalidResponse
        }
        let data = try await request(url: url, token: token)
        do {
            return try JSONDecoder().decode([PullRequestFileResponse].self, from: data)
        } catch {
            throw GitHubPullRequestError.invalidResponse
        }
    }

    private func pullRequestInlineComments(repository: (owner: String, name: String), number: Int, token: String) async throws -> [PullRequestInlineCommentResponse] {
        var components = URLComponents(
            url: apiBaseURL
                .appendingPathComponent("repos")
                .appendingPathComponent(repository.owner)
                .appendingPathComponent(repository.name)
                .appendingPathComponent("pulls")
                .appendingPathComponent(String(number))
                .appendingPathComponent("comments"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        guard let url = components?.url else {
            throw GitHubPullRequestError.invalidResponse
        }
        let data = try await request(url: url, token: token)
        do {
            return try JSONDecoder().decode([PullRequestInlineCommentResponse].self, from: data)
        } catch {
            throw GitHubPullRequestError.invalidResponse
        }
    }

    private func request(url: URL, token: String) async throws -> Data {
        try await request(url: url, token: token, method: "GET", body: Optional<Data>.none)
    }

    private func request<T: Encodable>(url: URL, token: String, method: String, body: T?) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubPullRequestError.invalidResponse
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw GitHubPullRequestError.requestFailed(status: httpResponse.statusCode)
        }
        return data
    }

    private func decodeInlineComment(_ data: Data) throws -> GitHubPullRequestInlineComment {
        try decodeInlineComment(JSONDecoder().decode(PullRequestInlineCommentResponse.self, from: data))
    }

    private func decodeInlineComment(_ decoded: PullRequestInlineCommentResponse) throws -> GitHubPullRequestInlineComment {
        GitHubPullRequestInlineComment(
            id: decoded.id,
            path: decoded.path,
            body: decoded.body,
            authorLogin: decoded.user?.login ?? "unknown",
            url: decoded.htmlURL.flatMap(URL.init(string:)),
            line: decoded.line,
            originalLine: decoded.originalLine,
            side: decoded.side,
            diffHunk: decoded.diffHunk
        )
    }
}

public enum GitHubPullRequestError: LocalizedError, Equatable, Sendable {
    case invalidRepository
    case invalidResponse
    case requestFailed(status: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRepository:
            return "Select a provider repository before creating a pull request."
        case .invalidResponse:
            return "GitHub returned an invalid pull request response."
        case let .requestFailed(status):
            return "GitHub returned an unexpected pull request response (HTTP \(status))."
        }
    }
}

private struct CreatePullRequestBody: Encodable {
    var title: String
    var body: String
    var head: String
    var base: String
    var draft: Bool
}

private struct ReplyToPullRequestCommentBody: Encodable {
    var body: String
}

private struct CreatePullRequestInlineCommentBody: Encodable {
    var body: String
    var commitID: String
    var path: String
    var line: Int
    var side: String

    private enum CodingKeys: String, CodingKey {
        case body
        case commitID = "commit_id"
        case path
        case line
        case side
    }
}

private struct SubmitPullRequestReviewBody: Encodable {
    var body: String
    var event: String
}

private struct CreatePullRequestResponse: Decodable {
    var number: Int
    var title: String
    var htmlURL: String
    var head: Ref
    var base: Ref
    var state: String?
    var draft: Bool?

    private enum CodingKeys: String, CodingKey {
        case number
        case title
        case htmlURL = "html_url"
        case head
        case base
        case state
        case draft
    }

    struct Ref: Decodable {
        var ref: String
        var sha: String?
    }
}

private struct PullRequestDetailResponse: Decodable {
    var number: Int
    var title: String
    var htmlURL: String
    var head: CreatePullRequestResponse.Ref
    var base: CreatePullRequestResponse.Ref
    var state: String?
    var draft: Bool?
    var mergeable: Bool?
    var mergeableState: String?
    var comments: Int?
    var reviewComments: Int?
    var commits: Int?
    var additions: Int?
    var deletions: Int?
    var changedFiles: Int?

    private enum CodingKeys: String, CodingKey {
        case number
        case title
        case htmlURL = "html_url"
        case head
        case base
        case state
        case draft
        case mergeable
        case mergeableState = "mergeable_state"
        case comments
        case reviewComments = "review_comments"
        case commits
        case additions
        case deletions
        case changedFiles = "changed_files"
    }
}

private struct PullRequestReviewResponse: Decodable {
    var state: String
}

private struct PullRequestFileResponse: Decodable {
    var filename: String
    var status: String
    var additions: Int
    var deletions: Int
    var changes: Int
    var previousFilename: String?
    var patch: String?

    private enum CodingKeys: String, CodingKey {
        case filename
        case status
        case additions
        case deletions
        case changes
        case previousFilename = "previous_filename"
        case patch
    }
}

private struct PullRequestInlineCommentResponse: Decodable {
    var id: Int
    var path: String
    var body: String
    var htmlURL: String?
    var user: User?
    var line: Int?
    var originalLine: Int?
    var side: String?
    var diffHunk: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case path
        case body
        case htmlURL = "html_url"
        case user
        case line
        case originalLine = "original_line"
        case side
        case diffHunk = "diff_hunk"
    }

    struct User: Decodable {
        var login: String
    }
}

private struct SubmitPullRequestReviewResponse: Decodable {
    var id: Int
    var state: String
    var body: String?
    var htmlURL: String?
    var user: PullRequestInlineCommentResponse.User?

    private enum CodingKeys: String, CodingKey {
        case id
        case state
        case body
        case htmlURL = "html_url"
        case user
    }
}
