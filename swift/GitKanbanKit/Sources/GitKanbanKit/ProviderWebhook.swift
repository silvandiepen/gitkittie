import Foundation
import GitPontCore

/// The push webhook a repo's provider calls the relay with. git-pont makes the calls;
/// this turns its answers into something to show.
enum ProviderWebhook {
    /// Create the webhook on `repo` (`owner/name`, or `group/sub/name`). Returns its id.
    static func create(with connection: ProviderConnection, repo: String, url: String, secret: String) async throws -> Int {
        guard connection.provider.capabilities.contains(.webhooks), let address = URL(string: url) else {
            throw BoardSourceError(message: "The webhook was not created: \(connection.instance.displayName) has no webhooks here.")
        }
        do {
            let hook = try await connection.provider.createWebhook(
                GitWebhookRequest(repository: reference(connection.instance, repo), url: address, secret: secret, name: "Tasks live updates"),
                context: connection.requestContext)
            // The id is kept as a number in `.gitkanban/relay.json`, which older builds read.
            guard let id = Int(hook.id) else {
                throw BoardSourceError(message: "The webhook was created, but \(connection.instance.displayName) gave it an id Tasks cannot keep.")
            }
            return id
        } catch let error as GitPontError {
            let reason: String
            switch error {
            case .authenticationFailed, .authenticationRequired, .permissionDenied, .notFound:
                reason = "this account is not allowed to add webhooks to \(repo). It needs admin access to the repository (on GitLab: the Maintainer role and a token with the api scope)."
            case .conflict:
                reason = "\(connection.instance.displayName) did not accept the relay's address."
            default:
                reason = "\(connection.instance.displayName) answered with an error (\(error))."
            }
            throw BoardSourceError(message: "The webhook was not created: \(reason)")
        }
    }

    static func remove(_ hookID: Int, with connection: ProviderConnection, repo: String) async {
        try? await connection.provider.deleteWebhook(
            id: String(hookID), repository: reference(connection.instance, repo), context: connection.requestContext)
    }

    /// `group/sub/name` → namespace `group/sub`, name `name`.
    static func reference(_ instance: GitProviderInstance, _ repo: String) -> GitRepositoryReference {
        let parts = repo.split(separator: "/")
        return GitRepositoryReference(instance: instance, namespace: parts.dropLast().joined(separator: "/"), name: String(parts.last ?? ""))
    }
}
