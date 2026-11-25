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
        return try await described(path, "read") { try await provider.readFile(reference, context: context).content }
    }

    /// Every text file of a folder in one request, where the provider can: a lane of a
    /// hundred cards is otherwise a hundred requests. `nil` for providers that cannot and
    /// whenever it does not work, so the caller reads file by file as before.
    func readTexts(in directory: String) async -> [String: String]? {
        guard provider.capabilities.contains(.directoryTextRead) else { return nil }
        let reference = GitFileReference(repository: repository, path: full(directory), ref: ref)
        return try? await provider.readTextFiles(inDirectory: reference, context: context)
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

    /// Delete a file in one commit, whatever version of it is there now.
    func delete(path: String, message: String) async throws {
        let request = GitFileDeleteRequest(
            reference: GitFileReference(repository: repository, path: full(path), ref: ref),
            message: message, targetBranch: ref, expectedVersion: nil, allowBlindOverwrite: true)
        _ = try await described(path, "delete") { try await provider.deleteFile(request, context: context) }
    }

}

extension GitPontFileSource: VersionedBoardSource {
    /// The text and the version the provider names for it (a blob sha on GitHub, a commit
    /// on GitLab), written down as JSON so it can travel as a string.
    func readVersioned(_ path: String) async throws -> (text: String, version: String?) {
        let reference = GitFileReference(repository: repository, path: full(path), ref: ref)
        let file = try await described(path, "read") { try await provider.readFile(reference, context: context) }
        guard let text = String(data: file.content, encoding: .utf8) else { throw BoardSourceError(message: "\(path) is not a text file.") }
        let version = try file.version.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        return (text, version)
    }

    func write(path: String, text: String, ifVersion version: String?) async throws {
        try await write(path: path, text: text, ifVersion: version, message: "Update \(path)")
    }

    /// Write only over the version read: the provider refuses it when the file changed in
    /// between, and that comes back as `SourceConflictError`.
    func write(path: String, text: String, ifVersion version: String?, message: String) async throws {
        let reference = GitFileReference(repository: repository, path: full(path), ref: ref)
        let expected = try version.map { try JSONDecoder().decode(GitRemoteVersion.self, from: Data($0.utf8)) }
        let change = GitFileChange(reference: reference, content: Data(text.utf8), message: message, targetBranch: ref,
                                   expectedVersion: expected, allowBlindOverwrite: false)
        do {
            _ = try await provider.commitFile(change, context: context)
        } catch GitPontError.conflict {
            throw SourceConflictError(path: path)
        } catch {
            throw Self.readable(error, path: path, action: "save")
        }
    }
}

extension GitPontFileSource: WebLinkingSource {
    func webURL(forPath path: String) -> URL? {
        provider.webURL(for: GitFileReference(repository: repository, path: full(path), ref: ref))
    }
}

extension GitPontFileSource: TreeListingSource {
    func listFiles(under directory: String) async -> [BoardFileEntry]? {
        guard provider.capabilities.contains(.treeList) else { return nil }
        let reference = GitFileReference(repository: repository, path: full(directory), ref: ref)
        guard let tree = try? await provider.listTree(reference, context: context), !tree.truncated else { return nil }
        let prefix = basePath.isEmpty ? "" : basePath + "/"
        return tree.items.filter { $0.type == .file }.map { entry in
            // Paths come back as repository paths; callers work relative to this source.
            let relative = !prefix.isEmpty && entry.path.hasPrefix(prefix) ? String(entry.path.dropFirst(prefix.count)) : entry.path
            return BoardFileEntry(name: entry.name, path: relative, kind: .file)
        }
    }
}

extension GitPontFileSource: BatchWritable {
    /// One commit for all the files, where the provider can. The commit is built on the
    /// branch as it is now and not forced, so a push in between refuses it and nothing changes.
    func writeTexts(_ texts: [String: String], message: String) async throws -> Bool {
        guard provider.capabilities.contains(.batchCommit), !texts.isEmpty else { return false }
        let commit = GitMultiFileCommit(
            repository: repository, branch: ref, message: message,
            operations: texts.sorted { $0.key < $1.key }.map { .write(full($0.key), Data($0.value.utf8)) })
        _ = try await described("\(texts.count) files", "save") { try await provider.commitFiles(commit, context: context) }
        return true
    }
}

extension GitPontFileSource {

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
        if case .conflict = error { return BoardSourceError(message: "\(what): \(why)", isConflict: true) }
        return BoardSourceError(message: "\(what): \(why)")
    }
}

/// A board-source failure with text a person can act on.
struct BoardSourceError: LocalizedError {
    let message: String
    /// The file changed on the server between reading it and writing it.
    var isConflict = false
    var errorDescription: String? { message }
}
