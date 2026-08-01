import XCTest
@testable import GitKittieKit

/// Records requests and replays canned responses so the client is tested without network.
private final class MockHTTP: SyncHTTPClient, @unchecked Sendable {
    struct Stub { let status: Int; let body: String }
    var stubs: [Stub] = []
    private(set) var sent: [URLRequest] = []
    private var index = 0

    init(_ stubs: [Stub]) { self.stubs = stubs }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        sent.append(request)
        let stub = stubs[min(index, stubs.count - 1)]
        index += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        return (Data(stub.body.utf8), response)
    }

    var lastBodyJSON: [String: Any] {
        guard let body = sent.last?.httpBody,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return [:] }
        return obj
    }
}

final class GitHubSyncClientTests: XCTestCase {
    private func client(_ http: MockHTTP) -> GitHubSyncClient {
        GitHubSyncClient(token: "tok", owner: "octo", repo: "board", http: http)
    }

    func testBranchHeadParsesSHAAndSetsAuthHeaders() async throws {
        let http = MockHTTP([.init(status: 200, body: #"{"object":{"sha":"abc123"}}"#)])
        let head = try await client(http).branchHead("main")
        XCTAssertEqual(head, "abc123")

        let req = try XCTUnwrap(http.sent.first)
        XCTAssertEqual(req.httpMethod, "GET")
        XCTAssertEqual(req.url?.absoluteString, "https://api.github.com/repos/octo/board/git/ref/heads/main")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    func testBranchHeadReturnsNilOnEmptyRepo() async throws {
        let http = MockHTTP([.init(status: 404, body: #"{"message":"Not Found"}"#)])
        let head = try await client(http).branchHead("main")
        XCTAssertNil(head)
    }

    func testTreeParsesEntriesAndTruncation() async throws {
        let body = #"""
        {"truncated": false, "tree": [
          {"path":"a.md","mode":"100644","type":"blob","sha":"sha_a","size":12},
          {"path":"dir","mode":"040000","type":"tree","sha":"sha_dir"},
          {"path":"dir/b.md","mode":"100644","type":"blob","sha":"sha_b","size":7}
        ]}
        """#
        let http = MockHTTP([.init(status: 200, body: body)])
        let (entries, truncated) = try await client(http).tree("t1")
        XCTAssertFalse(truncated)
        XCTAssertEqual(entries.count, 3)
        let file = try XCTUnwrap(entries.first { $0.path == "a.md" })
        XCTAssertTrue(file.isFile)
        XCTAssertEqual(file.sha, "sha_a")
        XCTAssertEqual(file.size, 12)
        XCTAssertFalse(entries.first { $0.path == "dir" }!.isFile)
        XCTAssertEqual(http.sent.first?.url?.absoluteString, "https://api.github.com/repos/octo/board/git/trees/t1?recursive=1")
    }

    func testBlobDecodesBase64WithNewlines() async throws {
        // GitHub wraps base64 content in newlines; decoding must ignore them. Build the
        // JSON via JSONSerialization so the embedded newline is escaped correctly on the wire.
        let raw = "hello world\n"
        let b64 = Data(raw.utf8).base64EncodedString()
        let wrapped = String(b64.prefix(4)) + "\n" + String(b64.dropFirst(4))
        let bodyData = try JSONSerialization.data(withJSONObject: ["encoding": "base64", "content": wrapped])
        let http = MockHTTP([.init(status: 200, body: String(data: bodyData, encoding: .utf8)!)])
        let data = try await client(http).blob("sha_a")
        XCTAssertEqual(String(data: data, encoding: .utf8), raw)
    }

    func testCreateBlobSendsBase64AndReturnsSHA() async throws {
        let http = MockHTTP([.init(status: 201, body: #"{"sha":"new_blob"}"#)])
        let sha = try await client(http).createBlob(Data("content".utf8))
        XCTAssertEqual(sha, "new_blob")
        XCTAssertEqual(http.sent.last?.httpMethod, "POST")
        XCTAssertEqual(http.lastBodyJSON["encoding"] as? String, "base64")
        XCTAssertEqual(http.lastBodyJSON["content"] as? String, Data("content".utf8).base64EncodedString())
    }

    func testCreateTreeEncodesDeleteAsExplicitNull() async throws {
        let http = MockHTTP([.init(status: 201, body: #"{"sha":"new_tree"}"#)])
        _ = try await client(http).createTree(baseTree: "base", changes: [
            .upsert(path: "keep.md", sha: "sha_k"),
            .delete(path: "gone.md")
        ])
        XCTAssertEqual(http.lastBodyJSON["base_tree"] as? String, "base")
        let tree = try XCTUnwrap(http.lastBodyJSON["tree"] as? [[String: Any]])
        let gone = try XCTUnwrap(tree.first { $0["path"] as? String == "gone.md" })
        // A deletion must serialize as sha: null (present key, null value).
        XCTAssertTrue(gone["sha"] is NSNull, "delete must encode sha as explicit null")
        let keep = try XCTUnwrap(tree.first { $0["path"] as? String == "keep.md" })
        XCTAssertEqual(keep["sha"] as? String, "sha_k")
    }

    func testSetBranchDetectsNonFastForward() async throws {
        let http = MockHTTP([.init(status: 422, body: #"{"message":"Update is not a fast forward"}"#)])
        do {
            try await client(http).setBranch("main", to: "sha_new", force: false)
            XCTFail("expected notFastForward")
        } catch GitHubSyncError.notFastForward {
            // expected
        }
    }

    func testSetBranchCreatesRefWhenMissing() async throws {
        // PATCH → 404 (no such ref), then POST /git/refs to create it.
        let http = MockHTTP([
            .init(status: 404, body: #"{"message":"Not Found"}"#),
            .init(status: 201, body: #"{"ref":"refs/heads/main","object":{"sha":"sha_new"}}"#)
        ])
        try await client(http).setBranch("main", to: "sha_new")
        XCTAssertEqual(http.sent.count, 2)
        XCTAssertEqual(http.sent[0].httpMethod, "PATCH")
        XCTAssertEqual(http.sent[1].httpMethod, "POST")
        XCTAssertEqual(http.sent[1].url?.absoluteString, "https://api.github.com/repos/octo/board/git/refs")
        XCTAssertEqual(http.lastBodyJSON["ref"] as? String, "refs/heads/main")
    }
}
