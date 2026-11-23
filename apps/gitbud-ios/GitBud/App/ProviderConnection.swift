import Foundation
import GitPontCore

/// Which host a connection targets. Self-hosted GitLab carries its own server URL.
enum ProviderChoice: String, CaseIterable, Identifiable, Codable {
    case github
    case gitlabCloud
    case gitlabSelfHosted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .github: return "GitHub"
        case .gitlabCloud: return "GitLab.com"
        case .gitlabSelfHosted: return "GitLab (self-hosted)"
        }
    }

    var needsServerURL: Bool { self == .gitlabSelfHosted }
}

/// The active connection: the GitPont provider, its instance, and the request context
/// (token and account) every call carries.
struct ProviderConnection {
    let choice: ProviderChoice?
    let instance: GitProviderInstance
    let provider: any GitProvider
    let token: String
    let login: String

    var context: GitProviderRequestContext {
        let now = Date()
        let connection = GitConnection(
            id: instance.id, instance: instance, accountID: login, accountLogin: login,
            authMethod: .personalAccessToken, createdAt: now, updatedAt: now)
        return GitProviderRequestContext(connection: connection, credential: GitCredential(accessToken: token))
    }

    /// "Pull request" or "merge request", as the host calls it.
    var changeRequestName: String {
        provider.changeRequestTerm == .mergeRequest ? "merge request" : "pull request"
    }
}
