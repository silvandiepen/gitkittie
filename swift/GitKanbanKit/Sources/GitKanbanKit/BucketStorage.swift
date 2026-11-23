import Foundation
import GitKittieKit

/// What a repository says about where its big files go: an S3-compatible bucket (Cloudflare
/// R2, AWS S3). It is a file in the repository, so every device and every agent reads the
/// same answer. The keys are not in it; they stay in each device's Keychain.
public struct BoardStorageConfig: Codable, Equatable, Sendable {
    public var enabled: Bool
    /// The S3 API address, e.g. `https://<account>.r2.cloudflarestorage.com`.
    public var endpoint: String
    public var bucket: String
    public var region: String
    /// The address the bucket's files can be read from without keys. Empty when there is
    /// none: reading then needs the keys too.
    public var publicBaseURL: String

    /// Where the settings live in the repository.
    public static let path = ".tasks/storage.json"

    public init(enabled: Bool = true, endpoint: String = "", bucket: String = "", region: String = "auto", publicBaseURL: String = "") {
        self.enabled = enabled
        self.endpoint = endpoint
        self.bucket = bucket
        self.region = region
        self.publicBaseURL = publicBaseURL
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        endpoint = try values.decode(String.self, forKey: .endpoint)
        bucket = try values.decode(String.self, forKey: .bucket)
        region = try values.decodeIfPresent(String.self, forKey: .region) ?? "auto"
        publicBaseURL = try values.decodeIfPresent(String.self, forKey: .publicBaseURL) ?? ""
    }

    var s3: S3Bucket { S3Bucket(endpoint: endpoint, bucket: bucket, region: region) }

    /// Complete enough to send a file to.
    public var isUsable: Bool {
        enabled && URL(string: endpoint)?.host != nil && !bucket.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The public address of an object, nil without a public address for the bucket.
    func publicURL(forKey key: String) -> URL? {
        let base = publicBaseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty, let url = URL(string: base.hasSuffix("/") ? String(base.dropLast()) : base) else { return nil }
        return key.split(separator: "/").reduce(url) { $0.appendingPathComponent(String($1)) }
    }

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }

    static func decode(_ text: String) -> BoardStorageConfig? {
        try? JSONDecoder().decode(BoardStorageConfig.self, from: Data(text.utf8))
    }
}

/// What stays in the repository in place of a file that went to the bucket: a small text
/// file named `<file>.bucket` next to where the file would have been.
public struct BucketPointer: Codable, Equatable, Sendable {
    public var version = 1
    /// The object's name in the bucket.
    public var key: String
    public var sha256: String
    public var size: Int
    public var contentType: String?
    /// Where the file can be read without keys, when the bucket has a public address.
    public var url: String?

    public static let suffix = ".bucket"

    public func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }

    static func decode(_ text: String) -> BucketPointer? {
        try? JSONDecoder().decode(BucketPointer.self, from: Data(text.utf8))
    }
}

/// The bucket's keys on this device, in the Keychain, one entry per bucket.
public struct BucketCredentialStore: Sendable {
    let service: String
    let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private struct Stored: Codable { let accessKeyID: String; let secretAccessKey: String }

    private func keychain(_ config: BoardStorageConfig) -> KeychainService {
        let host = URL(string: config.endpoint)?.host ?? config.endpoint
        return KeychainService(service: service, account: "bucket|\(host)|\(config.bucket)", accessGroup: accessGroup)
    }

    public func load(for config: BoardStorageConfig) -> S3Credentials? {
        guard let raw = try? keychain(config).load(),
              let stored = try? JSONDecoder().decode(Stored.self, from: Data(raw.utf8)) else { return nil }
        return S3Credentials(accessKeyID: stored.accessKeyID, secretAccessKey: stored.secretAccessKey)
    }

    public func save(_ credentials: S3Credentials, for config: BoardStorageConfig) throws {
        let data = try JSONEncoder().encode(Stored(accessKeyID: credentials.accessKeyID, secretAccessKey: credentials.secretAccessKey))
        try keychain(config).save(String(decoding: data, as: UTF8.self))
    }

    public func delete(for config: BoardStorageConfig) throws {
        try keychain(config).delete()
    }
}

/// The storage settings of each repository as last read, so a board does not ask the
/// repository again on every file.
actor BucketConfigCache {
    static let shared = BucketConfigCache()

    private var known: [String: (config: BoardStorageConfig?, at: Date)] = [:]

    /// The cached answer, nil when there is none or it is too old. A repository without
    /// settings is remembered for a shorter time, so switching storage on elsewhere shows
    /// up soon.
    func cached(_ repoKey: String, now: Date = Date()) -> BoardStorageConfig?? {
        guard let entry = known[repoKey] else { return nil }
        let life: TimeInterval = entry.config == nil ? 60 : 300
        return now.timeIntervalSince(entry.at) < life ? .some(entry.config) : nil
    }

    func store(_ config: BoardStorageConfig?, for repoKey: String, now: Date = Date()) {
        known[repoKey] = (config, now)
    }

    func forget(_ repoKey: String) { known[repoKey] = nil }
}

/// A source that sends images, audio, video and other binary files to the repository's
/// bucket and keeps only a pointer in the repository. Text (cards, review requests, docs,
/// settings) is written to the repository as before.
///
/// It sits directly on the provider, under the outbox, so a file made offline is uploaded
/// when it is sent, and an agent's write through the app is offloaded the same way.
///
/// - A repository without storage settings, or a device without the bucket's keys, writes
///   files to the repository as before. Nothing is lost; it just is not offloaded.
/// - Reading tries the repository first, so files from before the bucket still open.
struct BucketSource: BatchWritable, BulkTextSource, WebLinkingSource, TreeListingSource {
    let base: any BoardWritable
    let repoKey: String
    /// The keys this device holds for a bucket, nil when it has none.
    let keys: @Sendable (BoardStorageConfig) -> S3Credentials?
    var service = S3StorageService()
    var session: URLSession = .shared
    var cache: BucketConfigCache = .shared

    // MARK: What is offloaded

    /// Extensions that are text and belong in the repository: cards, requests, settings.
    private static let textExtensions: Set<String> = ["md", "markdown", "txt", "json", "yml", "yaml", "csv", "tsv", "toml", "xml", "html", "css", "js", "ts", "swift", "gitignore", "gitkeep"]

    /// Whether a file at this path goes to the bucket: anything with an extension that is
    /// not text. A name without an extension stays in the repository.
    static func offloads(_ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = name[name.index(after: dot)...].lowercased()
        return !ext.isEmpty && ext != "bucket" && !textExtensions.contains(ext)
    }

    static func objectKey(sha256: String, path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        return "tasks/v1/objects/\(sha256.prefix(2))/\(sha256)" + (ext.isEmpty ? "" : ".\(ext)")
    }

    static func contentType(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "svg": return "image/svg+xml"
        case "pdf": return "application/pdf"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "m4a", "aac": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg": return "audio/ogg"
        case "glb": return "model/gltf-binary"
        case "usdz": return "model/vnd.usdz+zip"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }

    // MARK: Settings

    /// The repository's storage settings, read once and remembered for a few minutes.
    func config() async -> BoardStorageConfig? {
        if let cached = await cache.cached(repoKey) { return cached }
        do {
            let config = BoardStorageConfig.decode(try await base.readText(BoardStorageConfig.path))
            await cache.store(config, for: repoKey)
            return config
        } catch {
            // No connection says nothing about the settings: do not remember that.
            if !Outbox.isConnectivity(error) { await cache.store(nil, for: repoKey) }
            return nil
        }
    }

    // MARK: Reading

    func list(_ directory: String) async throws -> [BoardFileEntry] {
        Self.resolved(try await base.list(directory))
    }

    func listFiles(under directory: String) async -> [BoardFileEntry]? {
        guard let tree = base as? any TreeListingSource, let files = await tree.listFiles(under: directory) else { return nil }
        return Self.resolved(files)
    }

    /// A listing with each pointer shown as the file it stands for.
    static func resolved(_ entries: [BoardFileEntry]) -> [BoardFileEntry] {
        var result: [BoardFileEntry] = []
        var seen = Set<String>()
        // Files that are really there first, so a file and its pointer show once.
        for entry in entries where !(entry.kind == .file && entry.name.hasSuffix(BucketPointer.suffix)) {
            result.append(entry)
            seen.insert(entry.path)
        }
        for entry in entries where entry.kind == .file && entry.name.hasSuffix(BucketPointer.suffix) {
            let name = String(entry.name.dropLast(BucketPointer.suffix.count))
            let path = String(entry.path.dropLast(BucketPointer.suffix.count))
            guard !name.isEmpty, seen.insert(path).inserted else { continue }
            result.append(BoardFileEntry(name: name, path: path, kind: .file))
        }
        return result
    }

    func readText(_ path: String) async throws -> String { try await base.readText(path) }

    func readTexts(in directory: String) async -> [String: String]? {
        guard let bulk = base as? any BulkTextSource else { return nil }
        return await bulk.readTexts(in: directory)
    }

    func readData(_ path: String) async throws -> Data {
        do {
            return try await base.readData(path)
        } catch {
            guard Self.offloads(path),
                  let text = try? await base.readText(path + BucketPointer.suffix),
                  let pointer = BucketPointer.decode(text) else { throw error }
            return try await fetch(pointer, path: path)
        }
    }

    /// The file a pointer stands for: from its public address, else with the keys.
    private func fetch(_ pointer: BucketPointer, path: String) async throws -> Data {
        let config = await config()
        if let url = pointer.url.flatMap(URL.init(string:)) ?? config?.publicURL(forKey: pointer.key) {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw BoardSourceError(message: "Couldn't load \(path) from the bucket (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
            }
            let actual = S3StorageService.sha256(data)
            guard actual == pointer.sha256 else { throw S3StorageError.checksumMismatch(expected: pointer.sha256, actual: actual) }
            return data
        }
        guard let config, let keys = self.keys(config) else {
            throw BoardSourceError(message: "\(path) is in the bucket, and this device has no keys for it. Add them in File Storage.")
        }
        return try await service.download(objectKey: pointer.key, expectedSHA256: pointer.sha256, bucket: config.s3, credentials: keys)
    }

    func webURL(forPath path: String) -> URL? { (base as? any WebLinkingSource)?.webURL(forPath: path) }

    // MARK: Writing

    func write(path: String, text: String, message: String) async throws {
        try await base.write(path: path, text: text, message: message)
    }

    func writeTexts(_ texts: [String: String], message: String) async throws -> Bool {
        guard let batch = base as? any BatchWritable else { return false }
        return try await batch.writeTexts(texts, message: message)
    }

    func writeData(path: String, data: Data, message: String) async throws {
        guard Self.offloads(path), let config = await config(), config.isUsable,
              let keys = self.keys(config) else {
            return try await base.writeData(path: path, data: data, message: message)
        }
        let sha256 = S3StorageService.sha256(data)
        let key = Self.objectKey(sha256: sha256, path: path)
        // The name is the content: the same file again is already there.
        if !(await service.hasObject(objectKey: key, sha256: sha256, bucket: config.s3, credentials: keys)) {
            try await service.upload(data, objectKey: key, contentType: Self.contentType(path), bucket: config.s3, credentials: keys)
            try await service.verifyObject(objectKey: key, sha256: sha256, bucket: config.s3, credentials: keys)
        }
        let pointer = BucketPointer(key: key, sha256: sha256, size: data.count, contentType: Self.contentType(path),
                                    url: config.publicURL(forKey: key)?.absoluteString)
        try await base.write(path: path + BucketPointer.suffix, text: try pointer.encoded(), message: message)
        // A copy of the file itself in the repository would be read before the pointer:
        // when this write replaces one, take it out. Most writes are new files, and then
        // there is nothing to delete.
        try? await base.delete(path: path, message: "\(message) (moved to the bucket)")
    }

    func delete(path: String, message: String) async throws {
        guard Self.offloads(path) else { return try await base.delete(path: path, message: message) }
        do {
            try await base.delete(path: path, message: message)
            // A pointer left behind would bring the file back.
            try? await base.delete(path: path + BucketPointer.suffix, message: message)
        } catch {
            do { try await base.delete(path: path + BucketPointer.suffix, message: message) } catch _ { throw error }
        }
    }

    // MARK: Moving what is already in the repository

    /// The files in the repository that would be in the bucket had they been written
    /// today, nil when this source cannot list a whole repository in one go.
    func filesStillInRepository() async -> [String]? {
        guard let tree = base as? any TreeListingSource, let files = await tree.listFiles(under: "") else { return nil }
        return files.filter { $0.kind == .file && Self.offloads($0.path) }.map(\.path).sorted()
    }

    /// Send one file that is in the repository to the bucket and leave a pointer.
    func offloadExisting(_ path: String) async throws {
        guard let config = await config(), config.isUsable, self.keys(config) != nil else {
            throw BoardSourceError(message: "File storage is not set up on this device.")
        }
        let data = try await base.readData(path)
        try await writeData(path: path, data: data, message: "chore(tasks): move \((path as NSString).lastPathComponent) to the bucket")
    }
}
