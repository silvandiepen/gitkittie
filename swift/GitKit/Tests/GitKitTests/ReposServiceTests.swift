import XCTest
@testable import GitKit

final class ReposServiceTests: XCTestCase {
    override func tearDown() {
        ReposURLProtocol.handler = nil
        super.tearDown()
    }

    func testReposServiceIsConstructible() {
        _ = GitHubReposService(userAgent: "GitKitTests")
    }

    func testDecodesUserReposArray() throws {
        let json = """
        [
          {
            "name": "gitfolder",
            "full_name": "sil/gitfolder",
            "private": false,
            "owner": { "login": "sil", "id": 1 },
            "clone_url": "https://github.com/sil/gitfolder.git",
            "default_branch": "main"
          },
          {
            "name": "secret-lab",
            "full_name": "acme/secret-lab",
            "private": true,
            "owner": { "login": "acme", "id": 2 },
            "clone_url": "https://github.com/acme/secret-lab.git",
            "default_branch": "develop"
          }
        ]
        """
        let repos = try JSONDecoder().decode([GitHubRepo].self, from: Data(json.utf8))
        XCTAssertEqual(repos.count, 2)

        let first = repos[0]
        XCTAssertEqual(first.name, "gitfolder")
        XCTAssertEqual(first.fullName, "sil/gitfolder")
        XCTAssertEqual(first.id, "sil/gitfolder")
        XCTAssertEqual(first.ownerLogin, "sil")
        XCTAssertEqual(first.cloneURL, URL(string: "https://github.com/sil/gitfolder.git"))
        XCTAssertEqual(first.defaultBranch, "main")
        XCTAssertFalse(first.isPrivate)

        let second = repos[1]
        XCTAssertEqual(second.ownerLogin, "acme")
        XCTAssertEqual(second.defaultBranch, "develop")
        XCTAssertTrue(second.isPrivate)
    }

    func testListRepositoriesFollowsNextPaginationLink() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReposURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let service = GitHubReposService(
            session: session,
            apiBaseURL: URL(string: "https://api.example.test")!,
            userAgent: "GitKitTests"
        )
        var requestedURLs: [String] = []

        ReposURLProtocol.handler = { request in
            requestedURLs.append(request.url?.absoluteString ?? "")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer repo-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GitKitTests")

            switch request.url?.absoluteString {
            case "https://api.example.test/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Content-Type": "application/json",
                        "Link": "<https://api.example.test/user/repos?page=2&per_page=100>; rel=\"next\", <https://api.example.test/user/repos?page=2&per_page=100>; rel=\"last\""
                    ]
                )!
                return (response, Self.reposPageJSON(name: "first", fullName: "sil/first"))
            case "https://api.example.test/user/repos?page=2&per_page=100":
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, Self.reposPageJSON(name: "second", fullName: "sil/second"))
            default:
                XCTFail("Unexpected URL: \(request.url?.absoluteString ?? "<nil>")")
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data("[]".utf8))
            }
        }

        let repositories = try await service.listRepositories(token: "repo-token")

        XCTAssertEqual(requestedURLs, [
            "https://api.example.test/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator,organization_member",
            "https://api.example.test/user/repos?page=2&per_page=100"
        ])
        XCTAssertEqual(repositories.map(\.fullName), ["sil/first", "sil/second"])
    }

    private static func reposPageJSON(name: String, fullName: String) -> Data {
        Data("""
        [
          {
            "name": "\(name)",
            "full_name": "\(fullName)",
            "private": false,
            "owner": { "login": "sil", "id": 1 },
            "clone_url": "https://github.com/\(fullName).git",
            "default_branch": "main"
          }
        ]
        """.utf8)
    }
}

private final class ReposURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: GitHubReposError.invalidResponse)
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
