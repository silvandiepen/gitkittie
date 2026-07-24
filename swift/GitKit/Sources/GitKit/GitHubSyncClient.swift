import Foundation

// A focused GitHub Git Data API client for git-free folder sync: read the repo tree and
// blobs, and write atomic commits (blob → tree → commit → ref). git-pont only exposes the
// per-file Contents API (one commit per file, ~1MB cap), so we implement the Data API here.
// Sandbox-safe (plain HTTPS via URLSession) and unit-testable via an injected HTTP client.

/// The minimal HTTP surface the client needs — injectable so tests can mock responses.
public protocol SyncHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionSyncHTTPClient: SyncHTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GitHubSyncError.invalidResponse
        }
        return (data, http)
    }
}

/// One entry in a recursive repo tree — a file (blob) or a directory (tree).
public struct GitHubTreeEntry: Equatable, Sendable {
    public var path: String
    public var sha: String
    public var mode: String
    public var size: Int
    public var isFile: Bool
}

/// A change to apply when building a new tree from a base tree.
public struct GitHubTreeChange: Equatable, Sendable {
    public var path: String
    public var mode: String
    /// The blob SHA for an add/modify, or nil to delete the path from the base tree.
    public var sha: String?

    public static func upsert(path: String, sha: String, mode: String = "100644") -> GitHubTreeChange {
        GitHubTreeChange(path: path, mode: mode, sha: sha)
    }
    public static func delete(path: String, mode: String = "100644") -> GitHubTreeChange {
        GitHubTreeChange(path: path, mode: mode, sha: nil)
    }
}

public enum GitHubSyncError: Error, Equatable, Sendable {
    case invalidResponse
    case http(status: Int, body: String)
    case decoding(String)
    /// A ref update was rejected because the branch moved under us (non-fast-forward).
    case notFastForward
}

/// Reads and writes a single GitHub repo/branch over the Git Data API.
public struct GitHubSyncClient: Sendable {
    private let token: String
    private let owner: String
    private let repo: String
    private let apiBase: URL
    private let http: SyncHTTPClient

    public init(
        token: String,
        owner: String,
        repo: String,
        apiBase: URL = URL(string: "https://api.github.com")!,
        http: SyncHTTPClient = URLSessionSyncHTTPClient()
    ) {
        self.token = token
        self.owner = owner
        self.repo = repo
        self.apiBase = apiBase
        self.http = http
    }

    // MARK: Reads

    /// The commit SHA at the tip of `branch`, or nil if the branch/repo is empty.
    public func branchHead(_ branch: String) async throws -> String? {
        let request = get("git/ref/heads/\(branch)")
        let (data, response) = try await http.send(request)
        if response.statusCode == 404 { return nil }
        try ensureOK(response, data)
        let ref = try decode(RefDTO.self, from: data)
        return ref.object.sha
    }

    /// The tree SHA a commit points at.
    public func commitTree(_ commitSHA: String) async throws -> String {
        let (data, response) = try await http.send(get("git/commits/\(commitSHA)"))
        try ensureOK(response, data)
        return try decode(CommitDTO.self, from: data).tree.sha
    }

    /// Every file/dir under a tree, recursively. `truncated` is true if GitHub capped the
    /// response (very large trees) — the caller should fall back to per-directory reads.
    public func tree(_ treeSHA: String) async throws -> (entries: [GitHubTreeEntry], truncated: Bool) {
        let (data, response) = try await http.send(get("git/trees/\(treeSHA)?recursive=1"))
        try ensureOK(response, data)
        let dto = try decode(TreeDTO.self, from: data)
        let entries = dto.tree.map {
            GitHubTreeEntry(path: $0.path, sha: $0.sha, mode: $0.mode, size: $0.size ?? 0, isFile: $0.type == "blob")
        }
        return (entries, dto.truncated)
    }

    /// The raw bytes of a blob (handles GitHub's base64 encoding, newlines and all).
    public func blob(_ sha: String) async throws -> Data {
        let (data, response) = try await http.send(get("git/blobs/\(sha)"))
        try ensureOK(response, data)
        let dto = try decode(BlobDTO.self, from: data)
        guard dto.encoding == "base64",
              let decoded = Data(base64Encoded: dto.content, options: .ignoreUnknownCharacters) else {
            throw GitHubSyncError.decoding("blob \(sha) was not base64")
        }
        return decoded
    }

    // MARK: Writes (atomic commit: blob → tree → commit → ref)

    /// Upload file content as a blob and return its SHA.
    public func createBlob(_ content: Data) async throws -> String {
        let body = BlobCreateDTO(content: content.base64EncodedString(), encoding: "base64")
        let (data, response) = try await http.send(post("git/blobs", body: body))
        try ensureOK(response, data)
        return try decode(ShaDTO.self, from: data).sha
    }

    /// Build a new tree by applying `changes` on top of `baseTree` (nil = from scratch).
    public func createTree(baseTree: String?, changes: [GitHubTreeChange]) async throws -> String {
        let body = TreeCreateDTO(
            baseTree: baseTree,
            tree: changes.map { TreeCreateEntryDTO(path: $0.path, mode: $0.mode, type: "blob", sha: $0.sha) }
        )
        let (data, response) = try await http.send(post("git/trees", body: body))
        try ensureOK(response, data)
        return try decode(ShaDTO.self, from: data).sha
    }

    /// Create a commit with the given tree and parents.
    public func createCommit(message: String, tree: String, parents: [String]) async throws -> String {
        let body = CommitCreateDTO(message: message, tree: tree, parents: parents)
        let (data, response) = try await http.send(post("git/commits", body: body))
        try ensureOK(response, data)
        return try decode(ShaDTO.self, from: data).sha
    }

    /// Point `branch` at `commitSHA`. Creates the ref if the branch is new. A non-forced
    /// update that isn't a fast-forward surfaces as `.notFastForward` so callers can retry.
    public func setBranch(_ branch: String, to commitSHA: String, force: Bool = false, createIfMissing: Bool = true) async throws {
        let (data, response) = try await http.send(
            patch("git/refs/heads/\(branch)", body: RefUpdateDTO(sha: commitSHA, force: force))
        )
        if response.statusCode == 422 {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.localizedCaseInsensitiveContains("fast forward") || body.localizedCaseInsensitiveContains("fast-forward") {
                throw GitHubSyncError.notFastForward
            }
        }
        if response.statusCode == 404, createIfMissing {
            let (cData, cResponse) = try await http.send(
                post("git/refs", body: RefCreateDTO(ref: "refs/heads/\(branch)", sha: commitSHA))
            )
            try ensureOK(cResponse, cData)
            return
        }
        try ensureOK(response, data)
    }

    // MARK: Request building

    private func base(_ path: String, method: String) -> URLRequest {
        // `path` may carry a query (e.g. "git/trees/<sha>?recursive=1"); split it off so the
        // path segment is escaped but the query stays a real query, not %3F in the path.
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let pathPart = String(parts[0])
        var components = URLComponents(
            url: apiBase.appendingPathComponent("repos/\(owner)/\(repo)/\(pathPart)"),
            resolvingAgainstBaseURL: false
        )!
        if parts.count == 2 { components.query = String(parts[1]) }

        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return request
    }

    private func get(_ path: String) -> URLRequest { base(path, method: "GET") }

    private func post<Body: Encodable>(_ path: String, body: Body) -> URLRequest { jsonRequest(path, method: "POST", body: body) }
    private func patch<Body: Encodable>(_ path: String, body: Body) -> URLRequest { jsonRequest(path, method: "PATCH", body: body) }

    private func jsonRequest<Body: Encodable>(_ path: String, method: String, body: Body) -> URLRequest {
        var request = base(path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        return request
    }

    private func ensureOK(_ response: HTTPURLResponse, _ data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw GitHubSyncError.http(status: response.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw GitHubSyncError.decoding("\(type): \(error)") }
    }
}

// MARK: - Wire DTOs

private struct RefDTO: Decodable { let object: Obj; struct Obj: Decodable { let sha: String } }
private struct CommitDTO: Decodable { let tree: Tree; struct Tree: Decodable { let sha: String } }
private struct ShaDTO: Decodable { let sha: String }

private struct TreeDTO: Decodable {
    let tree: [Entry]
    let truncated: Bool
    struct Entry: Decodable {
        let path: String
        let mode: String
        let type: String
        let sha: String
        let size: Int?
    }
}

private struct BlobDTO: Decodable { let content: String; let encoding: String }

private struct BlobCreateDTO: Encodable { let content: String; let encoding: String }

private struct TreeCreateDTO: Encodable {
    let baseTree: String?
    let tree: [TreeCreateEntryDTO]
    enum CodingKeys: String, CodingKey { case baseTree = "base_tree"; case tree }
}

/// A tree entry to create. When `sha` is nil the path is deleted from the base tree, which
/// GitHub expects as an explicit JSON `null` — so encode the key unconditionally.
private struct TreeCreateEntryDTO: Encodable {
    let path: String
    let mode: String
    let type: String
    let sha: String?
    enum CodingKeys: String, CodingKey { case path, mode, type, sha }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(mode, forKey: .mode)
        try c.encode(type, forKey: .type)
        if let sha { try c.encode(sha, forKey: .sha) } else { try c.encodeNil(forKey: .sha) }
    }
}

private struct CommitCreateDTO: Encodable { let message: String; let tree: String; let parents: [String] }
private struct RefUpdateDTO: Encodable { let sha: String; let force: Bool }
private struct RefCreateDTO: Encodable { let ref: String; let sha: String }
