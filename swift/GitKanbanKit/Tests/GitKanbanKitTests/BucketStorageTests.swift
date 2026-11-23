import XCTest
import GitKittieKit
@testable import GitKanbanKit

/// A stand-in for an S3-compatible server: it keeps what is PUT and answers HEAD and GET,
/// for the signed API address and the public address alike.
final class FakeBucketProtocol: URLProtocol {
    struct Object { let data: Data; let sha: String?; let type: String? }
    nonisolated(unsafe) static var objects: [String: Object] = [:]
    nonisolated(unsafe) static var requests: [(method: String, path: String, signed: Bool)] = []
    static let lock = NSLock()

    static func reset() { lock.lock(); objects = [:]; requests = []; lock.unlock() }
    static func puts() -> Int { lock.lock(); defer { lock.unlock() }; return requests.filter { $0.method == "PUT" }.count }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let method = request.httpMethod ?? "GET"
        // The API address is path-style (/bucket/key); the public address is /key.
        var key = url.path
        if url.host == "s3.test" { key = "/" + key.split(separator: "/").dropFirst().joined(separator: "/") }
        Self.lock.lock()
        Self.requests.append((method, key, request.value(forHTTPHeaderField: "Authorization") != nil))
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        switch method {
        case "PUT":
            let data = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
            Self.objects[key] = Object(data: data, sha: request.value(forHTTPHeaderField: "x-amz-meta-gitfolder-sha256"),
                                       type: request.value(forHTTPHeaderField: "content-type"))
        case "HEAD", "GET":
            if key == "/" || key.isEmpty {
                status = 200
            } else if let object = Self.objects[key] {
                if let sha = object.sha { headers["x-amz-meta-gitfolder-sha256"] = sha }
                if method == "GET" { body = object.data }
            } else {
                status = 404
            }
        default:
            status = 405
        }
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class BucketStorageTests: XCTestCase {
    private let config = BoardStorageConfig(endpoint: "https://s3.test", bucket: "assets", publicBaseURL: "https://files.test")
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4, 5])

    override func setUp() { FakeBucketProtocol.reset() }

    private func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FakeBucketProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// A source over an in-memory repository, with or without settings and keys.
    private func source(_ base: InMemoryBoardSource, settings: BoardStorageConfig?, hasKeys: Bool = true) async throws -> BucketSource {
        if let settings { await base.write(path: BoardStorageConfig.path, text: try settings.encoded(), message: "settings") }
        let session = session()
        return BucketSource(
            base: base, repoKey: UUID().uuidString,
            keys: { _ in hasKeys ? S3Credentials(accessKeyID: "id", secretAccessKey: "secret") : nil },
            service: S3StorageService(session: session), session: session, cache: BucketConfigCache())
    }

    func testOnlyBinaryFilesWithAnExtensionAreOffloaded() {
        XCTAssertTrue(BucketSource.offloads("Pets/attachments/PETS-1/shot.png"))
        XCTAssertTrue(BucketSource.offloads("Pets/review/r1/theme.MP3"))
        XCTAssertFalse(BucketSource.offloads("Pets/review/r1/review.md"))
        XCTAssertFalse(BucketSource.offloads(".tasks/storage.json"))
        XCTAssertFalse(BucketSource.offloads("Pets/attachments/PETS-1/shot.png.bucket"))
        XCTAssertFalse(BucketSource.offloads("Pets/LICENSE"))
        XCTAssertFalse(BucketSource.offloads("Pets/.gitkeep"))
    }

    func testABinaryWriteGoesToTheBucketAndLeavesAPointer() async throws {
        let base = InMemoryBoardSource(files: [:])
        let source = try await source(base, settings: config)
        try await source.writeData(path: "Pets/attachments/PETS-1/shot.png", data: png, message: "Attach")

        // The repository holds the pointer, not the picture.
        let pointerText = try await base.readText("Pets/attachments/PETS-1/shot.png.bucket")
        let pointer = try XCTUnwrap(BucketPointer.decode(pointerText))
        let sha = S3StorageService.sha256(png)
        XCTAssertEqual(pointer.sha256, sha)
        XCTAssertEqual(pointer.size, png.count)
        XCTAssertEqual(pointer.key, "tasks/v1/objects/\(sha.prefix(2))/\(sha).png")
        XCTAssertEqual(pointer.url, "https://files.test/tasks/v1/objects/\(sha.prefix(2))/\(sha).png")
        XCTAssertEqual(pointer.contentType, "image/png")
        let names = await base.list("Pets/attachments/PETS-1").map(\.name)
        XCTAssertEqual(names, ["shot.png.bucket"])

        // The bucket holds the picture, sent with a signed request.
        let stored = try XCTUnwrap(FakeBucketProtocol.objects["/" + pointer.key])
        XCTAssertEqual(stored.data, png)
        XCTAssertEqual(stored.type, "image/png")
        XCTAssertTrue(FakeBucketProtocol.requests.contains { $0.method == "PUT" && $0.signed })

        // Reading and listing show the file as if it were in the repository.
        let read = try await source.readData("Pets/attachments/PETS-1/shot.png")
        XCTAssertEqual(read, png)
        let listed = try await source.list("Pets/attachments/PETS-1")
        XCTAssertEqual(listed.map(\.name), ["shot.png"])
        XCTAssertEqual(listed.first?.path, "Pets/attachments/PETS-1/shot.png")
        // The read came from the public address, without keys.
        XCTAssertTrue(FakeBucketProtocol.requests.contains { $0.method == "GET" && !$0.signed })
    }

    func testTextStaysInTheRepository() async throws {
        let base = InMemoryBoardSource(files: [:])
        let source = try await source(base, settings: config)
        try await source.writeData(path: "Pets/review/r1/review.md", data: Data("# Review".utf8), message: "Request")
        let stored = try await base.readData("Pets/review/r1/review.md")
        XCTAssertEqual(stored, Data("# Review".utf8))
        XCTAssertEqual(FakeBucketProtocol.puts(), 0)
    }

    func testWithoutSettingsOrKeysTheFileGoesToTheRepository() async throws {
        let plain = InMemoryBoardSource(files: [:])
        try await source(plain, settings: nil).writeData(path: "a/shot.png", data: png, message: "Attach")
        let inPlain = try await plain.readData("a/shot.png")
        XCTAssertEqual(inPlain, png)

        let noKeys = InMemoryBoardSource(files: [:])
        try await source(noKeys, settings: config, hasKeys: false).writeData(path: "a/shot.png", data: png, message: "Attach")
        let inNoKeys = try await noKeys.readData("a/shot.png")
        XCTAssertEqual(inNoKeys, png)

        var off = config
        off.enabled = false
        let disabled = InMemoryBoardSource(files: [:])
        try await source(disabled, settings: off).writeData(path: "a/shot.png", data: png, message: "Attach")
        let inDisabled = try await disabled.readData("a/shot.png")
        XCTAssertEqual(inDisabled, png)
        XCTAssertEqual(FakeBucketProtocol.puts(), 0)
    }

    func testAFileFromBeforeTheBucketStillOpens() async throws {
        let base = InMemoryBoardSource(files: [:])
        await base.writeData(path: "a/old.png", data: png, message: "Old")
        let source = try await source(base, settings: config)
        let read = try await source.readData("a/old.png")
        XCTAssertEqual(read, png)
        XCTAssertTrue(FakeBucketProtocol.requests.isEmpty)
    }

    func testTheSameContentIsUploadedOnce() async throws {
        let base = InMemoryBoardSource(files: [:])
        let source = try await source(base, settings: config)
        try await source.writeData(path: "a/one.png", data: png, message: "Attach")
        try await source.writeData(path: "b/two.png", data: png, message: "Attach")
        XCTAssertEqual(FakeBucketProtocol.puts(), 1)
        let second = try await source.readData("b/two.png")
        XCTAssertEqual(second, png)
    }

    func testReplacingAFileInTheRepositoryRemovesTheOldCopy() async throws {
        let base = InMemoryBoardSource(files: [:])
        await base.writeData(path: "a/shot.png", data: Data([1, 2, 3]), message: "Old")
        let source = try await source(base, settings: config)
        try await source.writeData(path: "a/shot.png", data: png, message: "Annotate")
        let read = try await source.readData("a/shot.png")
        XCTAssertEqual(read, png)
        let names = await base.list("a").map(\.name)
        XCTAssertEqual(names, ["shot.png.bucket"])
    }

    func testDeletingAnOffloadedFileRemovesItsPointer() async throws {
        let base = InMemoryBoardSource(files: [:])
        let source = try await source(base, settings: config)
        try await source.writeData(path: "a/shot.png", data: png, message: "Attach")
        try await source.delete(path: "a/shot.png", message: "Remove")
        let left = try await source.list("a")
        XCTAssertTrue(left.isEmpty)
    }

    func testADamagedDownloadIsRefused() async throws {
        let base = InMemoryBoardSource(files: [:])
        let source = try await source(base, settings: config)
        try await source.writeData(path: "a/shot.png", data: png, message: "Attach")
        let sha = S3StorageService.sha256(png)
        FakeBucketProtocol.objects["/tasks/v1/objects/\(sha.prefix(2))/\(sha).png"] = .init(data: Data([9, 9]), sha: sha, type: nil)
        do {
            _ = try await source.readData("a/shot.png")
            XCTFail("A file that does not match its pointer must not be handed over.")
        } catch {}
    }

    func testWithoutAPublicAddressReadingUsesTheKeys() async throws {
        var privateOnly = config
        privateOnly.publicBaseURL = ""
        let base = InMemoryBoardSource(files: [:])
        let source = try await source(base, settings: privateOnly)
        try await source.writeData(path: "a/shot.png", data: png, message: "Attach")
        let pointerText = try await base.readText("a/shot.png.bucket")
        XCTAssertNil(BucketPointer.decode(pointerText)?.url)
        let read = try await source.readData("a/shot.png")
        XCTAssertEqual(read, png)
        XCTAssertTrue(FakeBucketProtocol.requests.contains { $0.method == "GET" && $0.signed })
    }

    func testMovingAnExistingFileToTheBucket() async throws {
        let base = InMemoryBoardSource(files: [:])
        await base.writeData(path: "a/old.png", data: png, message: "Old")
        let source = try await source(base, settings: config)
        try await source.offloadExisting("a/old.png")
        let names = await base.list("a").map(\.name)
        XCTAssertEqual(names, ["old.png.bucket"])
        let read = try await source.readData("a/old.png")
        XCTAssertEqual(read, png)
    }

    func testSettingsRoundTripAndOlderFilesDecode() throws {
        let decoded = try XCTUnwrap(BoardStorageConfig.decode(try config.encoded()))
        XCTAssertEqual(decoded, config)
        let minimal = try XCTUnwrap(BoardStorageConfig.decode(#"{"endpoint":"https://s3.test","bucket":"assets"}"#))
        XCTAssertTrue(minimal.enabled)
        XCTAssertEqual(minimal.region, "auto")
        XCTAssertTrue(minimal.isUsable)
        XCTAssertFalse(BoardStorageConfig(endpoint: "", bucket: "assets").isUsable)
    }
}
