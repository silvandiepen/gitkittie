import Foundation
import GitKittieKit
import GitPontCore
import GitPontGitHub

/// A `BoardFileSource` backed by a hosted git provider's REST API through git-pont —
/// the transport for both GitKanban apps. There is no local clone: the board is read
/// directly over the API (directory listings and file contents for a repo + branch)
/// and written with `commitFile`/`deleteFile`.
///
/// It is provider-agnostic: pass any git-pont provider (`GitHubProvider`,
/// `GitLabProvider`, …) and its `GitProviderInstance` (including a self-hosted GitLab
/// base URL), so GitHub, GitLab cloud, and custom GitLab installs all load the same
/// way. Writes will use `commitFile`/`deleteFile` in a later step; this is the read
/// path the board loads through.
struct GitPontFileSource: BoardFileSource, BulkTextSource {
    private let provider: any GitProvider
    private let context: GitProviderRequestContext
    private let repository: GitRepositoryReference
    private let ref: String
    /// A subfolder the source is rooted at; all paths are relative to it.
    private let basePath: String

    /// Prefix a source-relative path with the base folder to get the real repo path.
    private func full(_ path: String) -> String {
        guard !basePath.isEmpty else { return path }
        return path.isEmpty ? basePath : "\(basePath)/\(path)"
    }

    init(
        provider: any GitProvider,
        instance: GitProviderInstance,
        owner: String,
        repo: String,
        branch: String,
        token: String,
        basePath: String = ""
    ) {
        self.provider = provider
        self.basePath = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let now = Date()
        let connection = GitConnection(
            id: "gitkanban",
            instance: instance,
            accountID: "account",
            accountLogin: owner,
            authMethod: .personalAccessToken,
            createdAt: now,
            updatedAt: now
        )
        self.context = GitProviderRequestContext(
            connection: connection,
            credential: GitCredential(accessToken: token)
        )
        self.repository = GitRepositoryReference(
            instance: instance, namespace: owner, name: repo, defaultBranch: branch
        )
        self.ref = branch
    }

    /// Convenience for a github.com repo.
    static func gitHub(owner: String, repo: String, branch: String, token: String) -> GitPontFileSource {
        GitPontFileSource(
            provider: GitHubProvider(httpClient: UncachedHTTPClient()),
            instance: .github,
            owner: owner, repo: repo, branch: branch, token: token
        )
    }

    func list(_ directory: String) async throws -> [BoardFileEntry] {
        let reference = GitFileReference(repository: repository, path: full(directory), ref: ref)
        let result = try await described(directory, "list") { try await provider.listDirectory(reference, context: context) }
        return result.items.map { entry in
            // Keep returned paths source-relative (relative to basePath) so callers can
            // feed them straight back to list/readText.
            let relative = directory.isEmpty ? entry.name : "\(directory)/\(entry.name)"
            return BoardFileEntry(
                name: entry.name,
                path: relative,
                kind: entry.type == .directory ? .directory : .file
            )
        }
    }

    func readText(_ path: String) async throws -> String {
        let data = try await readData(path)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BoardSourceError(message: "\(path) is not a text file.")
        }
        return text
    }

    /// A file's raw bytes (for attachments/images).
    func readData(_ path: String) async throws -> Data {
        let reference = GitFileReference(repository: repository, path: full(path), ref: ref)
        do {
            return try await provider.readFile(reference, context: context).content
        } catch GitPontError.fileTooLarge where provider is GitHubProvider {
            // GitHub's JSON contents endpoint only inlines files up to 1 MB, and git-pont
            // reports anything bigger as too large. Screenshots and review assets pass
            // that easily, so fetch those through the raw media type (up to 100 MB).
            // This belongs in git-pont's GitHubProvider; see GITKITTIE-022.
            return try await described(path, "read") { try await readRawFromGitHub(full(path)) }
        } catch {
            throw Self.readable(error, path: path, action: "read")
        }
    }

    /// Every text file of a folder in one GraphQL request (GitHub only): the REST API has
    /// no way to read more than one file per request, which makes a lane of a hundred
    /// cards a hundred requests. `nil` for other providers and whenever it does not work,
    /// so the caller reads file by file as before. Belongs in git-pont; see GITKITTIE-022.
    func readTexts(in directory: String) async -> [String: String]? {
        guard provider is GitHubProvider, let token = context.credential?.accessToken else { return nil }
        let query = """
        query($owner: String!, $name: String!, $expression: String!) {
          repository(owner: $owner, name: $name) {
            object(expression: $expression) {
              ... on Tree { entries { name type object { ... on Blob { text isTruncated } } } }
            }
          }
        }
        """
        let variables = ["owner": repository.namespace, "name": repository.name, "expression": "\(ref):\(full(directory))"]
        var request = URLRequest(url: GitProviderInstance.github.apiBaseURL.appendingPathComponent("graphql"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        guard let (data, response) = try? await UncachedHTTPClient.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.texts(inGraphQLTree: data)
    }

    /// File name → text out of the GraphQL answer; `nil` when it holds no folder.
    static func texts(inGraphQLTree data: Data) -> [String: String]? {
        struct Answer: Decodable {
            struct Payload: Decodable { let repository: Repository? }
            struct Repository: Decodable { let object: Tree? }
            struct Tree: Decodable { let entries: [Entry]? }
            struct Entry: Decodable { let name: String; let type: String; let object: Blob? }
            struct Blob: Decodable { let text: String?; let isTruncated: Bool? }
            let data: Payload?
        }
        guard let entries = (try? JSONDecoder().decode(Answer.self, from: data))?.data?.repository?.object?.entries else { return nil }
        var texts: [String: String] = [:]
        // Binary and cut-off files carry no usable text: leave them to a single read.
        for entry in entries where entry.type == "blob" {
            if let text = entry.object?.text, entry.object?.isTruncated != true { texts[entry.name] = text }
        }
        return texts
    }

    private func readRawFromGitHub(_ path: String) async throws -> Data {
        guard let token = context.credential?.accessToken else { throw GitPontError.authenticationRequired }
        let base = GitProviderInstance.github.apiBaseURL
            .appendingPathComponent("repos").appendingPathComponent(repository.namespace)
            .appendingPathComponent(repository.name).appendingPathComponent("contents")
            .appendingPathComponent(path)
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "ref", value: ref)]
        guard let url = components?.url else { throw GitPontError.unsupportedURL(path) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await UncachedHTTPClient.session.data(for: request)
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200..<300: return data
        case 401: throw GitPontError.authenticationFailed("GitHub authentication failed")
        case 403: throw GitPontError.permissionDenied("GitHub permission denied")
        case 404: throw GitPontError.notFound("GitHub resource not found")
        case let status: throw GitPontError.invalidProviderResponse("GitHub returned \(status)")
        }
    }

    // MARK: Writes

    /// Create or overwrite a file with `text` in one commit (last-writer-wins).
    func write(path: String, text: String, message: String) async throws {
        try await writeData(path: path, data: Data(text.utf8), message: message)
    }

    /// Create or overwrite a file with raw bytes in one commit (for binary attachments).
    func writeData(path: String, data: Data, message: String) async throws {
        let reference = GitFileReference(repository: repository, path: full(path), ref: ref)
        func change(replacing version: GitRemoteVersion?) -> GitFileChange {
            GitFileChange(reference: reference, content: data, message: message, targetBranch: ref,
                          expectedVersion: version, allowBlindOverwrite: true)
        }
        try await described(path, "save") {
            do {
                // Most writes create a file, so try without a version first.
                _ = try await provider.commitFile(change(replacing: nil), context: context)
            } catch GitPontError.conflict {
                // The file exists: GitHub rejects an update that does not name the blob
                // it replaces. Look the current version up and send it.
                guard let current = try? await provider.readFile(reference, context: context).version else { throw GitPontError.conflict(GitConflict(reference: reference)) }
                _ = try await provider.commitFile(change(replacing: current), context: context)
            }
        }
    }

    /// Delete a file in one commit. Fetches the current version first (providers that
    /// require the blob sha to delete), falling back to a blind delete.
    func delete(path: String, message: String) async throws {
        let reference = GitFileReference(repository: repository, path: full(path), ref: ref)
        let version = try? await provider.readFile(reference, context: context).version
        let request = GitFileDeleteRequest(
            reference: reference,
            message: message,
            targetBranch: ref,
            expectedVersion: version,
            allowBlindOverwrite: version == nil
        )
        _ = try await described(path, "delete") { try await provider.deleteFile(request, context: context) }
    }

    // MARK: Errors

    private func described<T>(_ path: String, _ action: String, _ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch { throw Self.readable(error, path: path, action: action) }
    }

    /// git-pont's errors carry no user-facing text, so on their own they surface as
    /// "GitPontError error 7". Say what failed and on which file instead.
    static func readable(_ error: Error, path: String, action: String) -> Error {
        guard let error = error as? GitPontError else { return error }
        let what = "Could not \(action) \(path.isEmpty ? "the repository root" : path)"
        let why: String
        switch error {
        case .notFound:
            why = action == "read" || action == "list"
                ? "it was not found. It may have been moved or renamed."
                : "the repository refused it as not found. This usually means the signed-in account or token cannot write to this repository."
        case .authenticationRequired, .authenticationFailed:
            why = "the sign-in is no longer valid. Sign in again."
        case .permissionDenied:
            why = "this account is not allowed to. Check the token's access to the repository."
        case .conflict(let conflict):
            why = "it changed on the server in the meantime" + (conflict.providerMessage.map { " (\($0))" } ?? "") + ". Reload and try again."
        case .fileTooLarge(let size, _):
            why = "the file is too large" + (size.map { " (\($0 / 1_000_000) MB)" } ?? "") + "."
        case .rateLimited:
            why = "the provider is rate limiting requests. Try again in a minute."
        case .providerUnavailable(let message), .invalidProviderResponse(let message), .unsupportedCapability(let message):
            why = message
        default:
            why = "\(error)"
        }
        return BoardSourceError(message: "\(what): \(why)")
    }
}

/// A board-source failure with text a person can act on.
struct BoardSourceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
