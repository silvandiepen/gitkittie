import Foundation
import GitKittieKit
import GitPontCore

// The open board's documentation pages (see `BoardDocs`): its own, and those of folders
// in other repositories that its README links to.

extension AppModel {
    /// Whether the open board has pages beyond its README: what makes it show Docs.
    public var hasDocs: Bool {
        if docs.contains(where: { !$0.isAbout }) || !docSources.isEmpty { return true }
        // Not read yet: go by what this board had the last time it was read.
        guard isLoadingDocs || docsBoardKey == nil, let repo = activeRepo, let folder = activeBoardFolder else { return false }
        return boardsWithDocs.contains("\(repo.id)|\(folder)")
    }

    /// The boards known to have docs, kept between launches so a board shows its Docs row
    /// before its pages are read again.
    var boardsWithDocs: Set<String> {
        get { Set(defaults.stringArray(forKey: "gitkanban.boardsWithDocs") ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: "gitkanban.boardsWithDocs") }
    }

    /// A linked folder's repository, opened with the account that is signed in. Reads and
    /// writes go straight to the host; nothing is queued. Nil without a connection.
    func linkedDocSource(_ linked: DocSource) async -> (any BoardWritable)? {
        guard let connection else { return nil }
        let branch: String
        if let named = linked.branch, !named.isEmpty {
            branch = named
        } else if let known = docBranches[linked.repo] {
            branch = known
        } else {
            let reference = GitRepositoryReference(instance: connection.instance, namespace: linked.owner, name: linked.name)
            guard let found = try? await connection.provider.repository(reference, context: connection.requestContext) else { return nil }
            branch = found.reference.defaultBranch ?? "main"
            docBranches[linked.repo] = branch
        }
        return GitPontFileSource(provider: connection.provider, instance: connection.instance,
                                 owner: linked.owner, repo: linked.name, branch: branch, token: connection.token)
    }

    /// Read the open board's pages. Linked folders are listed; their pages are read when opened.
    public func loadDocs() async {
        guard let source, let folder = activeBoardFolder, let repo = activeRepo else {
            docs = []; docSources = []; docsBoardKey = nil; return
        }
        let key = "\(repo.id)|\(folder)"
        if docsBoardKey != key {
            // What this board had the last time shows until it is read again.
            docs = boardCache[key]?.docs ?? []
            docSources = boardCache[key]?.docSources ?? []
            docSourceProblems = [:]
            docsBoardKey = key
        }
        isLoadingDocs = true
        defer { isLoadingDocs = false }
        var pages = await BoardDocs.load(source: source, boardFolder: folder)
        let readme = (try? await source.readText(BoardDocs.join(folder, BoardDocs.aboutPath))) ?? ""
        let linkedFolders = BoardDocs.sources(inReadme: readme)
        var problems: [String: String] = [:]
        for linked in linkedFolders {
            guard let through = await linkedDocSource(linked) else {
                problems[linked.id] = connection == nil ? "Sign in to read \(linked.repo)." : "\(linked.repo) could not be opened with this account."
                continue
            }
            let listed = await BoardDocs.list(linked, through: through)
            if listed.isEmpty { problems[linked.id] = "No Markdown pages found in \(linked.folder.isEmpty ? "the repository" : linked.folder)." }
            // Pages already read stay read across a reload.
            pages += listed.map { page in docs.first { $0.id == page.id && $0.isLoaded } ?? page }
        }
        // The board may have been switched while this was reading.
        guard docsBoardKey == key else { return }
        docs = pages
        docSources = linkedFolders
        docSourceProblems = problems
        var known = boardsWithDocs
        if pages.contains(where: { !$0.isAbout }) || !linkedFolders.isEmpty { known.insert(key) } else { known.remove(key) }
        if known != boardsWithDocs { boardsWithDocs = known }
    }

    /// The page with its text, read now if it was only listed.
    public func openDoc(_ page: BoardDoc) async -> BoardDoc {
        guard !page.isLoaded, let linked = page.source, let through = await linkedDocSource(linked) else { return page }
        do {
            let loaded = try await BoardDocs.read(page, through: through)
            if let index = docs.firstIndex(where: { $0.id == page.id }) { docs[index] = loaded }
            return loaded
        } catch {
            errorMessage = error.localizedDescription
            return page
        }
    }

    /// Read every linked page that is only listed so far, so a search covers them all.
    public func loadAllDocTexts() async {
        guard docs.contains(where: { !$0.isLoaded }) else { return }
        isLoadingDocs = true
        var pages = docs
        for linked in docSources {
            guard let through = await linkedDocSource(linked) else { continue }
            pages = await BoardDocs.readAll(pages, of: linked, through: through)
        }
        // Keep what was typed or loaded meanwhile: only fill in what is still unread.
        for page in pages where page.isLoaded {
            if let index = docs.firstIndex(where: { $0.id == page.id && !$0.isLoaded }) { docs[index] = page }
        }
        isLoadingDocs = false
    }

    /// Save a page's text. Returns false when it was not written (see `errorMessage`).
    @discardableResult
    public func saveDoc(_ page: BoardDoc, text: String) async -> Bool {
        guard let source, let folder = activeBoardFolder else { return false }
        errorMessage = nil
        do {
            if let linked = page.source {
                guard linked.editable, let through = await linkedDocSource(linked) else {
                    errorMessage = "\(page.fileName) is read-only here: \(linked.label) is marked read-only in Board Settings → Docs."
                    return false
                }
                try await through.write(path: BoardDocs.join(linked.folder, page.path), text: text.hasSuffix("\n") ? text : text + "\n",
                                        message: "Update \(page.path)")
            } else {
                try await BoardDocs.write(source: source, boardFolder: folder, path: page.path, text: text, message: "Update \(page.path)")
            }
        } catch { errorMessage = error.localizedDescription; return false }
        if let index = docs.firstIndex(where: { $0.id == page.id }) {
            docs[index].text = text
            if !page.isAbout { docs[index].title = BoardDocs.title(of: text, fileName: page.fileName) }
        }
        return true
    }

    /// Add a page named after `title` to the board's own docs. Returns it, or nil when it was not written.
    public func createDoc(title rawTitle: String) async -> BoardDoc? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let source, let folder = activeBoardFolder, !title.isEmpty else { return nil }
        errorMessage = nil
        var name = BoardDocs.fileName(for: title)
        var number = 2
        while docs.contains(where: { $0.source == nil && $0.fileName.lowercased() == name.lowercased() }) {
            name = BoardDocs.fileName(for: "\(title) \(number)"); number += 1
        }
        let page = BoardDoc(path: "\(BoardDocs.folder)/\(name)", title: title, text: "# \(title)\n\n")
        do {
            try await BoardDocs.write(source: source, boardFolder: folder, path: page.path, text: page.text, message: "Add \(page.path)")
        } catch { errorMessage = error.localizedDescription; return nil }
        // After the board's other pages, before the linked ones.
        let index = docs.firstIndex { $0.source != nil } ?? docs.count
        docs.insert(page, at: index)
        return page
    }

    /// Where a page is written: the source to write through and its path there.
    private func place(of page: BoardDoc) async -> (through: any BoardWritable, path: String)? {
        if let linked = page.source {
            guard linked.editable, let through = await linkedDocSource(linked) else { return nil }
            return (through, BoardDocs.join(linked.folder, page.path))
        }
        guard let source, let folder = activeBoardFolder else { return nil }
        return (source, BoardDocs.join(folder, page.path))
    }

    public func deleteDoc(_ page: BoardDoc) async {
        guard !page.isAbout, let place = await place(of: page) else { return }
        errorMessage = nil
        do { try await place.through.delete(path: place.path, message: "Delete \(page.path)") }
        catch { errorMessage = error.localizedDescription; return }
        docs.removeAll { $0.id == page.id }
    }

    /// Give a page another file name (from a new title), in the folder it is in. The text
    /// stays as it is. Returns the page under its new name.
    public func renameDoc(_ page: BoardDoc, to rawTitle: String) async -> BoardDoc? {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !page.isAbout, !title.isEmpty, let place = await place(of: page) else { return nil }
        let name = BoardDocs.fileName(for: title)
        let directory = (page.path as NSString).deletingLastPathComponent
        var renamed = await openDoc(page)
        renamed.path = BoardDocs.join(directory, name)
        guard renamed.path != page.path else { return page }
        guard !docs.contains(where: { $0.id == renamed.id }) else {
            errorMessage = "There is already a page called \(name) there."
            return nil
        }
        errorMessage = nil
        let newPath = BoardDocs.join((place.path as NSString).deletingLastPathComponent, name)
        do {
            try await place.through.write(path: newPath, text: renamed.text, message: "Rename \(page.fileName) to \(name)")
            try await place.through.delete(path: place.path, message: "Rename \(page.fileName) to \(name)")
        } catch { errorMessage = error.localizedDescription; return nil }
        renamed.title = BoardDocs.title(of: renamed.text, fileName: name)
        if let index = docs.firstIndex(where: { $0.id == page.id }) { docs[index] = renamed }
        return renamed
    }

    /// A copy of a page next to it, named "… copy".
    public func duplicateDoc(_ page: BoardDoc) async -> BoardDoc? {
        guard !page.isAbout, let place = await place(of: page) else { return nil }
        let original = await openDoc(page)
        let directory = (page.path as NSString).deletingLastPathComponent
        let base = (page.fileName as NSString).deletingPathExtension
        var name = "\(base)-copy.md"
        var number = 2
        while docs.contains(where: { $0.source == page.source && $0.path == BoardDocs.join(directory, name) }) {
            name = "\(base)-copy-\(number).md"; number += 1
        }
        var copy = original
        copy.path = BoardDocs.join(directory, name)
        errorMessage = nil
        do {
            try await place.through.write(path: BoardDocs.join((place.path as NSString).deletingLastPathComponent, name),
                                          text: original.text, message: "Duplicate \(page.fileName)")
        } catch { errorMessage = error.localizedDescription; return nil }
        let index = docs.firstIndex { $0.id == page.id }.map { $0 + 1 } ?? docs.count
        docs.insert(copy, at: index)
        return copy
    }

    /// The path of a page in its repository, for handing to an agent.
    public func docPath(_ page: BoardDoc) -> String {
        if let linked = page.source { return BoardDocs.join(linked.folder, page.path) }
        return BoardDocs.join(activeBoardFolder ?? "", page.path)
    }

    /// The link to a page: the host's page for it, or the file on disk for a board in a folder.
    public func docLink(_ page: BoardDoc) async -> URL? {
        if let linked = page.source {
            return (await linkedDocSource(linked) as? any WebLinkingSource)?.webURL(forPath: docPath(page))
        }
        return (source as? any WebLinkingSource)?.webURL(forPath: docPath(page))
    }

    /// Set which folders in other repositories the open board links to (its README's `docs:`).
    @discardableResult
    public func saveDocSources(_ sources: [DocSource]) async -> Bool {
        guard let source, let folder = activeBoardFolder else { return false }
        errorMessage = nil
        let path = BoardDocs.join(folder, BoardDocs.aboutPath)
        do {
            let readme = try await source.readText(path)
            let updated = BoardDocs.setting(sources, inReadme: readme)
            if updated != readme { try await source.write(path: path, text: updated, message: "Update linked docs") }
        } catch { errorMessage = error.localizedDescription; return false }
        await loadDocs()
        return true
    }
}
