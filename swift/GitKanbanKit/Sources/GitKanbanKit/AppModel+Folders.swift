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

    /// Load the open board's review requests: from its `review_path`, or its own
    /// `review/` folder when that is unset or cannot be reached in this source.
    public func loadReviews() async {
        guard let source, let project = selectedProject, let board else {
            reviews = []
            reviewFolder = nil
            return
        }
        guard let folder = Review.reviewFolder(board.config.reviewPath, projectFolder: project.folder) else {
            reviews = []
            reviewFolder = nil
            return
        }
        reviewFolder = folder
        isLoadingReviews = true
        defer { isLoadingReviews = false }
        let origin = activeRepo?.id ?? ""
        let onScreen = openBoardKey
        let loaded = Self.newestFirst(await RemoteBoardStore.loadReviews(source: source, folder: folder).map {
            var request = $0
            request.origin = origin
            return request
        })
        // The requests of a board that is no longer on screen are not this board's.
        guard openBoardKey == onScreen else { return }
        reviews = loaded
        if serverLogin == nil, let server = source as? ServerFolderSource {
            serverLogin = await server.whoami()?.login
        }
        // The inbox shows the same requests: keep its copy of this board in step.
        if let repo = activeRepo, let index = reviewInbox.firstIndex(where: { $0.repoID == repo.id && $0.boardFolder == project.folder }) {
            reviewInbox[index].requests = reviews
        }
    }

    /// Review requests that belong to a card (by `card:` id).
    public func reviews(for card: Card) -> [ReviewRequest] {
        reviews.filter { $0.card == card.fields.id }
    }

    /// Entries across the open board still waiting on you (requests for others left out).
    public var pendingReviewCount: Int { reviews.filter(isForMe).reduce(0) { $0 + $1.summary.pending } }

    /// Who decisions and comments are recorded as: the board user matching the server's
    /// Tailscale login or this device's account (by `github` or `id`), or the one you said you
    /// are on the board, else that login.
    public var reviewerID: String { reviewerID(among: board?.config.users ?? [], boardKey: openReviewBoardKey) }

    func reviewerID(among users: [User], boardKey: String? = nil) -> String {
        if let user = reviewUser(among: users, boardKey: boardKey) { return user }
        let handle = reviewLogin
        return handle.isEmpty ? "reviewer" : handle
    }

    /// The reviewer's name on the board a request belongs to.
    func reviewerID(for request: ReviewRequest) -> String {
        reviewerID(among: reviewBoardUsers(for: request), boardKey: reviewBoardKey(for: request))
    }

    /// The source a request's files are read from and written to: the open board's when
    /// the request is from there, else the repository or folder it was loaded from.
    func reviewSource(for request: ReviewRequest) -> (any BoardWritable)? {
        if request.origin.isEmpty || request.origin == activeRepo?.id, let source { return source }
        if let repo = addedRepos.first(where: { $0.id == request.origin }) { return self.source(for: repo) }
        return source
    }

    /// A request in its current state, wherever it was loaded (the open board or the inbox).
    public func reviewRequest(_ ref: ReviewRef) -> ReviewRequest? {
        if let found = reviews.first(where: { $0.ref == ref }) { return found }
        for entry in reviewInbox {
            if let found = entry.requests.first(where: { $0.ref == ref }) { return found }
        }
        return nil
    }

    /// Decide on one file. Changes needs a comment (`ReviewStatus.needsComment`): without one
    /// nothing is written and `errorMessage` says why. A comment goes in the same write as the
    /// decision. Returns whether it was written.
    @discardableResult
    public func decide(_ request: ReviewRequest, item: ReviewItem, status: ReviewStatus, comment: String? = nil) async -> Bool {
        guard ReviewDecisionRule.canSend(status, comment: comment) else {
            errorMessage = ReviewDecisionRule.commentRequired
            return false
        }
        let by = reviewerID(for: request)
        let at = ReviewEdit.now()
        var edits: [ReviewEdit] = [.decision(item: item.id, status: status, by: by, at: at)]
        if let note = comment.map(Self.trimmed), !note.isEmpty {
            edits.append(.comment(item: item.id, by: by, text: note, image: nil, at: at))
        }
        await rewriteReview(request, edits)
        return errorMessage == nil
    }

    public func comment(_ request: ReviewRequest, item: ReviewItem, text: String) async {
        let by = reviewerID(for: request)
        await rewriteReview(request, [.comment(item: item.id, by: by, text: Self.trimmed(text), image: nil, at: ReviewEdit.now())])
    }

    /// Answer a question, or change the answer while the agent has not acted on it. The
    /// answer is checked against the question in the file (one choice for `select: one`);
    /// a refused answer is reported in `errorMessage` and nothing is written.
    /// Returns whether the answer was written.
    @discardableResult
    public func answer(_ request: ReviewRequest, question: ReviewQuestion, choices: [String], other: String?, comment: String? = nil) async -> Bool {
        let by = reviewerID(for: request)
        let at = ReviewEdit.now()
        var edits: [ReviewEdit] = [.answer(question: question.id, choices: choices, other: other, by: by, at: at)]
        if let note = comment.map(Self.trimmed), !note.isEmpty {
            edits.append(.questionComment(question: question.id, by: by, text: note, at: at))
        }
        await rewriteReview(request, edits)
        return errorMessage == nil
    }

    /// Comment on a question without changing its answer.
    public func comment(_ request: ReviewRequest, question: ReviewQuestion, text: String) async {
        let by = reviewerID(for: request)
        await rewriteReview(request, [.questionComment(question: question.id, by: by, text: Self.trimmed(text), at: ReviewEdit.now())])
    }

    // MARK: Whole requests at once

    /// Give every item that is still waiting the same answer, in one write. Groups where
    /// one item has to be picked are left alone when approving: approving them all would
    /// pick nothing. Questions are never answered this way: each needs its own answer.
    /// Changes needs a comment, which every one of those files gets; without it nothing is
    /// written. Returns whether it was written (or there was nothing waiting).
    @discardableResult
    public func decideAll(_ request: ReviewRequest, status: ReviewStatus, comment: String? = nil) async -> Bool {
        guard ReviewDecisionRule.canSend(status, comment: comment) else {
            errorMessage = ReviewDecisionRule.commentRequired
            return false
        }
        let by = reviewerID(for: request)
        let waiting = request.items.filter { item in
            guard item.status == .pending else { return false }
            return !(status == .approved && item.pickOne) && !(status == .approved && request.groups.contains { $0.pickOne && $0.items.contains(item) })
        }
        guard !waiting.isEmpty else { return true }
        let at = ReviewEdit.now()
        await rewriteReview(request, Self.edits(deciding: waiting.map(\.id), commenting: waiting.map(\.id),
                                                status: status, comment: comment, by: by, at: at))
        return errorMessage == nil
    }

    /// The edits of one decision on several files: a decision per file in `deciding`, then the
    /// comment (when there is one) on each file in `commenting`, all at the same time.
    private static func edits(deciding: [String], commenting: [String], status: ReviewStatus, comment: String?,
                              by: String, at: Date) -> [ReviewEdit] {
        var edits: [ReviewEdit] = deciding.map { .decision(item: $0, status: status, by: by, at: at) }
        if let note = comment.map(trimmed), !note.isEmpty {
            edits += commenting.map { .comment(item: $0, by: by, text: note, image: nil, at: at) }
        }
        return edits
    }

    /// The same comment on every item of a request (or only those still waiting), in one write.
    /// Questions keep their own comments.
    public func commentAll(_ request: ReviewRequest, text raw: String, onlyWaiting: Bool = false) async {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = request.items.filter { !onlyWaiting || $0.status == .pending }
        guard !body.isEmpty, !targets.isEmpty else { return }
        let by = reviewerID(for: request)
        let at = ReviewEdit.now()
        await rewriteReview(request, targets.map { .comment(item: $0.id, by: by, text: body, image: nil, at: at) })
    }

    // MARK: A selection of files

    /// Give the chosen files of a request the same decision, in one write (one outbox entry
    /// carrying an edit per file). Files that already have that decision are left as they
    /// are. Approving is refused, and nothing written, when it would leave more than one
    /// option of a pick-one group approved; `errorMessage` then says which. Changes needs a
    /// comment, and every chosen file gets it (also one that already asked for changes).
    /// Returns whether the decision was written (or there was nothing to change).
    @discardableResult
    public func decide(_ request: ReviewRequest, itemIDs: some Collection<String>, status: ReviewStatus, comment: String? = nil) async -> Bool {
        let chosen = request.items(withIDs: itemIDs)
        errorMessage = nil
        guard ReviewDecisionRule.canSend(status, comment: comment) else {
            errorMessage = ReviewDecisionRule.commentRequired
            return false
        }
        if status == .approved, let conflict = request.pickOneConflict(approving: chosen.map(\.id)) {
            errorMessage = conflict.message
            return false
        }
        let changing = chosen.filter { $0.status != status }
        let hasComment = !(comment.map(Self.trimmed) ?? "").isEmpty
        guard !changing.isEmpty || (hasComment && !chosen.isEmpty) else { return true }
        let by = reviewerID(for: request)
        let at = ReviewEdit.now()
        await rewriteReview(request, Self.edits(deciding: changing.map(\.id), commenting: chosen.map(\.id),
                                                status: status, comment: comment, by: by, at: at))
        return errorMessage == nil
    }

    /// The same comment on each of the chosen files of a request, and on no other, in one write.
    /// Returns whether the comment was written.
    @discardableResult
    public func comment(_ request: ReviewRequest, itemIDs: some Collection<String>, text raw: String) async -> Bool {
        let body = Self.trimmed(raw)
        let targets = request.items(withIDs: itemIDs)
        guard !body.isEmpty, !targets.isEmpty else { return false }
        let by = reviewerID(for: request)
        let at = ReviewEdit.now()
        await rewriteReview(request, targets.map { .comment(item: $0.id, by: by, text: body, image: nil, at: at) })
        return errorMessage == nil
    }

    /// Remove a request and its files from the board, answered or not. Git keeps its history.
    public func removeReview(_ request: ReviewRequest) async {
        guard let source = reviewSource(for: request) else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            var files: [String] = []
            for entry in try await source.list(request.folder) {
                if entry.kind == .directory {
                    files += ((try? await source.list(entry.path)) ?? []).filter { $0.kind == .file }.map(\.path)
                } else {
                    files.append(entry.path)
                }
            }
            // The request file goes last: until then the request still shows, with what is left.
            let ordered = files.filter { $0 != request.path } + files.filter { $0 == request.path }
            for file in ordered { try await source.delete(path: file, message: "Remove review \(request.id)") }
        } catch {
            errorMessage = error.localizedDescription
        }
        reviews.removeAll { $0.ref == request.ref }
        for index in reviewInbox.indices { reviewInbox[index].requests.removeAll { $0.ref == request.ref } }
        await refreshReviews()
    }

    /// The path of a request's file in its repository, for handing to an agent.
    public func reviewPath(_ request: ReviewRequest, file: String? = nil) -> String {
        file.map { "\(request.folder)/\($0)" } ?? request.folder
    }

    /// The link to a request's folder or one of its files: the host's page for it, or the
    /// file on disk for a board in a folder.
    public func reviewLink(_ request: ReviewRequest, file: String? = nil) -> URL? {
        (reviewSource(for: request) as? any WebLinkingSource)?.webURL(forPath: reviewPath(request, file: file))
    }

    /// Comment on an item with a marked-up copy of it: the image is written next to the
    /// request (`annotations/`), and the comment points at it so the agent can open it.
    public func annotate(_ request: ReviewRequest, item: ReviewItem, image: Data, fileExtension: String, text: String) async {
        guard let source = reviewSource(for: request) else { return }
        let stamp = Review.timestamp(Date()).filter { $0.isNumber }
        let safeID = String(item.id.map { $0.isLetter || $0.isNumber || "-_".contains($0) ? $0 : "-" })
        let file = "annotations/\(safeID)-\(stamp).\(fileExtension)"
        guard let path = request.assetPath(file) else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await source.writeData(path: path, data: image, message: "Annotate \(item.id) in review \(request.id)")
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
            return
        }
        isSaving = false
        let by = reviewerID(for: request)
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "See the marked-up image." : text
        await rewriteReview(request, [.comment(item: item.id, by: by, text: Self.trimmed(body), image: file, at: ReviewEdit.now())])
    }

    /// Read-modify-write a `review.md`, only touching reviewer fields. On sources that
    /// support it, the write is compare-and-swap; a concurrent agent edit is re-read and
    /// the change re-applied (up to 3 times) instead of overwritten. Through the outbox the
    /// edits travel with the write, and are applied again onto the server's copy when sent.
    func rewriteReview(_ request: ReviewRequest, _ edits: [ReviewEdit]) async {
        guard let source = reviewSource(for: request) else { return }
        // Someone else's request: comments yes, decisions and answers no.
        if edits.contains(where: \.isDecision), isReadOnly(request) {
            errorMessage = readOnlyNotice(request)
            return
        }
        isSaving = true
        errorMessage = nil
        var written: (before: String, after: String)?
        do {
            if let versioned = source as? any VersionedBoardSource {
                var attempt = 0
                while true {
                    let (text, version) = try await versioned.readVersioned(request.path)
                    do {
                        let next = try Review.apply(text, edits: edits)
                        try await versioned.write(path: request.path, text: next, ifVersion: version, message: "Review \(request.id)")
                        written = (text, next)
                        break
                    } catch is SourceConflictError where attempt < 2 {
                        attempt += 1
                    }
                }
            } else if let editing = source as? any ReviewEditingSource {
                let text = try await editing.readText(request.path)
                let next = try Review.apply(text, edits: edits)
                try await editing.writeReview(path: request.path, text: next, edits: edits, message: "Review \(request.id)")
                written = (text, next)
            } else {
                let text = try await source.readText(request.path)
                let next = try Review.apply(text, edits: edits)
                try await source.write(path: request.path, text: next, message: "Review \(request.id)")
                written = (text, next)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
        await reloadReview(request)
        // The decision that settles a request (or an entry) runs its actions.
        if let written, edits.contains(where: \.isDecision) {
            var before = Review.parse(written.before, folder: request.folder), after = Review.parse(written.after, folder: request.folder)
            before.origin = request.origin
            after.origin = request.origin
            await runReviewActions(request, before: before, after: after)
        }
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func reloadReview(_ request: ReviewRequest) async {
        guard let source = reviewSource(for: request), let text = try? await source.readText(request.path) else { return }
        var fresh = Review.parse(text, folder: request.folder)
        fresh.origin = request.origin
        if let index = reviews.firstIndex(where: { $0.ref == request.ref }) { reviews[index] = fresh }
        for entry in reviewInbox.indices {
            if let index = reviewInbox[entry].requests.firstIndex(where: { $0.ref == request.ref }) {
                reviewInbox[entry].requests[index] = fresh
            }
        }
    }

    /// A URL that streams an asset (AVPlayer, image loading) when the source can address
    /// files directly; `nil` otherwise — use `localAssetURL` then.
    public func streamURL(_ request: ReviewRequest, file: String) -> URL? {
        guard let path = request.assetPath(file), let linking = reviewSource(for: request) as? any AssetLinkingSource else { return nil }
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

    /// Where a downloaded copy of a request's file is kept. The name carries the request's
    /// source, so two repositories with the same path do not share a copy.
    private func cachedAssetURL(_ request: ReviewRequest, path: String) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GitKanbanAssets", isDirectory: true)
        let origin = request.origin.isEmpty ? (activeRepo?.id ?? "source") : request.origin
        let key = origin.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "source"
        return caches.appendingPathComponent(key, isDirectory: true).appendingPathComponent(path)
    }

    /// A local file URL for an asset (Quick Look / RealityKit need one). Local folders
    /// return the file itself; other sources download it once into the caches folder.
    public func localAssetURL(_ request: ReviewRequest, file: String) async -> URL? {
        guard let source = reviewSource(for: request), let path = request.assetPath(file) else { return nil }
        if source is LocalFolderSource, let url = (source as? any AssetLinkingSource)?.assetURL(path) { return url }
        let target = cachedAssetURL(request, path: path)
        if FileManager.default.fileExists(atPath: target.path) { return target }
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

    /// Raw bytes of an asset (images, sprite sheets). From a repository or a server the
    /// file is downloaded once and kept in the caches folder: a review file is never
    /// changed under the same name, and fetching it again on every look is what makes
    /// reviewing slow.
    public func assetData(_ request: ReviewRequest, file: String) async -> Data? {
        guard let source = reviewSource(for: request), let path = request.assetPath(file) else { return nil }
        if source is LocalFolderSource { return try? await source.readData(path) }
        let target = cachedAssetURL(request, path: path)
        if let cached = try? Data(contentsOf: target, options: .mappedIfSafe) { return cached }
        guard let data = try? await source.readData(path) else { return nil }
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: target, options: .atomic)
        return data
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
        let onScreen = openBoardKey
        if touchesBoard, !isSaving,
           let fresh = try? await RemoteBoardStore.loadProjectBoard(
               source: source, project: project, rootConfig: rootConfig, loadBacklog: false) {
            // Another board may have been opened while this one was read.
            guard openBoardKey == onScreen, selectedProject?.id == project.id else { return }
            board = fresh
        }
        if touchesReviews || touchesBoard { await loadReviews() }
    }
}
