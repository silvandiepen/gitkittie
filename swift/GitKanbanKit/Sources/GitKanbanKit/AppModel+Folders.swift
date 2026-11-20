import Foundation
import GitKittieKit

// GitKanban over plain folders (no git) and asset review driven by the folder structure.
// A board's effective `review_path` names where its review requests live; when that
// folder exists, its requests are loaded and can be decided on. Without it the board
// behaves exactly as before.

extension AppModel {

    // MARK: Home

    /// True when there's something to show on the home screen: a provider connection, or
    /// at least one folder entry (which works without signing in anywhere).
    public var hasHome: Bool { isConnected || addedRepos.contains { $0.kind.isFolder } }

    // MARK: Adding folders

    /// Add a folder on this device. `url` comes from a folder picker and must be
    /// security-scope accessible while this call runs.
    @discardableResult
    public func addLocalFolder(_ url: URL) throws -> AddedRepo {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        #if os(macOS)
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
        let entry = AddedRepo(namespace: "folder", name: url.lastPathComponent, branch: "", isPrivate: true,
                              kind: .localFolder(path: url.path, bookmark: bookmark))
        return insertFolderEntry(entry)
    }

    /// Add a GitKanban folder server (e.g. `https://my-mac.tailnet.ts.net`). Verifies it
    /// answers `/api/health` before saving it.
    public func addFolderServer(_ rawURL: String, name: String? = nil) async -> AddedRepo? {
        errorMessage = nil
        var text = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http") { text = "https://\(text)" }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.host != nil else {
            errorMessage = "That doesn't look like a server address."
            return nil
        }
        do {
            let host = url.host ?? text
            let label = host.split(separator: ".").first.map(String.init) ?? host
            let root = try await ServerFolderSource(baseURL: url).health()
            let entry = AddedRepo(namespace: "server", name: name ?? "\(root) on \(label)", branch: "", isPrivate: true,
                                  kind: .folderServer(url: text))
            return insertFolderEntry(entry)
        } catch {
            errorMessage = "Couldn't reach a GitKanban folder server at \(text): \(error.localizedDescription)"
            return nil
        }
    }

    /// Add a server found by `FolderServerBrowser`, under the name it announces.
    public func addDiscoveredServer(_ server: DiscoveredServer) async -> AddedRepo? {
        if let existing = addedServer(for: server) { return existing }
        guard let url = server.url else {
            errorMessage = "\(server.name) has no address yet. On that Mac, run gitkanban-server's tools/tailscale-serve.sh."
            return nil
        }
        let added = await addFolderServer(url, name: server.name)
        if added == nil {
            errorMessage = "Found \(server.name), but \(url) doesn't answer. Check that Tailscale is on here and on the Mac, and that tools/tailscale-serve.sh ran there."
        }
        return added
    }

    /// The saved entry for a discovered server, if it was added before.
    public func addedServer(for server: DiscoveredServer) -> AddedRepo? {
        guard let url = server.url else { return nil }
        return addedRepos.first { repo in
            if case .folderServer(let saved) = repo.kind { return saved == url }
            return false
        }
    }

    private func insertFolderEntry(_ entry: AddedRepo) -> AddedRepo {
        if let existing = addedRepos.first(where: { $0.id == entry.id }) { return existing }
        addedRepos.append(entry)
        addedRepos.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        persistAddedRepos()
        return entry
    }

    /// The (cached) source for a folder entry. Cached so a local folder's security scope
    /// stays open while it's in use.
    func folderSource(for repo: AddedRepo) -> (any BoardWritable)? {
        if let cached = folderSourceCache[repo.id] { return cached }
        let made: (any BoardWritable)?
        switch repo.kind {
        case .provider:
            made = nil
        case .folderServer(let urlString):
            made = URL(string: urlString).map { ServerFolderSource(baseURL: $0) }
        case .localFolder(let path, let bookmark):
            var url = URL(fileURLWithPath: path, isDirectory: true)
            var scoped = false
            if let bookmark {
                var stale = false
                #if os(macOS)
                let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
                #else
                let options: URL.BookmarkResolutionOptions = []
                #endif
                if let resolved = try? URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) {
                    url = resolved
                    scoped = true
                }
            }
            made = LocalFolderSource(root: url, securityScoped: scoped)
        }
        if let made { folderSourceCache[repo.id] = made }
        return made
    }

    // MARK: Reviews

    /// Load the open board's review requests from its effective `review_path`.
    public func loadReviews() async {
        guard let source, let project = selectedProject, let board else {
            reviews = []
            reviewFolder = nil
            return
        }
        guard let folder = Review.resolveReviewPath(board.config.reviewPath, projectFolder: project.folder) else {
            reviews = []
            reviewFolder = nil
            return
        }
        reviewFolder = folder
        isLoadingReviews = true
        defer { isLoadingReviews = false }
        reviews = await RemoteBoardStore.loadReviews(source: source, folder: folder)
        if serverLogin == nil, let server = source as? ServerFolderSource {
            serverLogin = await server.whoami()?.login
        }
    }

    /// Review requests that belong to a card (by `card:` id).
    public func reviews(for card: Card) -> [ReviewRequest] {
        reviews.filter { $0.card == card.fields.id }
    }

    /// Items across the open board still waiting on the reviewer.
    public var pendingReviewCount: Int { reviews.reduce(0) { $0 + $1.summary.pending } }

    /// Who decisions and comments are recorded as: the board user matching the server's
    /// Tailscale login or this device's account (by `github` or `id`), else that login.
    public var reviewerID: String {
        let login = serverLogin ?? connection?.login ?? NSUserName()
        let handle = login.split(separator: "@").first.map(String.init) ?? login
        let users = board?.config.users ?? []
        if let user = users.first(where: {
            ($0.github?.lowercased() == handle.lowercased()) || $0.id.lowercased() == handle.lowercased()
        }) { return user.id }
        return handle.isEmpty ? "reviewer" : handle
    }

    public func decide(_ request: ReviewRequest, item: ReviewItem, status: ReviewStatus) async {
        let by = reviewerID
        await rewriteReview(request) { try Review.applyDecision($0, itemID: item.id, status: status, by: by) }
    }

    public func comment(_ request: ReviewRequest, item: ReviewItem, text: String) async {
        let by = reviewerID
        await rewriteReview(request) { try Review.appendComment($0, itemID: item.id, by: by, body: text) }
    }

    /// Read-modify-write a `review.md`, only touching reviewer fields. On sources that
    /// support it, the write is compare-and-swap; a concurrent agent edit is re-read and
    /// the change re-applied (up to 3 times) instead of overwritten.
    private func rewriteReview(_ request: ReviewRequest, _ change: (String) throws -> String) async {
        guard let source else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            if let versioned = source as? any VersionedBoardSource {
                var attempt = 0
                while true {
                    let (text, version) = try await versioned.readVersioned(request.path)
                    do {
                        try await versioned.write(path: request.path, text: try change(text), ifVersion: version)
                        break
                    } catch is SourceConflictError where attempt < 2 {
                        attempt += 1
                    }
                }
            } else {
                let text = try await source.readText(request.path)
                try await source.write(path: request.path, text: try change(text), message: "Review \(request.id)")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        await reloadReview(request)
    }

    private func reloadReview(_ request: ReviewRequest) async {
        guard let source, let text = try? await source.readText(request.path) else { return }
        let fresh = Review.parse(text, folder: request.folder)
        if let index = reviews.firstIndex(where: { $0.folder == request.folder }) { reviews[index] = fresh }
    }

    /// A URL that streams an asset (AVPlayer, image loading) when the source can address
    /// files directly; `nil` otherwise — use `localAssetURL` then.
    public func streamURL(_ request: ReviewRequest, file: String) -> URL? {
        guard let path = request.assetPath(file), let linking = source as? any AssetLinkingSource else { return nil }
        return linking.assetURL(path)
    }

    /// The lane a card sits in on the open board.
    public func location(ofCard card: Card) -> Lane? { location(of: card)?.lane }

    /// The open board's card with this id, in its current state.
    public func card(withID id: String) -> Card? {
        guard let board else { return nil }
        for column in board.columns {
            if let found = column.cards.first(where: { $0.id == id }) { return found }
        }
        return board.uncategorised.first { $0.id == id }
    }

    /// Whether the open board's files are real files on this Mac (a folder), so opening
    /// one in another app edits the board itself.
    public var cardFilesAreLocal: Bool { source is LocalFolderSource }

    /// A card's Markdown file, to open in another app. For a folder that is the file
    /// itself; for a repository it is a copy downloaded into the caches folder, and
    /// changes made to that copy do not go back to the repository.
    public func fileURL(for card: Card) async -> URL? {
        guard let source, let path = location(of: card)?.path else { return nil }
        if source is LocalFolderSource, let url = (source as? any AssetLinkingSource)?.assetURL(path) { return url }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitKanbanFiles", isDirectory: true)
        let key = (activeRepo?.id ?? "source").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "source"
        let target = caches.appendingPathComponent(key, isDirectory: true).appendingPathComponent(path)
        do {
            let data = try await source.readData(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return target
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// A local file URL for an asset (Quick Look / RealityKit need one). Local folders
    /// return the file itself; other sources download it once into the caches folder.
    public func localAssetURL(_ request: ReviewRequest, file: String) async -> URL? {
        guard let source, let path = request.assetPath(file) else { return nil }
        if source is LocalFolderSource, let url = (source as? any AssetLinkingSource)?.assetURL(path) { return url }
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitKanbanAssets", isDirectory: true)
        let key = (activeRepo?.id ?? "source").addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "source"
        let target = caches.appendingPathComponent(key, isDirectory: true).appendingPathComponent(path)
        do {
            let data = try await source.readData(path)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target, options: .atomic)
            return target
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Raw bytes of an asset (small images, sprite sheets).
    public func assetData(_ request: ReviewRequest, file: String) async -> Data? {
        guard let source, let path = request.assetPath(file) else { return nil }
        return try? await source.readData(path)
    }

    // MARK: Live refresh

    /// Watch the source for changes and refresh the board/reviews they touch.
    func startWatching() {
        stopWatching()
        guard let observing = source as? any ChangeObservingSource else { return }
        let stream = observing.changes()
        watchTask = Task { [weak self] in
            var pending = Set<String>()
            var flushTask: Task<Void, Never>?
            for await paths in stream {
                guard !Task.isCancelled else { break }
                pending.formUnion(paths)
                flushTask?.cancel()
                flushTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    guard !Task.isCancelled, let self else { return }
                    let changed = pending
                    pending.removeAll()
                    await self.refresh(for: changed)
                }
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    private func refresh(for paths: Set<String>) async {
        guard let source, let project = selectedProject, let rootConfig = workspace?.rootConfig else { return }
        let projectPrefix = project.folder.isEmpty ? "" : project.folder + "/"
        // The relay reports "anything may have changed" when it cannot list a push fully.
        let everything = paths.contains(RelayClient.everything)
        let touchesBoard = everything || paths.contains { $0.hasPrefix(projectPrefix) || $0 == project.folder }
        let touchesReviews = everything || (reviewFolder.map { folder in paths.contains { $0.hasPrefix(folder + "/") } } ?? false)
        if touchesBoard, !isSaving,
           let fresh = try? await RemoteBoardStore.loadProjectBoard(
               source: source, project: project, rootConfig: rootConfig, loadBacklog: false) {
            board = fresh
        }
        if touchesReviews || touchesBoard { await loadReviews() }
    }
}
