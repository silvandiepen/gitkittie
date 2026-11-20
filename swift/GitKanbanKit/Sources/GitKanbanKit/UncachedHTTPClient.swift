import Foundation
import GitPontCore

/// The HTTP client GitKanban hands to git-pont's providers. It never serves a cached
/// response.
///
/// git-pont's own `URLSessionHTTPClient` uses `URLSession.shared`, which honours GitHub's
/// `Cache-Control: max-age=60`. For a board that is wrong twice over: after a write, the
/// next read returns the file as it was before (a decision you just made still shows as
/// pending), and the version taken from that stale read makes the following write fail
/// as a conflict. Every read here has to be the server's current state.
public struct UncachedHTTPClient: HTTPClient {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    public init() {}

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await Self.session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw GitPontError.invalidProviderResponse("Response was not HTTP")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String { headers[key] = String(describing: value) }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}
