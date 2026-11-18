import Foundation
import GitKittieKit
import XCTest
@testable import GitFolder

final class ConfigStoreTests: XCTestCase {
    @MainActor
    func testCloudflareAuthorizationRequestsConfiguredPermissions() throws {
        let url = try CloudflareStorageConnectionService.authorizationURL(
            clientID: "client-id",
            redirectURI: "http://127.0.0.1:53682/oauth/cloudflare",
            state: "state",
            challenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let scope = try XCTUnwrap(components.queryItems?.first { $0.name == "scope" }?.value)

        XCTAssertEqual(Set(scope.split(separator: " ").map(String.init)), Set(CloudflareStorageConnectionService.requestedScopes))
        XCTAssertEqual(CloudflareStorageConnectionService.requestedScopes.count, 3)
    }

    func testDefaultConfigKeepsPurchaseMetadataOutOfAppState() {
        let config = GitFolderConfig.empty

        XCTAssertEqual(config.schemaVersion, 1)
        XCTAssertTrue(config.folders.isEmpty)
        XCTAssertEqual(config.app.defaultSyncIntervalMinutes, 15)
    }

    func testSyncedFolderCreateKeepsConfiguredInterval() {
        let folder = SyncedFolder.create(
            name: "Documents",
            localPath: "/tmp/Documents",
            bookmarkData: nil,
            repoUrl: "git@github.com:silvandiepen/documents.git",
            branch: "main",
            syncIntervalMinutes: 30
        )

        XCTAssertEqual(folder.syncIntervalMinutes, 30)
        XCTAssertEqual(folder.branch, "main")
        XCTAssertEqual(folder.authModeValue, .githubToken)
        XCTAssertEqual(folder.lastStatus, .idle)
        XCTAssertTrue(folder.enabled)
    }

    func testConfigEncodingDoesNotIncludeGitHubTokenValue() throws {
        let secret = "github_pat_secret_value"
        let folder = SyncedFolder.create(
            name: "Documents",
            localPath: "/tmp/Documents",
            bookmarkData: nil,
            repoUrl: "https://github.com/silvandiepen/documents.git"
        )
        let config = GitFolderConfig(schemaVersion: 1, app: .defaults, folders: [folder])

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        let json = String(data: data, encoding: .utf8) ?? ""

        XCTAssertTrue(json.contains(AuthMode.githubToken.rawValue))
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("github_pat_"))
    }

    func testSyncedFolderCreatesRepositoryWebURLFromSSHURL() {
        let folder = SyncedFolder.create(
            name: "Documents",
            localPath: "/tmp/Documents",
            bookmarkData: nil,
            repoUrl: "git@github.com:silvandiepen/documents.git"
        )

        XCTAssertEqual(folder.repositoryWebURLString, "https://github.com/silvandiepen/documents")
    }

    func testRepositoryWebURLSupportsCommonCloneURLForms() {
        XCTAssertEqual(
            SyncedFolder.webURLString(fromRepositoryURL: "ssh://git@github.com/silvandiepen/documents.git"),
            "https://github.com/silvandiepen/documents"
        )
        XCTAssertEqual(
            SyncedFolder.webURLString(fromRepositoryURL: "https://github.com/silvandiepen/documents.git"),
            "https://github.com/silvandiepen/documents"
        )
        XCTAssertEqual(
            SyncedFolder.webURLString(fromRepositoryURL: " git@gitlab.com:group/documents.git\n"),
            "https://gitlab.com/group/documents"
        )
    }

    func testSnapshotCommitMessageIsStableAndIdentifiable() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let message = SnapshotCommitMessage.make(date: date)

        XCTAssertTrue(message.hasPrefix("GitFolder snapshot "))
        XCTAssertTrue(message.contains("T"))
        XCTAssertTrue(message.contains("Z"))
    }

    func testSyncCreatesCommitAndPushesToLocalRemote() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let remote = root.appending(path: "remote.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)

        _ = try runGit(["init", "--bare"], in: remote)
        _ = try runGit(["init"], in: source)
        try "hello".write(to: source.appending(path: "note.txt"), atomically: true, encoding: .utf8)

        let folder = SyncedFolder.create(
            name: "source",
            localPath: source.path,
            bookmarkData: nil,
            repoUrl: remote.path,
            authMode: .ssh,
            branch: "main",
            syncIntervalMinutes: 15
        )

        let engine = GitSyncEngine(now: { Date(timeIntervalSince1970: 1_700_000_000) })
        let options = GitSyncOptions(
            gitAuthorName: "GitFolder Test",
            gitAuthorEmail: "gitfolder@example.com",
            githubToken: nil,
            sshPrivateKeyPath: nil,
            sshPrivateKeyBookmarkData: nil
        )
        let outcome = try await engine.sync(folder, options: options)

        XCTAssertTrue(outcome.changed)
        XCTAssertTrue(outcome.pushed)
        XCTAssertEqual(outcome.folder.lastStatus, .synced)
        XCTAssertNotNil(outcome.folder.lastSuccessfulSyncAt)

        let remoteHead = try runGit(["--git-dir", remote.path, "rev-parse", "main"], in: root)
        XCTAssertFalse(remoteHead.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testSyncPullsRemoteChangesWhenWorkingTreeIsClean() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let writer = root.appending(path: "writer", directoryHint: .isDirectory)
        let remote = root.appending(path: "remote.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try runGit(["init", "--bare"], in: remote)
        _ = try runGit(["init"], in: source)
        try "local".write(to: source.appending(path: "local.txt"), atomically: true, encoding: .utf8)

        let folder = SyncedFolder.create(
            name: "source",
            localPath: source.path,
            bookmarkData: nil,
            repoUrl: remote.path,
            authMode: .ssh,
            branch: "main"
        )
        let options = GitSyncOptions(
            gitAuthorName: "GitFolder Test",
            gitAuthorEmail: "gitfolder@example.com",
            githubToken: nil,
            sshPrivateKeyPath: nil,
            sshPrivateKeyBookmarkData: nil
        )
        let engine = GitSyncEngine()
        _ = try await engine.sync(folder, options: options)

        _ = try runGit(["clone", "--branch", "main", remote.path, writer.path], in: root)
        _ = try runGit(["config", "user.name", "Remote Writer"], in: writer)
        _ = try runGit(["config", "user.email", "writer@example.com"], in: writer)
        try "remote".write(to: writer.appending(path: "remote.txt"), atomically: true, encoding: .utf8)
        _ = try runGit(["add", "remote.txt"], in: writer)
        _ = try runGit(["commit", "-m", "Add remote file"], in: writer)
        _ = try runGit(["push", "origin", "main"], in: writer)

        let outcome = try await engine.sync(folder, options: options)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appending(path: "remote.txt").path))
        XCTAssertTrue(outcome.changed)
        XCTAssertEqual(outcome.message, "Pulled remote changes")
    }

    func testRepairReattachesDetachedHeadToConfiguredBranch() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        _ = try runGit(["init"], in: source)
        _ = try runGit(["config", "user.name", "GitFolder Test"], in: source)
        _ = try runGit(["config", "user.email", "gitfolder@example.com"], in: source)
        try "hello".write(to: source.appending(path: "note.txt"), atomically: true, encoding: .utf8)
        _ = try runGit(["add", "note.txt"], in: source)
        _ = try runGit(["commit", "-m", "Initial"], in: source)
        _ = try runGit(["branch", "-M", "main"], in: source)
        _ = try runGit(["checkout", "--detach"], in: source)

        let folder = SyncedFolder.create(
            name: "source",
            localPath: source.path,
            bookmarkData: nil,
            repoUrl: "unused",
            authMode: .ssh,
            branch: "main"
        )

        _ = try await GitSyncEngine().repair(folder)

        let branch = try runGit(["branch", "--show-current"], in: source)
        XCTAssertEqual(branch.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "main")
    }

    func testLargeFilesAreBlockedAndCanBeAddedToGitIgnore() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let remote = root.appending(path: "remote.git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try runGit(["init", "--bare"], in: remote)
        _ = try runGit(["init"], in: source)

        let largeFile = source.appending(path: "large.bin")
        FileManager.default.createFile(atPath: largeFile.path, contents: nil)
        let handle = try FileHandle(forWritingTo: largeFile)
        try handle.truncate(atOffset: 100_000_000)
        try handle.close()

        let folder = SyncedFolder.create(
            name: "source",
            localPath: source.path,
            bookmarkData: nil,
            repoUrl: remote.path,
            authMode: .ssh,
            branch: "main"
        )
        let options = GitSyncOptions(
            gitAuthorName: "GitFolder Test",
            gitAuthorEmail: "gitfolder@example.com",
            githubToken: nil,
            sshPrivateKeyPath: nil,
            sshPrivateKeyBookmarkData: nil
        )
        let engine = GitSyncEngine()

        do {
            _ = try await engine.sync(folder, options: options)
            XCTFail("Expected oversized file to block sync")
        } catch let error as GitSyncError {
            guard case .largeFilesBlocked(let files) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(files.map(\.path), ["large.bin"])
        }

        _ = try await engine.ignore(["large.bin"], for: folder)

        let ignore = try String(contentsOf: source.appending(path: ".gitignore"), encoding: .utf8)
        XCTAssertTrue(ignore.contains("/large.bin"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: largeFile.path))
    }

    func testSyncRejectsFolderWithoutRepositoryURL() async throws {
        let folder = SyncedFolder.create(
            name: "source",
            localPath: "/tmp/source",
            bookmarkData: nil,
            repoUrl: "",
            authMode: .ssh,
            branch: "main"
        )
        let engine = GitSyncEngine()

        do {
            _ = try await engine.sync(folder)
            XCTFail("Expected missing repository URL error")
        } catch let error as GitSyncError {
            XCTAssertEqual(error, .missingRepositoryURL)
        }
    }

    func testSyncRejectsTokenFolderWithoutToken() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = SyncedFolder.create(
            name: "source",
            localPath: root.path,
            bookmarkData: nil,
            repoUrl: "https://github.com/silvandiepen/documents.git",
            authMode: .githubToken,
            branch: "main"
        )
        let engine = GitSyncEngine()

        do {
            _ = try await engine.sync(folder)
            XCTFail("Expected missing GitHub token error")
        } catch let error as GitSyncError {
            XCTAssertEqual(error, .missingGitHubToken)
        }
    }

    func testTokenAuthCommandConstructionDoesNotPutTokenInArguments() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = FakeGitRunner()
        let engine = GitSyncEngine(gitRunner: runner)
        let token = "github_pat_secret_value"

        try await engine.testGitHubAccess(
            repoUrl: "https://github.com/example/repo.git",
            authMode: .githubToken,
            options: GitSyncOptions(
                gitAuthorName: nil,
                gitAuthorEmail: nil,
                githubToken: token,
                sshPrivateKeyPath: nil,
                sshPrivateKeyBookmarkData: nil
            )
        )

        let calls = runner.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls[0].arguments.joined(separator: " ").contains(token))
        XCTAssertEqual(calls[0].environment["GITPONT_TOKEN"], token)
        XCTAssertEqual(calls[0].environment["GITPONT_USERNAME"], "x-access-token")
        XCTAssertEqual(calls[0].environment["GIT_TERMINAL_PROMPT"], "0")
    }

    func testGitRunnerLaunchFailureIncludesExecutablePath() throws {
        let missingGitPath = "/tmp/gitfolder-missing-git-\(UUID().uuidString)"
        let runner = GitRunner(gitExecutableURL: URL(fileURLWithPath: missingGitPath))

        do {
            _ = try runner.run(["--version"], in: FileManager.default.temporaryDirectory, timeoutSeconds: 1)
            XCTFail("Expected Git launch failure")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Could not launch Git"), message)
            XCTAssertTrue(message.contains(missingGitPath), message)
        }
    }

    func testKeychainServiceStoresReplacesAndDeletesToken() throws {
        let service = KeychainService(service: "app.hakobs.gitfolder.tests.\(UUID().uuidString)")
        defer { try? service.delete() }

        try service.save("first-token")
        XCTAssertEqual(try service.load(), "first-token")

        try service.save("second-token")
        XCTAssertEqual(try service.load(), "second-token")

        try service.delete()
        XCTAssertNil(try service.load())
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "GitFolderTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func runGit(_ arguments: [String], in workingDirectory: URL) throws -> GitFolder.GitCommandResult {
        let result = try GitRunner().run(arguments, in: workingDirectory, timeoutSeconds: 60)
        XCTAssertEqual(result.exitCode, 0, result.standardError)
        return result
    }
}

final class S3StorageServiceTests: XCTestCase {
    override func tearDown() {
        S3TestURLProtocol.handler = nil
        super.tearDown()
    }

    func testConnectionUsesPathStyleBucketAndAWSV4Signature() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [S3TestURLProtocol.self]
        let service = S3StorageService(
            session: URLSession(configuration: configuration),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        var settings = BucketStorageSettings.defaults
        settings.enabled = true
        settings.endpoint = "https://example.r2.cloudflarestorage.com"
        settings.bucket = "project assets"
        settings.region = "auto"

        S3TestURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            XCTAssertEqual(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }, "/project%20assets")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-date"), "20231114T221320Z")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=access/20231114/auto/s3/aws4_request") == true)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        try await service.testConnection(
            settings: settings,
            credentials: S3Credentials(accessKeyID: "access", secretAccessKey: "secret")
        )
    }

    func testStreamingSHA256MatchesKnownDigest() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "hello.txt")
        try Data("hello".utf8).write(to: file)

        XCTAssertEqual(
            try S3StorageService.sha256(of: file),
            "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
    }

    func testStorageSettingsDecodeOlderConfigWithoutRegionOrProvider() throws {
        let data = Data(#"{"enabled":true,"endpoint":"https://example.com","bucket":"assets","publicBaseURL":"https://cdn.example.com","minimumFileSizeMB":25,"offloadExtensions":["mov"],"keepDownloadedPatterns":["**/*.md"]}"#.utf8)
        let settings = try JSONDecoder().decode(BucketStorageSettings.self, from: data)
        XCTAssertEqual(settings.region, "auto")
        XCTAssertEqual(settings.provider, .manual)
    }
}

private final class S3TestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw S3StorageError.invalidResponse }
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

private final class FakeGitRunner: GitRunning, @unchecked Sendable {
    struct Call: Equatable {
        var arguments: [String]
        var environment: [String: String]
    }

    private(set) var calls: [Call] = []

    func run(
        _ arguments: [String],
        in workingDirectory: URL,
        timeoutSeconds: TimeInterval,
        environment: [String: String]
    ) throws -> GitFolder.GitCommandResult {
        calls.append(Call(arguments: arguments, environment: environment))
        return GitFolder.GitCommandResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}
