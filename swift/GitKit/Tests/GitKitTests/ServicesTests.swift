import XCTest
@testable import GitKit

/// Compile/link-level checks that the shared services expose a usable public API.
/// (Keychain and network calls are not exercised here — they need entitlements /
/// live endpoints; those are covered by the apps' integration tests.)
final class ServicesTests: XCTestCase {
    override func tearDown() {
        OAuthURLProtocol.handler = nil
        super.tearDown()
    }

    func testKeychainServiceIsConstructible() {
        _ = KeychainService(service: "app.hakobs.gitkit.tests", account: "token")
    }

    func testOAuthServiceIsConstructible() {
        _ = GitHubOAuthService(clientID: "test-client-id", userAgent: "GitKitTests")
    }

    func testDeviceAuthorizationValueSemantics() {
        let url = URL(string: "https://github.com/login/device")!
        let a = GitHubDeviceAuthorization(deviceCode: "d", userCode: "u", verificationURI: url, expiresIn: 900, interval: 5)
        let b = a
        XCTAssertEqual(a, b)
    }

    func testOAuthDeviceAuthorizationPostsExpectedRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OAuthURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = GitHubOAuthService(
            clientID: "client-123",
            scope: "repo read:user",
            userAgent: "GitKitTests",
            session: session
        )

        OAuthURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://github.com/login/device/code")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBodyStream.flatMap(Self.data(from:))), encoding: .utf8))
            let components = Set(body.split(separator: "&").map(String.init))
            XCTAssertEqual(components, ["client_id=client-123", "scope=repo%20read:user"])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data("""
            {
              "device_code": "device-abc",
              "user_code": "ABCD-EFGH",
              "verification_uri": "https://github.com/login/device",
              "expires_in": 900,
              "interval": 5
            }
            """.utf8)
            return (response, data)
        }

        let authorization = try await service.requestDeviceAuthorization()

        XCTAssertEqual(authorization.deviceCode, "device-abc")
        XCTAssertEqual(authorization.userCode, "ABCD-EFGH")
        XCTAssertEqual(authorization.verificationURI, URL(string: "https://github.com/login/device"))
        XCTAssertEqual(authorization.expiresIn, 900)
        XCTAssertEqual(authorization.interval, 5)
    }

    private static func data(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}

private final class OAuthURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: GitHubOAuthError.invalidResponse)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
