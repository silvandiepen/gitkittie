import AppKit
import AuthenticationServices
import CryptoKit
import Foundation

struct CloudflareAccount: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

struct CloudflareBucket: Codable, Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let jurisdiction: String?
}

struct CloudflareConnection: Sendable {
    let accessToken: String
    let accounts: [CloudflareAccount]
}

@MainActor
final class CloudflareStorageConnectionService: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var authenticationSession: ASWebAuthenticationSession?
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func connect(clientID: String) async throws -> CloudflareConnection {
        guard !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudflareConnectionError.missingClientID
        }
        let verifier = Self.codeVerifier()
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = UUID().uuidString
        let redirectURI = "http://127.0.0.1:53682/oauth/cloudflare"
        var components = URLComponents(string: "https://dash.cloudflare.com/oauth2/auth")!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let authorizationURL = components.url else { throw CloudflareConnectionError.invalidResponse }
        let callbackURL = try await authenticate(at: authorizationURL)
        guard let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              callback.queryItems?.first(where: { $0.name == "state" })?.value == state,
              let code = callback.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw CloudflareConnectionError.invalidCallback
        }

        let token = try await exchangeCode(code, verifier: verifier, clientID: clientID, redirectURI: redirectURI)
        let accounts: [CloudflareAccount] = try await api(path: "/accounts", token: token)
        return CloudflareConnection(accessToken: token, accounts: accounts)
    }

    func buckets(accountID: String, token: String) async throws -> [CloudflareBucket] {
        struct BucketResult: Decodable { let buckets: [CloudflareBucket] }
        let result: BucketResult = try await api(path: "/accounts/\(accountID)/r2/buckets", token: token)
        return result.buckets.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func createBucket(name: String, accountID: String, token: String) async throws -> CloudflareBucket {
        try await api(
            path: "/accounts/\(accountID)/r2/buckets",
            method: "POST",
            token: token,
            body: ["name": name]
        )
    }

    func provisionCredentials(bucket: CloudflareBucket, accountID: String, token: String) async throws -> S3Credentials {
        struct PermissionGroup: Decodable { let id: String; let name: String }
        let groups: [PermissionGroup] = try await api(
            path: "/accounts/\(accountID)/tokens/permission_groups?name=Workers%20R2%20Storage%20Bucket%20Item%20Write",
            token: token
        )
        guard let group = groups.first(where: { $0.name == "Workers R2 Storage Bucket Item Write" }) else {
            throw CloudflareConnectionError.missingR2Permission
        }
        let jurisdiction = bucket.jurisdiction ?? "default"
        let resource = "com.cloudflare.edge.r2.bucket.\(accountID)_\(jurisdiction)_\(bucket.name)"
        let payload: [String: Any] = [
            "name": "GitFolder – \(bucket.name)",
            "policies": [[
                "id": UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
                "effect": "allow",
                "resources": [resource: "*"],
                "permission_groups": [["id": group.id]]
            ]]
        ]
        struct TokenResult: Decodable { let id: String; let value: String }
        let result: TokenResult = try await api(
            path: "/accounts/\(accountID)/tokens",
            method: "POST",
            token: token,
            jsonBody: payload
        )
        let secret = SHA256.hash(data: Data(result.value.utf8)).map { String(format: "%02x", $0) }.joined()
        return S3Credentials(accessKeyID: result.id, secretAccessKey: secret)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }

    private func authenticate(at url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "http") { callbackURL, error in
                if let error { continuation.resume(throwing: error) }
                else if let callbackURL { continuation.resume(returning: callbackURL) }
                else { continuation.resume(throwing: CloudflareConnectionError.invalidCallback) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            authenticationSession = session
            guard session.start() else {
                continuation.resume(throwing: CloudflareConnectionError.couldNotStartAuthentication)
                return
            }
        }
    }

    private func exchangeCode(_ code: String, verifier: String, clientID: String, redirectURI: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://dash.cloudflare.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formData([
            "grant_type": "authorization_code",
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ])
        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response, data: data)
        struct TokenResponse: Decodable { let access_token: String }
        return try JSONDecoder().decode(TokenResponse.self, from: data).access_token
    }

    private func api<Result: Decodable>(
        path: String,
        method: String = "GET",
        token: String,
        body: [String: String]? = nil,
        jsonBody: [String: Any]? = nil
    ) async throws -> Result {
        guard let url = URL(string: "https://api.cloudflare.com/client/v4" + path) else {
            throw CloudflareConnectionError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        } else if let jsonBody {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response, data: data)
        let envelope = try JSONDecoder().decode(CloudflareEnvelope<Result>.self, from: data)
        guard envelope.success, let result = envelope.result else {
            throw CloudflareConnectionError.api(envelope.errors.first?.message ?? "Cloudflare rejected the request.")
        }
        return result
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw CloudflareConnectionError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(CloudflareErrorEnvelope.self, from: data).errors.first?.message)
            throw CloudflareConnectionError.api(message ?? "Cloudflare returned HTTP \(response.statusCode).")
        }
    }

    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formData(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let text = values.sorted { $0.key < $1.key }.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }
}

private struct CloudflareEnvelope<Result: Decodable>: Decodable {
    let success: Bool
    let result: Result?
    let errors: [CloudflareAPIError]
}

private struct CloudflareErrorEnvelope: Decodable { let errors: [CloudflareAPIError] }
private struct CloudflareAPIError: Decodable { let message: String }

enum CloudflareConnectionError: LocalizedError {
    case missingClientID
    case invalidCallback
    case invalidResponse
    case couldNotStartAuthentication
    case missingR2Permission
    case api(String)

    var errorDescription: String? {
        switch self {
        case .missingClientID: "Cloudflare login needs the GitFolder OAuth client ID."
        case .invalidCallback: "Cloudflare returned an invalid login callback."
        case .invalidResponse: "Cloudflare returned an invalid response."
        case .couldNotStartAuthentication: "The Cloudflare login window could not be opened."
        case .missingR2Permission: "The Cloudflare connection cannot provision an R2 write key."
        case .api(let message): message
        }
    }
}
