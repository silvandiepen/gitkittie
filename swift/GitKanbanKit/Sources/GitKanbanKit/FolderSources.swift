import Foundation
import GitKittieKit
#if canImport(CoreServices)
import CoreServices
#endif

// Folder sources — GitKanban over a plain folder, with **no git at all**. The folder is
// synced (or not) by whatever owns it, e.g. GitFolder auto-committing `~/Projects`; GitKanban
// only reads and writes the files. Two transports share the same semantics:
//
// - `LocalFolderSource`: a folder on this device (macOS folder picker, security-scoped).
// - `ServerFolderSource`: a folder on another machine, served by `apps/gitkanban-server`
//   (reached over Tailscale). See that app's README for the HTTP API.

/// Thrown when a versioned write finds the file changed since it was read.
public struct SourceConflictError: Error, LocalizedError, Equatable {
    public let path: String
    public var errorDescription: String? { "\(path) changed while saving. Try again." }
}

/// A source that can do compare-and-swap writes, so a reviewer's write never silently
/// drops an agent's edit made in between.
protocol VersionedBoardSource: BoardWritable {
    func readVersioned(_ path: String) async throws -> (text: String, version: String?)
    /// Write only if the file is still at `version` (`nil` = must not exist).
    func write(path: String, text: String, ifVersion version: String?) async throws
}

/// A source whose files can be addressed by URL (for AVPlayer/Quick Look streaming).
protocol AssetLinkingSource: Sendable {
    func assetURL(_ path: String) -> URL?
}

/// A source that can report which files changed, for live refresh.
protocol ChangeObservingSource: Sendable {
    func changes() -> AsyncStream<[String]>
}

enum FolderPath {
    /// Validate a source-relative path: no absolute, `..`, NUL, backslash or dot segments.
    static func validate(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.isEmpty { return "" }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else {
            throw NSError(domain: "FolderSource", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid path: \(path)"])
        }
        return trimmed
    }

    static func join(_ base: String, _ name: String) -> String { base.isEmpty ? name : "\(base)/\(name)" }
}

// MARK: - Local folder

/// Keeps a security-scoped folder accessible for as long as a source uses it.
final class SecurityScopedAccess: Sendable {
    let url: URL
    private let started: Bool

    init(url: URL) {
        self.url = url
        self.started = url.startAccessingSecurityScopedResource()
    }

    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}

struct LocalFolderSource: VersionedBoardSource, AssetLinkingSource, ChangeObservingSource, WebLinkingSource {
    let root: URL

    func webURL(forPath path: String) -> URL? { root.appendingPathComponent(path) }
    private let access: SecurityScopedAccess?

    init(root: URL, securityScoped: Bool) {
        self.root = root.standardizedFileURL
        self.access = securityScoped ? SecurityScopedAccess(url: root) : nil
    }

    private func url(_ path: String) throws -> URL {
        let clean = try FolderPath.validate(path)
        return clean.isEmpty ? root : root.appendingPathComponent(clean, isDirectory: false)
    }

    func list(_ directory: String) async throws -> [BoardFileEntry] {
        let dir = try url(directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let base = try FolderPath.validate(directory)
        return names.compactMap { name -> BoardFileEntry? in
            guard !name.hasPrefix("."), name != "node_modules" else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir) else { return nil }
            return BoardFileEntry(name: name, path: FolderPath.join(base, name), kind: isDir.boolValue ? .directory : .file)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func readText(_ path: String) async throws -> String {
        try String(contentsOf: url(path), encoding: .utf8)
    }

    func readData(_ path: String) async throws -> Data {
        try Data(contentsOf: url(path))
    }

    func readVersioned(_ path: String) async throws -> (text: String, version: String?) {
        let target = try url(path)
        let version = Self.version(of: target)
        return (try String(contentsOf: target, encoding: .utf8), version)
    }

    func write(path: String, text: String, message: String) async throws {
        try writeData(at: url(path), Data(text.utf8))
    }

    func writeData(path: String, data: Data, message: String) async throws {
        try writeData(at: url(path), data)
    }

    func write(path: String, text: String, ifVersion version: String?) async throws {
        let target = try url(path)
        guard Self.version(of: target) == version else { throw SourceConflictError(path: path) }
        try writeData(at: target, Data(text.utf8))
    }

    func delete(path: String, message: String) async throws {
        let target = try url(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue else { return }
        try FileManager.default.removeItem(at: target)
    }

    func assetURL(_ path: String) -> URL? { try? url(path) }

    private func writeData(at target: URL, _ data: Data) throws {
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
    }

    /// Size + modification time, which changes on every write (atomic writes replace the inode).
    static func version(of url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)-\(mtime)"
    }

    func changes() -> AsyncStream<[String]> {
        #if os(macOS)
        return FSEventsWatcher.stream(root: root)
        #else
        // iOS has no FSEvents; a local folder there refreshes on demand.
        return AsyncStream { $0.finish() }
        #endif
    }
}

#if os(macOS)
/// Recursive file-change stream for a folder via FSEvents, as source-relative paths.
enum FSEventsWatcher {
    private final class Box {
        let continuation: AsyncStream<[String]>.Continuation
        let rootPath: String
        init(_ c: AsyncStream<[String]>.Continuation, rootPath: String) { continuation = c; self.rootPath = rootPath }
    }

    /// Only touched on the watcher's serial queue, which orders create before stop.
    private final class StreamHandle {
        var stream: FSEventStreamRef?
        var box: Unmanaged<Box>?
    }

    static func stream(root: URL) -> AsyncStream<[String]> {
        AsyncStream { continuation in
            let rootPath = root.resolvingSymlinksInPath().path
            let queue = DispatchQueue(label: "gitkanban.fsevents")
            let handle = StreamHandle()
            queue.async {
                let box = Unmanaged.passRetained(Box(continuation, rootPath: rootPath))
                var context = FSEventStreamContext(version: 0, info: box.toOpaque(), retain: nil, release: nil, copyDescription: nil)
                let callback: FSEventStreamCallback = { _, info, count, pathsPointer, _, _ in
                    guard let info else { return }
                    let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
                    let cfArray = Unmanaged<CFArray>.fromOpaque(pathsPointer).takeUnretainedValue()
                    guard let all = cfArray as? [String] else { return }
                    let prefix = box.rootPath.hasSuffix("/") ? box.rootPath : box.rootPath + "/"
                    let paths = all.prefix(count).compactMap { full -> String? in
                        guard full.hasPrefix(prefix) else { return nil }
                        let rel = String(full.dropFirst(prefix.count))
                        if rel.split(separator: "/").contains(where: { $0.hasPrefix(".") || $0 == "node_modules" }) { return nil }
                        return rel
                    }
                    if !paths.isEmpty { box.continuation.yield(paths) }
                }
                guard let stream = FSEventStreamCreate(
                    kCFAllocatorDefault, callback, &context, [rootPath] as CFArray,
                    FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
                    FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
                ) else {
                    box.release()
                    continuation.finish()
                    return
                }
                FSEventStreamSetDispatchQueue(stream, queue)
                FSEventStreamStart(stream)
                handle.stream = stream
                handle.box = box
            }
            continuation.onTermination = { _ in
                queue.async {
                    if let stream = handle.stream {
                        FSEventStreamStop(stream)
                        FSEventStreamInvalidate(stream)
                        FSEventStreamRelease(stream)
                    }
                    handle.box?.release()
                    handle.stream = nil
                    handle.box = nil
                }
            }
        }
    }
}
#endif

// MARK: - Folder server

/// The GitKanban folder server (`apps/gitkanban-server`), usually on the user's Mac and
/// reached over Tailscale. It does no git; this client only reads and writes files.
struct ServerFolderSource: VersionedBoardSource, AssetLinkingSource, ChangeObservingSource {
    let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    struct Whoami: Decodable, Sendable { let login: String?; let name: String? }
    private struct ListEntry: Decodable { let name: String; let path: String; let kind: String }
    private struct Health: Decodable { let ok: Bool; let root: String? }

    /// Query-safe path encoding: Hono decodes `+` as a space, so encode everything but unreserved + `/`.
    private static let allowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~/")
        return set
    }()

    func endpoint(_ route: String, path: String? = nil) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/\(route)"), resolvingAgainstBaseURL: false)!
        if let path {
            let encoded = path.addingPercentEncoding(withAllowedCharacters: Self.allowed) ?? path
            components.percentEncodedQuery = "path=\(encoded)"
        }
        return components.url!
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    private func check(_ data: Data, _ http: HTTPURLResponse, path: String) throws {
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 412 { throw SourceConflictError(path: path) }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["message"] as? String) ?? ($0["error"] as? String) } ?? "HTTP \(http.statusCode)"
            throw NSError(domain: "ServerFolderSource", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "\(path): \(message)"])
        }
    }

    /// Verify the URL points at a GitKanban folder server; returns the served folder's name.
    func health() async throws -> String {
        let (data, http) = try await send(URLRequest(url: endpoint("health")))
        try check(data, http, path: "health")
        let health = try JSONDecoder().decode(Health.self, from: data)
        guard health.ok else { throw URLError(.badServerResponse) }
        return health.root ?? baseURL.host ?? "Folder"
    }

    func whoami() async -> Whoami? {
        guard let (data, http) = try? await send(URLRequest(url: endpoint("whoami"))),
              http.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Whoami.self, from: data)
    }

    func list(_ directory: String) async throws -> [BoardFileEntry] {
        let (data, http) = try await send(URLRequest(url: endpoint("list", path: directory)))
        try check(data, http, path: directory)
        return try JSONDecoder().decode([ListEntry].self, from: data).map {
            BoardFileEntry(name: $0.name, path: $0.path, kind: $0.kind == "directory" ? .directory : .file)
        }
    }

    func readData(_ path: String) async throws -> Data {
        var request = URLRequest(url: endpoint("file", path: path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, http) = try await send(request)
        try check(data, http, path: path)
        return data
    }

    func readText(_ path: String) async throws -> String {
        String(decoding: try await readData(path), as: UTF8.self)
    }

    func readVersioned(_ path: String) async throws -> (text: String, version: String?) {
        var request = URLRequest(url: endpoint("file", path: path))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, http) = try await send(request)
        try check(data, http, path: path)
        return (String(decoding: data, as: UTF8.self), http.value(forHTTPHeaderField: "ETag"))
    }

    private func put(_ path: String, _ body: Data, headers: [String: String]) async throws {
        var request = URLRequest(url: endpoint("file", path: path))
        request.httpMethod = "PUT"
        request.httpBody = body
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, http) = try await send(request)
        try check(data, http, path: path)
    }

    func write(path: String, text: String, message: String) async throws {
        try await put(path, Data(text.utf8), headers: [:])
    }

    func writeData(path: String, data: Data, message: String) async throws {
        try await put(path, data, headers: [:])
    }

    func write(path: String, text: String, ifVersion version: String?) async throws {
        try await put(path, Data(text.utf8), headers: version.map { ["If-Match": $0] } ?? ["If-None-Match": "*"])
    }

    func delete(path: String, message: String) async throws {
        var request = URLRequest(url: endpoint("file", path: path))
        request.httpMethod = "DELETE"
        let (data, http) = try await send(request)
        if http.statusCode == 404 { return }
        try check(data, http, path: path)
    }

    func assetURL(_ path: String) -> URL? { endpoint("file", path: path) }

    /// Server-sent `change` events, reconnecting with backoff until the consumer stops.
    func changes() -> AsyncStream<[String]> {
        let url = endpoint("events")
        let session = self.session
        return AsyncStream { continuation in
            let task = Task {
                var delay: UInt64 = 1_000_000_000
                while !Task.isCancelled {
                    do {
                        var request = URLRequest(url: url)
                        request.timeoutInterval = 60 * 60
                        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                        let (bytes, response) = try await session.bytes(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                        delay = 1_000_000_000
                        var event = ""
                        for try await line in bytes.lines {
                            if line.hasPrefix("event:") {
                                event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                            } else if line.hasPrefix("data:"), event == "change" {
                                let json = Data(line.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8)
                                if let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                                   let paths = object["paths"] as? [String], !paths.isEmpty {
                                    continuation.yield(paths)
                                }
                                event = ""
                            }
                        }
                    } catch {
                        if Task.isCancelled { break }
                    }
                    try? await Task.sleep(nanoseconds: delay)
                    delay = min(delay * 2, 30_000_000_000)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
