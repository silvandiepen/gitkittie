import Foundation
import GitPontCore

/// The push webhook a repo's provider calls the relay with. git-pont has no webhook
/// calls, so these go to the provider's REST API directly.
enum ProviderWebhook {
    /// GitLab addresses a project by its URL-encoded path (`group%2Fsub%2Fname`).
    static func gitLabProjectID(_ repo: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return repo.addingPercentEncoding(withAllowedCharacters: allowed) ?? repo
    }

    /// The request that creates a push webhook on `repo` (`owner/name`) calling `url`.
    /// GitHub signs each delivery with `secret`; GitLab sends it back as `X-Gitlab-Token`.
    static func createRequest(on instance: GitProviderInstance, repo: String, token: String,
                              url: String, secret: String) throws -> URLRequest {
        var request = URLRequest(url: hooksURL(instance, repo: repo, hookID: nil))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, instance: instance, token: token)
        let body: [String: Any]
        switch instance.kind {
        case .github:
            body = ["name": "web", "active": true, "events": ["push"],
                    "config": ["url": url, "content_type": "json", "secret": secret]]
        default:
            body = ["url": url, "token": secret, "push_events": true, "enable_ssl_verification": true,
                    "name": "Tasks live updates"]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Create the webhook. Returns its id.
    static func create(on instance: GitProviderInstance, repo: String, token: String,
                       url: String, secret: String) async throws -> Int {
        let request = try createRequest(on: instance, repo: repo, token: token, url: url, secret: secret)
        let (data, response) = try await UncachedHTTPClient.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int else {
            let reason: String
            switch status {
            case 401, 403, 404:
                reason = instance.kind == .github
                    ? "this account is not allowed to add webhooks to \(repo) (it needs admin access)."
                    : "this account is not allowed to add webhooks to \(repo) (it needs the Maintainer role and a token with the api scope)."
            case 422:
                reason = "\(instance.displayName) did not accept the relay's address."
            default:
                reason = "\(instance.displayName) answered \(status)."
            }
            throw BoardSourceError(message: "The webhook was not created: \(reason)")
        }
        return id
    }

    static func remove(_ hookID: Int, on instance: GitProviderInstance, repo: String, token: String) async {
        var request = URLRequest(url: hooksURL(instance, repo: repo, hookID: hookID))
        request.httpMethod = "DELETE"
        authorize(&request, instance: instance, token: token)
        _ = try? await UncachedHTTPClient.session.data(for: request)
    }

    static func hooksURL(_ instance: GitProviderInstance, repo: String, hookID: Int?) -> URL {
        let base = instance.apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let hooks = instance.kind == .github
            ? "\(base)/repos/\(repo)/hooks"
            : "\(base)/projects/\(gitLabProjectID(repo))/hooks"
        // Built from a provider base URL and an encoded path, so it always parses.
        return URL(string: hookID.map { "\(hooks)/\($0)" } ?? hooks)!
    }

    private static func authorize(_ request: inout URLRequest, instance: GitProviderInstance, token: String) {
        if instance.kind == .github {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        } else {
            request.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")
        }
    }
}
