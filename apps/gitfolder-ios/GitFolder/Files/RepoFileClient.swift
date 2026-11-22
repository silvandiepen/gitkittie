import Foundation
import GitPontCore

/// One entry in a repository directory listing.
struct RepoEntry: Identifiable, Hashable {
    let name: String
    let path: String
    let isDirectory: Bool
    var id: String { path }
}

/// A file view of a repository over a hosted git provider's REST API (via git-pont) —
/// the iOS transport. iOS has no `git` binary, so the app browses and edits files
/// directly through the API: list a directory, read a file, and write/delete files
/// (each write is one commit, pushed immediately).
struct RepoFileClient {
    let provider: any GitProvider
    let context: GitProviderRequestContext
    let repository: GitRepositoryReference
    let ref: String
    let connection: ProviderConnection
    let repoRef: RepoRef

    init(connection: ProviderConnection, ref repoRef: RepoRef) {
        self.provider = connection.provider
        self.context = connection.requestContext
        self.connection = connection
        self.repoRef = repoRef
        self.repository = GitRepositoryReference(
            instance: connection.instance,
            namespace: repoRef.namespace,
            name: repoRef.name,
            defaultBranch: repoRef.branch
        )
        self.ref = repoRef.branch
    }

    /// List a directory (empty string = repo root), folders first then files, A→Z.
    func list(_ directory: String) async throws -> [RepoEntry] {
        let reference = GitFileReference(repository: repository, path: directory, ref: ref)
        let result = try await provider.listDirectory(reference, context: context)
        return result.items
            .map { RepoEntry(name: $0.name, path: $0.path, isDirectory: $0.type == .directory) }
            .sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }

    /// Read a UTF-8 file's text.
    func readText(_ path: String) async throws -> String {
        let reference = GitFileReference(repository: repository, path: path, ref: ref)
        let file = try await provider.readFile(reference, context: context)
        guard let text = String(data: file.content, encoding: .utf8) else {
            throw GitPontError.invalidProviderResponse("File is not UTF-8 text: \(path)")
        }
        return text
    }

    /// Read a file's raw bytes (for images and other binary content).
    func readData(_ path: String) async throws -> Data {
        let reference = GitFileReference(repository: repository, path: path, ref: ref)
        return try await provider.readFile(reference, context: context).content
    }

    /// Create or overwrite a file with `text` in one commit (last-writer-wins).
    func write(path: String, text: String, message: String) async throws {
        try await writeData(path: path, data: Data(text.utf8), message: message)
    }

    /// Create or overwrite a file with raw bytes in one commit (for binary files).
    func writeData(path: String, data: Data, message: String) async throws {
        let change = GitFileChange(
            reference: GitFileReference(repository: repository, path: path, ref: ref),
            content: data,
            message: message,
            targetBranch: ref,
            allowBlindOverwrite: true
        )
        _ = try await provider.commitFile(change, context: context)
    }

    /// Delete a file in one commit, whatever version of it is there now.
    func delete(path: String, message: String) async throws {
        let request = GitFileDeleteRequest(
            reference: GitFileReference(repository: repository, path: path, ref: ref),
            message: message, targetBranch: ref, expectedVersion: nil, allowBlindOverwrite: true)
        _ = try await provider.deleteFile(request, context: context)
    }
}
