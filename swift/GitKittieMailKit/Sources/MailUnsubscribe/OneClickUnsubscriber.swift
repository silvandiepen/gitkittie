import Foundation
import os

// The only network request unsubscribe ever makes (GKM-020; RFC 8058; ThreatModel §9; MAIL-056):
// one POST of `List-Unsubscribe=One-Click` to an approved HTTPS endpoint. The session is
// ephemeral and stores nothing: no cookies sent or kept, no cache, no credentials, no
// authentication answered. Redirects are not followed, except a 307/308 to the same host over
// HTTPS (which keeps the POST), at most twice, each checked again like the first URL.

/// What happened to a one-click request. A request the list accepted is not proof that you are
/// unsubscribed; the ledger keeps it pending until mail stops (or doesn't).
public enum OneClickResult: Sendable, Equatable {
    /// 2xx: the list accepted the request.
    case accepted(status: Int)
    /// 4xx/5xx: the list refused or failed.
    case rejected(status: Int)
    /// A redirect the app did not follow; the host it pointed to, if any.
    case redirectRefused(status: Int, host: String?)
    /// The endpoint failed the policy check right before sending; nothing was sent.
    case refused(EndpointProblem)
    /// The network failed (offline, timeout, TLS); the message is the system's.
    case failed(String)
}

public final class OneClickUnsubscriber: Sendable {
    public static let maxSameHostRedirects = 2
    public let policy: EndpointPolicy
    public let timeout: TimeInterval

    public init(policy: EndpointPolicy = .standard, timeout: TimeInterval = 20) {
        self.policy = policy
        self.timeout = timeout
    }

    /// The session configuration: nothing persists, nothing is sent that the request doesn't set.
    static func configuration(timeout: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.httpAdditionalHeaders = ["User-Agent": "GitKittieMail-Unsubscribe/1"]
        return configuration
    }

    /// The request RFC 8058 describes, and nothing more.
    static func request(_ url: URL, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        return request
    }

    /// Sends the request. Call only after you approved this exact URL.
    public func unsubscribe(_ url: URL) async -> OneClickResult {
        if let problem = policy.problem(with: url) { return .refused(problem) }
        let guardian = RedirectGuard(origin: url, policy: policy)
        let session = URLSession(configuration: Self.configuration(timeout: timeout), delegate: guardian, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let response = try await Self.send(Self.request(url, timeout: timeout), on: session)
            // A redirect the guard refused is known from the guard, not from the response: CFNetwork
            // sometimes finishes such a task with no response and no error (GKM-077).
            if let refused = guardian.refused { return .redirectRefused(status: refused.status, host: refused.host) }
            guard let http = response as? HTTPURLResponse else { return .failed("No HTTP response.") }
            switch http.statusCode {
            case 200..<300: return .accepted(status: http.statusCode)
            case 300..<400: return .redirectRefused(status: http.statusCode, host: Self.locationHost(of: http))
            default: return .rejected(status: http.statusCode)
            }
        } catch {
            if let refused = guardian.refused { return .redirectRefused(status: refused.status, host: refused.host) }
            return .failed(error.localizedDescription)
        }
    }

    /// The host a redirect's Location points to, resolved against the URL that answered.
    static func locationHost(of response: HTTPURLResponse) -> String? {
        response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: response.url) }?.host
    }

    /// One data task, its response or its error. Not `URLSession.data(for:)`: that force-unwraps the
    /// response, and when a delegate refuses a redirect CFNetwork sometimes completes the task with
    /// no response and no error, which crashed the process (GKM-077).
    static func send(_ request: URLRequest, on session: URLSession) async throws -> URLResponse? {
        let running = OSAllocatedUnfairLock<URLSessionDataTask?>(initialState: nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request) { _, response, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: response) }
                }
                running.withLock { $0 = task }
                task.resume()
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            running.withLock { $0 }?.cancel()
        }
    }
}

/// Follows a redirect only when it keeps the POST (307, 308), stays on the same host over HTTPS
/// (or the same test loopback), passes the policy, and is one of the first two. Answers no
/// authentication challenge but the server's TLS certificate, checked the system's way.
final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let origin: URL
    private let policy: EndpointPolicy
    private let followed = OSAllocatedUnfairLock(initialState: 0)
    private let refusal = OSAllocatedUnfairLock<(status: Int, host: String?)?>(initialState: nil)

    /// The redirect this guard refused, if it refused one: its status and the host it pointed to.
    var refused: (status: Int, host: String?)? { refusal.withLock { $0 } }

    init(origin: URL, policy: EndpointPolicy) {
        self.origin = origin
        self.policy = policy
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let mayFollow = followed.withLock { count in
            guard count < OneClickUnsubscriber.maxSameHostRedirects else { return false }
            count += 1
            return true
        }
        guard [307, 308].contains(response.statusCode), mayFollow,
              let target = request.url, target.host?.lowercased() == origin.host?.lowercased(),
              target.scheme?.lowercased() == origin.scheme?.lowercased(), target.port == origin.port,
              policy.problem(with: target) == nil, request.httpMethod == "POST" else {
            refusal.withLock { $0 = (response.statusCode, OneClickUnsubscriber.locationHost(of: response)) }
            completionHandler(nil)
            return
        }
        var safe = OneClickUnsubscriber.request(target, timeout: request.timeoutInterval)
        safe.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        completionHandler(safe)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}
