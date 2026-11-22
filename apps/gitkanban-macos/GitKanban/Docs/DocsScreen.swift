import GitKanbanKit
import GitKittieKit
import SwiftUI

/// The open board's documentation: its pages on the left (or what a search found), the
/// page being read and edited on the right. A page is a Markdown file in the board's
/// `docs` folder, "About" is the text of its README, and the pages of folders linked from
/// other repositories are listed under them, by folder.
struct DocsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var selected: String?
    @State private var text = ""
    @State private var editorHeight: CGFloat = 0
    @State private var query = ""
    @State private var newTitle = ""
    @State private var isNaming = false
    @State private var isSaving = false
    @State private var deleting: BoardDoc?
    @State private var renaming: BoardDoc?
    @State private var renameTitle = ""
    @State private var commands = MarkdownCommands()

    private var page: BoardDoc? { model.docs.first { $0.id == selected } }
    private var hits: [BoardDocHit] { BoardDocs.search(model.docs, query: query) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var isDirty: Bool { page.map { $0.isLoaded && $0.isEditable && $0.text != text } ?? false }
    private var ownPages: [BoardDoc] { model.docs.filter { $0.source == nil } }

    var body: some View {
        HSplitView {
            pageList
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
            pageView
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(model.selectedProject.map { "\($0.name) Docs" } ?? "Docs")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isSaving { ProgressView().controlSize(.small) }
                Button("Save", systemImage: "checkmark") { Task { await save() } }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(!isDirty || isSaving)
                    .help("Save this page (⌘S)")
                Button("New Page", systemImage: "plus") { newTitle = ""; isNaming = true }
                    .help("Add a page to this board's docs")
                    .accessibilityIdentifier("docsNewPage")
                Button("Reload", systemImage: "arrow.clockwise") { Task { await model.loadDocs() } }
                    .help("Read the pages again")
            }
        }
        .task(id: model.docs.map(\.id)) { if page == nil { open(model.docs.first { !$0.isAbout } ?? model.docs.first) } }
        // A search has to cover the linked pages too, which are only read when opened.
        .task(id: isSearching) { if isSearching { await model.loadAllDocTexts() } }
        .alert("New Page", isPresented: $isNaming) {
            TextField("Title", text: $newTitle)
            Button("Add") { Task { await add() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The page is a Markdown file in this board's docs folder.")
        }
        .alert("Rename Page", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameTitle)
            Button("Rename") {
                guard let target = renaming else { return }
                let title = renameTitle
                Task { if let renamed = await model.renameDoc(target, to: title), selected == target.id { open(renamed) } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("The file gets a new name; links to the old name elsewhere are not changed.")
        }
        .confirmationDialog("Delete “\(deleting?.title ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Page", role: .destructive) {
                guard let target = deleting else { return }
                Task {
                    await model.deleteDoc(target)
                    if selected == target.id { open(model.docs.first { !$0.isAbout } ?? model.docs.first) }
                }
            }
        } message: {
            Text("The file is removed from the repository. Its history stays in git.")
        }
    }

    /// One page in the list: its title, and under it the file it is, when that says more.
    private func pageRow(_ doc: BoardDoc) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: doc.isAbout ? "info.circle" : "doc.text")
                .font(.callout).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(doc.title).font(.callout).lineLimit(1).truncationMode(.tail).help(doc.title)
                if !doc.isAbout, BoardDocs.title(of: "", fileName: doc.fileName).caseInsensitiveCompare(doc.title) != .orderedSame {
                    Text(doc.fileName).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .listRowSeparator(.hidden)
        .tag(doc.id)
        .contextMenu { pageMenu(doc) }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// What can be done with a page, from a right-click on it.
    @ViewBuilder private func pageMenu(_ doc: BoardDoc) -> some View {
        Button("Open", systemImage: "doc.text") { open(doc) }
        Divider()
        Button("Copy Link", systemImage: "link") {
            Task { if let link = await model.docLink(doc) { copy(link.isFileURL ? link.path : link.absoluteString) } }
        }
        Button("Copy Path", systemImage: "doc.on.doc") { copy(model.docPath(doc)) }
        Button("Copy as Markdown", systemImage: "text.alignleft") {
            Task { copy(await model.openDoc(doc).text) }
        }
        Button("Open in Browser", systemImage: "safari") {
            Task {
                guard let link = await model.docLink(doc) else { return }
                if link.isFileURL { NSWorkspace.shared.activateFileViewerSelecting([link]) } else { NSWorkspace.shared.open(link) }
            }
        }
        if !doc.isAbout {
            Divider()
            Button("Rename…", systemImage: "pencil") { renameTitle = BoardDocs.title(of: "", fileName: doc.fileName); renaming = doc }
                .disabled(!doc.isEditable)
            Button("Duplicate", systemImage: "plus.square.on.square") {
                Task { if let made = await model.duplicateDoc(doc) { open(made) } }
            }
            .disabled(!doc.isEditable)
            Divider()
            Button("Delete Page…", systemImage: "trash", role: .destructive) { deleting = doc }
                .disabled(!doc.isEditable)
        }
    }

    private var pageList: some View {
        VStack(spacing: 0) {
            TextField("Search these docs", text: $query, prompt: Text("Search these docs"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
                .accessibilityIdentifier("docsSearch")
            List(selection: Binding(get: { selected }, set: { id in open(model.docs.first { $0.id == id }) })) {
                if isSearching {
                    if model.isLoadingDocs {
                        HStack { ProgressView().controlSize(.small); Text("Reading the linked pages…").foregroundStyle(.secondary) }
                    } else if hits.isEmpty {
                        Text("Nothing found for “\(query)”").foregroundStyle(.secondary)
                    }
                    ForEach(hits) { hit in
                        Button { open(model.docs.first { $0.id == hit.doc }) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.heading.map { "\(hit.title) › \($0)" } ?? hit.title)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(hit.line).font(.callout).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    ForEach(ownPages) { doc in
                        pageRow(doc)
                    }
                    // Linked folders: one section each, their subfolders folded.
                    ForEach(model.docSources) { linked in
                        let pages = model.docs.filter { $0.source == linked }
                        Section {
                            if let problem = model.docSourceProblems[linked.id] {
                                Text(problem).font(.caption).foregroundStyle(.secondary)
                            }
                            // Folders fold open; a page is a leaf.
                            OutlineGroup(DocNode.tree(of: pages), children: \.children) { node in
                                if let doc = node.doc {
                                    pageRow(doc)
                                } else {
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder").font(.callout).foregroundStyle(.secondary).frame(width: 16)
                                        Text(node.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                                        Spacer()
                                        Text("\(node.pageCount)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                                    }
                                    .padding(.vertical, 3)
                                    .listRowSeparator(.hidden)
                                }
                            }
                        } header: {
                            HStack(spacing: 5) {
                                Image(systemName: linked.editable ? "link" : "lock").font(.caption2)
                                Text(linked.label).font(.caption.weight(.semibold)).textCase(.uppercase)
                                Spacer()
                                Text("\(pages.count) pages").font(.caption).monospacedDigit()
                            }
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                            .help(linked.editable ? "Pages of \(linked.repo); a save is a commit there" : "Pages of \(linked.repo), read-only here")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.docs.isEmpty, model.docSources.isEmpty {
                    if model.isLoadingDocs {
                        ProgressView()
                    } else {
                        VStack(spacing: 10) {
                            Text("No pages yet").font(.headline)
                            Text("Plans, specs and decisions about this project go here.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("New Page") { newTitle = ""; isNaming = true }
                        }
                        .padding()
                    }
                }
            }
        }
    }

    @ViewBuilder private var pageView: some View {
        if let page {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(page.isAbout ? "README.md" : page.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if !page.isEditable {
                            Label("Read-only", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                                .help("This folder of \(page.source?.repo ?? "") is marked read-only in Board Settings → Docs.")
                        } else if isDirty {
                            Text("Edited").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    if page.isEditable {
                        MarkdownFormatBar(commands: commands)
                        Divider()
                    }
                    if page.isLoaded {
                        MarkdownEditor(text: $text, contentHeight: $editorHeight, fontSize: 14, isEditable: page.isEditable,
                                       onCommit: { Task { await save() } }, commands: commands)
                            .frame(height: max(editorHeight, 400))
                    } else {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    }
                    if let error = model.errorMessage {
                        Text(error).font(.callout).foregroundStyle(.red)
                    }
                }
                .padding(24)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else {
            Text(model.docs.isEmpty ? "" : "Select a page").foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Show a page. What was typed in the page before it is saved first.
    private func open(_ doc: BoardDoc?) {
        let leaving = page, typed = text
        if let leaving, leaving.isLoaded, leaving.isEditable, leaving.text != typed, leaving.id != doc?.id {
            Task { await model.saveDoc(leaving, text: typed) }
        }
        selected = doc?.id
        text = doc?.text ?? ""
        // A linked page is only listed until it is opened.
        if let doc, !doc.isLoaded {
            Task {
                let loaded = await model.openDoc(doc)
                if selected == loaded.id { text = loaded.text }
            }
        }
    }

    private func save() async {
        guard let page, isDirty else { return }
        isSaving = true
        await model.saveDoc(page, text: text)
        isSaving = false
    }

    private func add() async {
        if let made = await model.createDoc(title: newTitle) { open(made) }
    }
}

/// A linked folder's pages as a tree: folders with what is in them, pages as leaves.
struct DocNode: Identifiable {
    let id: String
    let name: String
    var doc: BoardDoc?
    var children: [DocNode]?

    var pageCount: Int { doc != nil ? 1 : (children ?? []).reduce(0) { $0 + $1.pageCount } }

    /// The tree of `pages`, by their paths: folders first, then pages, each A to Z.
    static func tree(of pages: [BoardDoc], under prefix: String = "") -> [DocNode] {
        var folders: [String: [BoardDoc]] = [:]
        var leaves: [DocNode] = []
        for page in pages {
            let rest = prefix.isEmpty ? page.path : String(page.path.dropFirst(prefix.count + 1))
            let parts = rest.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2 { folders[parts[0], default: []].append(page) }
            else { leaves.append(DocNode(id: page.id, name: page.title, doc: page, children: nil)) }
        }
        let branches = folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name -> DocNode in
            let path = prefix.isEmpty ? name : "\(prefix)/\(name)"
            return DocNode(id: "folder:\(pages.first?.source?.id ?? "")/\(path)", name: name, doc: nil,
                           children: tree(of: folders[name] ?? [], under: path))
        }
        return branches + leaves
    }
}
