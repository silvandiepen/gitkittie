import GitKittieKit
import GitKanbanKit
import SwiftUI

/// Create a board, or edit an existing board's settings. A new board (and the set-up of a
/// detected one) is one short form. The settings of an existing board are a window with
/// its parts on the left: General, Lanes, Priorities, Members, Types and Epics. Saving
/// rewrites the board's README.
struct ProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// nil = create a new project; non-nil = edit that project's settings.
    var editing: BoardProject?
    /// When set, prefill the form from an auto-detected config (board setup flow).
    var prefill: DetectedBoardConfig?

    /// One row of a list: a lane, a priority, a member, a type or an epic.
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var text: String
        /// What the row was when the settings opened, for lanes and epics: they keep their id.
        var lane: Lane?
        var epic: Epic?
    }

    /// The parts of a board's settings, as the sidebar of the settings window lists them.
    enum Category: String, CaseIterable, Identifiable {
        case general = "General", products = "Products", lanes = "Lanes", priorities = "Priorities", members = "Members", types = "Types", epics = "Epics", docs = "Docs"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .lanes: return "rectangle.split.3x1"
            case .priorities: return "flag"
            case .members: return "person.2"
            case .types: return "tag"
            case .epics: return "square.stack.3d.up"
            case .docs: return "doc.text"
            case .products: return "shippingbox"
            }
        }
        var hint: String {
            switch self {
            case .general, .docs, .products: return ""
            case .lanes: return "Lane name"
            case .priorities: return "P0"
            case .members: return "username"
            case .types: return "feature"
            case .epics: return "Epic name"
            }
        }
        var singular: String {
            switch self {
            case .general, .docs, .products: return ""
            case .lanes: return "Lane"
            case .priorities: return "Priority"
            case .members: return "Member"
            case .types: return "Type"
            case .epics: return "Epic"
            }
        }
        /// Merging rewrites a field on every task. A lane is a folder of tasks, not a field.
        var canMerge: Bool { self != .lanes && self != .general && self != .docs && self != .products }
        /// Parts that are a plain list of names.
        var isList: Bool { self != .general && self != .docs && self != .products }
    }

    /// A row folded into another one: what it was, and the row it went into.
    struct PendingMerge: Identifiable {
        let id = UUID()
        var category: Category
        var from: Entry
        var into: UUID
    }

    @State private var name = ""
    @State private var description = ""
    @State private var icon: String?
    @State private var color: String?
    @State private var lanes: [Entry] = AppModel.defaultProjectLanes().map { Entry(text: $0.name) }
    @State private var priorities: [Entry] = AppModel.defaultPriorities().map { Entry(text: $0.id) }
    @State private var members: [Entry] = []
    @State private var types: [Entry] = []
    @State private var epics: [Entry] = []
    @State private var merges: [PendingMerge] = []
    /// Folders in other repositories whose pages the board shows under Docs.
    @State private var docSources: [DocSource] = []
    @State private var newSource = ""
    /// The board's products, with the id each had when the settings opened.
    @State private var productRows: [ProductRow] = []

    struct ProductRow: Identifiable {
        let id = UUID()
        var name: String
        var prefix: String
        var original: BoardProduct?
    }
    @State private var sourceProblem: String?
    @State private var selection: Set<UUID> = []
    /// A field of a list row: its name, or a product's prefix.
    enum RowField: Hashable {
        case name(UUID), prefix(UUID)
        var row: UUID { switch self { case .name(let id), .prefix(let id): id } }
    }
    /// The row field being typed in, right in the list: a row just added, or one double-clicked.
    @State private var editingField: RowField?
    @FocusState private var focusedField: RowField?
    @State private var category: Category = .general
    @State private var seeded = false
    @State private var detecting = false

    private var isEditing: Bool { editing != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Settings of an existing board come one part at a time.
    private var isCategorized: Bool { isEditing && prefill == nil }

    private func entries(_ category: Category) -> Binding<[Entry]> {
        switch category {
        case .lanes: return $lanes
        case .priorities: return $priorities
        case .members: return $members
        case .types: return $types
        case .epics, .general, .docs, .products: return $epics
        }
    }

    static func laneColor(_ i: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.23, green: 0.51, blue: 0.96),
            Color(red: 0.96, green: 0.62, blue: 0.09), Color(red: 0.91, green: 0.70, blue: 0.05),
            Color(red: 0.13, green: 0.77, blue: 0.37), Color(red: 0.09, green: 0.64, blue: 0.72),
        ]
        return palette[i % palette.count]
    }

    static func priorityColor(_ i: Int) -> Color {
        let ramp: [Color] = [
            Color(red: 0.90, green: 0.26, blue: 0.21), Color(red: 0.96, green: 0.55, blue: 0.09),
            Color(red: 0.23, green: 0.51, blue: 0.96), Color(red: 0.45, green: 0.50, blue: 0.58),
        ]
        return ramp[min(i, ramp.count - 1)]
    }

    /// A field without the leading label a macOS form gives every text field; the hint
    /// shows inside the empty field instead.
    private func field(_ hint: String, _ text: Binding<String>) -> some View {
        TextField(hint, text: text, prompt: Text(hint)).labelsHidden()
    }

    /// Text in a list row that turns into a field to type in when it is double-clicked, or
    /// when its row was just added. Return or clicking away ends the edit.
    @ViewBuilder private func editableText(_ text: Binding<String>, hint: String, field: RowField) -> some View {
        if editingField == field {
            TextField(hint, text: text, prompt: Text(hint))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .onSubmit { editingField = nil }
                .onAppear { Task { @MainActor in focusedField = field } }
                .accessibilityIdentifier("settingsRename")
        } else {
            Text(text.wrappedValue.isEmpty ? hint : text.wrappedValue)
                .foregroundStyle(text.wrappedValue.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // Simultaneous, so the first click still selects the row.
                .simultaneousGesture(TapGesture(count: 2).onEnded { edit(field) })
        }
    }

    private func edit(_ field: RowField) {
        selection = [field.row]
        editingField = field
    }

    /// Typing ends when the field loses focus; Return on a selected row starts it again.
    private func listEditing<V: View>(_ list: V, proxy: ScrollViewProxy) -> some View {
        list
            .onChange(of: focusedField) { old, new in
                if new == nil, let old, editingField == old { editingField = nil }
            }
            .onChange(of: editingField) { _, field in
                if let field { withAnimation { proxy.scrollTo(field.row) } }
            }
            .onKeyPress(.return) {
                guard editingField == nil, selection.count == 1, let id = selection.first else { return .ignored }
                edit(.name(id))
                return .handled
            }
    }

    @ViewBuilder private func decoration(_ category: Category, _ index: Int) -> some View {
        switch category {
        case .lanes: Circle().fill(Self.laneColor(index)).frame(width: 11, height: 11)
        case .priorities: Image(systemName: "flag.fill").font(.caption).foregroundStyle(Self.priorityColor(index))
        default: Image(systemName: category.symbol).font(.caption).foregroundStyle(.tertiary)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isCategorized { categorized } else { singleForm }
            }
            .navigationTitle(prefill != nil ? "Set Up Board" : (isEditing ? "Board Settings" : "New Project"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Create") { Task { await save() } }
                        .disabled(trimmedName.isEmpty || model.isSaving)
                }
            }
            .onAppear(perform: seed)
        }
        .frame(minWidth: isCategorized ? 720 : 520, minHeight: 580)
    }

    // MARK: An existing board: parts on the left

    private var categorized: some View {
        HStack(spacing: 0) {
            List(Category.allCases, selection: Binding(get: { category }, set: { category = $0 ?? .general; selection = []; editingField = nil })) { item in
                HStack {
                    Label(item.rawValue, systemImage: item.symbol)
                    Spacer()
                    if item == .products {
                        Text("\(productRows.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else if item == .docs {
                        Text("\(docSources.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    } else if item != .general {
                        Text("\(entries(item).wrappedValue.count)").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .tag(item)
            }
            .listStyle(.sidebar)
            .frame(width: 180)
            Divider()
            VStack(spacing: 0) {
                if category == .general { generalForm } else if category == .docs { docsForm } else if category == .products { productsForm } else { entryList(category) }
                if let progress = model.settingsProgress {
                    HStack { ProgressView().controlSize(.small); Text(progress).foregroundStyle(.secondary); Spacer() }.padding(10)
                }
                if let error = model.errorMessage {
                    Text(error).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var generalForm: some View {
        Form {
            Section {
                field("Name", $name)
            } header: {
                Text("Board")
            } footer: {
                Text("The board's own text is its About page, under Docs.")
            }
            Section {
                BoardAppearancePicker(icon: $icon, color: $color)
            } header: {
                Text("Color and Icon")
            } footer: {
                Text("Saved in the board's README in the repository, so it is the same everywhere.")
            }
            Section {
                Button { detect() } label: {
                    HStack {
                        Label("Detect from Folders", systemImage: "wand.and.stars")
                        Spacer()
                        if detecting { ProgressView().controlSize(.small) }
                    }
                }
                .disabled(detecting)
            } footer: {
                Text("Read the board's folders and cards to fill in lanes, priorities, types, members, and epics.")
            }
        }
        .formStyle(.grouped)
    }

    /// The products this board covers. A task can name one, and the board can be filtered on it.
    private var productsForm: some View {
        VStack(spacing: 0) {
            HStack {
                Text("A board can cover several products. Tasks name the one they are for; the sidebar and the filter show one at a time. Double-click a name or prefix to change it.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if !selection.isEmpty, productRows.contains(where: { selection.contains($0.id) }) {
                    Button(role: .destructive) { removeProducts(selection) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Delete the selected products")
                        .accessibilityLabel("Delete")
                        .accessibilityIdentifier("settingsDeleteSelected")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollViewReader { proxy in
                listEditing(List(selection: $selection) {
                    ForEach($productRows) { $row in
                        HStack(spacing: 10) {
                            Image(systemName: "shippingbox").font(.caption).foregroundStyle(.tertiary).frame(width: 16)
                            editableText($row.name, hint: "Product name", field: .name(row.id))
                            editableText($row.prefix, hint: "No prefix", field: .prefix(row.id))
                                .frame(width: 130)
                                .help("With a prefix, new tasks of this product are numbered with it, such as \(BoardProduct.cleanPrefix(row.prefix) ?? "TASKS")-001. Without one they use the board's numbering. Double-click to change it.")
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Drag to order")
                        }
                        .padding(.vertical, 2)
                        .tag(row.id)
                        .id(row.id)
                        .contextMenu { productMenu(row) }
                    }
                    .onMove { productRows.move(fromOffsets: $0, toOffset: $1) }
                }, proxy: proxy)
                .onDeleteCommand { removeProducts(selection) }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Removing a product leaves its tasks as they are; they only lose their place in the list.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    let row = ProductRow(name: "", prefix: "", original: nil)
                    productRows.append(row)
                    // Straight into its name, ready to type.
                    edit(.name(row.id))
                } label: { Label("Add Product", systemImage: "plus") }
                    .accessibilityIdentifier("settingsAddProduct")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A product row's right-click menu.
    @ViewBuilder private func productMenu(_ row: ProductRow) -> some View {
        // On a row that is part of the selection the menu acts on all of it.
        let ids = selection.contains(row.id) ? selection : [row.id]
        if ids.count == 1 {
            Button("Rename", systemImage: "pencil") { edit(.name(row.id)) }
            Button("Change Prefix", systemImage: "number") { edit(.prefix(row.id)) }
            Divider()
        }
        Button(ids.count == 1 ? "Delete" : "Delete \(ids.count) Products", systemImage: "trash", role: .destructive) { removeProducts(ids) }
    }

    private func removeProducts(_ ids: Set<UUID>) {
        productRows.removeAll { ids.contains($0.id) }
        selection = []
        editingField = nil
    }

    /// The rows as products. One that existed keeps its id, so its tasks stay with it when it is renamed.
    private func builtProducts() -> [BoardProduct] {
        var used = Set(productRows.compactMap { $0.original?.id })
        return productRows.compactMap { row -> BoardProduct? in
            let name = row.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let prefix = BoardProduct.cleanPrefix(row.prefix)
            if let original = row.original {
                return BoardProduct(id: original.id, name: name, prefix: prefix, icon: original.icon, color: original.color)
            }
            var id = BoardProduct.id(for: name)
            var number = 2
            while used.contains(id) || id.isEmpty { id = "\(BoardProduct.id(for: name))-\(number)"; number += 1 }
            used.insert(id)
            return BoardProduct(id: id, name: name, prefix: prefix)
        }
    }

    /// Where the board's pages come from besides its own `docs` folder.
    private var docsForm: some View {
        Form {
            Section {
                if docSources.isEmpty {
                    Text("No linked folders. The board shows the pages in its own docs folder.").foregroundStyle(.secondary)
                }
                ForEach($docSources) { $source in
                    HStack(spacing: 10) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.repo)
                            Text(source.folder.isEmpty ? "Whole repository" : source.folder).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Editable", isOn: $source.editable)
                            .toggleStyle(.switch).controlSize(.small)
                            .help("On: pages can be changed here, and a save is a commit to \(source.repo)")
                        Button { docSources.removeAll { $0.id == source.id } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(source.repo)")
                    }
                }
            } header: {
                Text("Linked Folders")
            } footer: {
                Text("A linked folder keeps its pages in its own repository, such as the docs folder next to a project's code. They are shown here, not copied. With Editable on, a save is a commit to that repository; switch it off to only read.")
            }
            Section {
                HStack {
                    field("owner/repository/folder", $newSource).autocorrectionDisabled()
                        .onSubmit(addSource)
                        .accessibilityIdentifier("settingsDocSource")
                    Button("Link", action: addSource)
                        .disabled(newSource.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Link a Folder")
            } footer: {
                if let sourceProblem {
                    Text(sourceProblem).foregroundStyle(.red)
                } else {
                    Text("For example silvandiepen/arvik/docs. Your account must be able to read that repository.")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addSource() {
        guard let source = DocSource(written: newSource) else {
            sourceProblem = "Write it as owner/repository/folder, for example silvandiepen/arvik/docs."
            return
        }
        guard !docSources.contains(where: { $0.id == source.id }) else {
            sourceProblem = "\(source.repo) · \(source.folder) is already linked."
            return
        }
        docSources.append(source)
        newSource = ""
        sourceProblem = nil
    }

    /// One part's rows: drag to order, select one to rename it in the field above, select
    /// several to merge them into one of themselves or to delete them.
    private func entryList(_ category: Category) -> some View {
        let items = entries(category)
        let chosen = items.wrappedValue.filter { selection.contains($0.id) }
        let pending = merges.filter { $0.category == category }
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                if chosen.count < 2 {
                    Text("Drag to order. Double-click a name to rename it. Select several (⌘ or ⇧) to \(category.canMerge ? "merge or " : "")delete them.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    Text("\(chosen.count) selected").font(.callout.weight(.medium))
                    Spacer()
                    if category.canMerge {
                        // Merge into one of the selected rows: the one you pick keeps its name,
                        // the others are folded into it.
                        Menu("Merge Into") { mergeTargets(chosen, in: category) }
                        .fixedSize()
                        .help("Every task that has one of the selected \(category.rawValue.lowercased()) gets the one you pick")
                        .accessibilityIdentifier("settingsMergeInto")
                    }
                }
                if !chosen.isEmpty {
                    Button(role: .destructive) {
                        remove(selection, from: category)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete the selected \(chosen.count == 1 ? category.singular.lowercased() : category.rawValue.lowercased())")
                    .accessibilityLabel("Delete")
                    .accessibilityIdentifier("settingsDeleteSelected")
                }
            }
            .padding(.horizontal, 14).frame(height: 40)
            Divider()
            ScrollViewReader { proxy in
                listEditing(List(selection: $selection) {
                    ForEach(items) { $item in
                        let index = items.wrappedValue.firstIndex { $0.id == item.id } ?? 0
                        HStack(spacing: 10) {
                            decoration(category, index).frame(width: 16)
                            editableText($item.text, hint: category.hint, field: .name(item.id))
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                .help("Drag to order")
                        }
                        .padding(.vertical, 2)
                        .tag(item.id)
                        .id(item.id)
                        .contextMenu { entryMenu(item, in: category) }
                    }
                    .onMove { items.wrappedValue.move(fromOffsets: $0, toOffset: $1) }
                }, proxy: proxy)
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .onDeleteCommand { remove(selection, from: category) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                ForEach(pending) { merge in
                    HStack {
                        Image(systemName: "arrow.triangle.merge").foregroundStyle(.secondary)
                        Text("\(merge.from.text) → \(items.wrappedValue.first { $0.id == merge.into }?.text ?? "")")
                        Spacer()
                        Button("Undo") { undo(merge) }
                    }
                }
                if !pending.isEmpty {
                    Text("When you save, every task that has a merged \(category.singular.lowercased()) is changed to the one it was merged into, in one commit.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    let entry = Entry(text: category == .priorities ? "P\(priorities.count)" : "")
                    items.wrappedValue.append(entry)
                    // Straight into its name, ready to type.
                    edit(.name(entry.id))
                } label: { Label("Add \(category.singular)", systemImage: "plus") }
                .accessibilityIdentifier("settingsAdd")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A row's right-click menu. On a row that is part of the selection it acts on all of it.
    @ViewBuilder private func entryMenu(_ item: Entry, in category: Category) -> some View {
        let ids = selection.contains(item.id) ? selection : [item.id]
        let chosen = entries(category).wrappedValue.filter { ids.contains($0.id) }
        if chosen.count == 1 {
            Button("Rename", systemImage: "pencil") { edit(.name(item.id)) }
        } else if category.canMerge {
            Menu("Merge Into") { mergeTargets(chosen, in: category) }
        }
        Divider()
        Button(chosen.count == 1 ? "Delete" : "Delete \(chosen.count) \(category.rawValue)", systemImage: "trash", role: .destructive) {
            remove(ids, from: category)
        }
    }

    /// Merge into one of the chosen rows: the one you pick keeps its name, the others are
    /// folded into it.
    @ViewBuilder private func mergeTargets(_ chosen: [Entry], in category: Category) -> some View {
        ForEach(chosen.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }) { target in
            Button(target.text) { merge(chosen.filter { $0.id != target.id }, into: target, in: category) }
        }
    }

    private func remove(_ ids: Set<UUID>, from category: Category) {
        guard !ids.isEmpty else { return }
        entries(category).wrappedValue.removeAll { ids.contains($0.id) }
        // What was merged into a row that is now gone has nowhere to go.
        merges.removeAll { $0.category == category && ids.contains($0.into) }
        selection = []
    }

    private func merge(_ chosen: [Entry], into target: Entry, in category: Category) {
        for entry in chosen {
            // Whatever was merged into this row earlier follows it to the new one.
            for index in merges.indices where merges[index].into == entry.id { merges[index].into = target.id }
            if !entry.text.trimmingCharacters(in: .whitespaces).isEmpty {
                merges.append(PendingMerge(category: category, from: entry, into: target.id))
            }
        }
        let ids = Set(chosen.map(\.id))
        entries(category).wrappedValue.removeAll { ids.contains($0.id) }
        selection = [target.id]
    }

    private func undo(_ merge: PendingMerge) {
        entries(merge.category).wrappedValue.append(merge.from)
        merges.removeAll { $0.id == merge.id }
    }

    // MARK: A new board, or the set-up of a detected one: one form

    private var singleForm: some View {
        Form {
            Section("Project") {
                field("Name", $name)
                TextField("Description (optional)", text: $description, prompt: Text("Description (optional)"), axis: .vertical)
                    .labelsHidden().lineLimit(1...4)
            }
            ForEach(Category.allCases.filter(\.isList)) { category in
                let items = entries(category)
                Section(category.rawValue) {
                    ForEach(items) { $item in
                        let index = items.wrappedValue.firstIndex { $0.id == item.id } ?? 0
                        HStack(spacing: 10) {
                            decoration(category, index).frame(width: 16)
                            field(category.hint, $item.text).autocorrectionDisabled()
                            Button { items.wrappedValue.removeAll { $0.id == item.id } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove")
                        }
                    }
                    .onMove { items.wrappedValue.move(fromOffsets: $0, toOffset: $1) }
                    Button { items.wrappedValue.append(Entry(text: category == .priorities ? "P\(priorities.count)" : "")) } label: {
                        Label("Add \(category.singular)", systemImage: "plus")
                    }
                }
            }
            if let error = model.errorMessage {
                Section { Text(error).font(.callout).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Loading and saving

    private func seed() {
        guard !seeded else { return }
        seeded = true
        // `GITKANBAN_SETTINGS_TAB=Members` — open on that part, for screenshots.
        if let wanted = ProcessInfo.processInfo.environment["GITKANBAN_SETTINGS_TAB"], let tab = Category(rawValue: wanted) { category = tab }
        guard let editing else { return }
        icon = editing.config.icon
        color = editing.config.color
        if let prefill {
            name = model.board?.config.project ?? editing.name
            lanes = prefill.lanes.map { Entry(text: $0.name, lane: $0) }
            priorities = prefill.priorities.map { Entry(text: $0.id) }
            members = prefill.users.map { Entry(text: $0.id) }
            types = prefill.types.map { Entry(text: $0) }
            epics = prefill.epics.map { Entry(text: $0.name ?? $0.id, epic: $0) }
            return
        }
        docSources = model.docSources
        productRows = model.products.map { ProductRow(name: $0.name, prefix: $0.prefix ?? "", original: $0) }
        guard let config = model.board?.config else { return }
        name = config.project ?? editing.name
        lanes = config.lanes.map { Entry(text: $0.name, lane: $0) }
        priorities = config.priorities.map { Entry(text: $0.id) }
        members = config.users.map { Entry(text: $0.id) }
        types = config.types.map { Entry(text: $0) }
        epics = config.epics.map { Entry(text: $0.name ?? $0.id, epic: $0) }
        if ProcessInfo.processInfo.environment["GITKANBAN_SETTINGS_SELECT"] != nil { selection = Set(members.prefix(2).map(\.id)) }
    }

    private func detect() {
        guard let editing, !detecting else { return }
        detecting = true
        Task {
            let d = await model.detectConfig(for: editing)
            applyDetected(d)
            detecting = false
        }
    }

    private func applyDetected(_ d: DetectedBoardConfig) {
        func has(_ list: [Entry], _ text: String) -> Bool { list.contains { $0.text.caseInsensitiveCompare(text) == .orderedSame } }
        if !d.lanes.isEmpty { lanes = d.lanes.map { Entry(text: $0.name, lane: $0) } }
        for p in d.priorities where !has(priorities, p.id) { priorities.append(Entry(text: p.id)) }
        for u in d.users where !has(members, u.id) { members.append(Entry(text: u.id)) }
        for t in d.types where !has(types, t) { types.append(Entry(text: t)) }
        for e in d.epics {
            let label = e.name ?? e.id
            if !epics.contains(where: { $0.epic?.id == e.id }) && !has(epics, label) { epics.append(Entry(text: label, epic: e)) }
        }
    }

    private func texts(_ list: [Entry]) -> [String] {
        list.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func save() async {
        let builtLanes = buildLanes()
        let builtEpics = buildEpics()
        if let editing {
            await model.saveProjectSettings(
                project: editing, name: trimmedName, description: description,
                lanes: builtLanes, priorities: texts(priorities).map { Priority(id: $0) }, users: texts(members).map { User(id: $0) },
                types: texts(types), epics: builtEpics.map(\.epic),
                appearance: isCategorized ? (icon, color) : nil,
                merges: fieldMerges(epicIDs: Dictionary(uniqueKeysWithValues: builtEpics.map { ($0.row, $0.epic.id) })))
        } else {
            await model.createProject(name: trimmedName, description: description, lanes: builtLanes,
                                      priorities: texts(priorities).map { Priority(id: $0) }, users: texts(members).map { User(id: $0) },
                                      epics: builtEpics.map(\.epic))
        }
        // The linked folders are their own lines in the README, written after the rest.
        if model.errorMessage == nil, isCategorized, docSources != model.docSources { await model.saveDocSources(docSources) }
        if model.errorMessage == nil, isCategorized, builtProducts() != model.products { await model.saveProducts(builtProducts()) }
        if model.errorMessage == nil { dismiss() }
    }

    /// The merges as changes to make on the tasks.
    private func fieldMerges(epicIDs: [UUID: String]) -> [FieldMerge] {
        merges.compactMap { merge -> FieldMerge? in
            let from = merge.from.text.trimmingCharacters(in: .whitespaces)
            let target = entries(merge.category).wrappedValue.first { $0.id == merge.into }?.text.trimmingCharacters(in: .whitespaces) ?? ""
            switch merge.category {
            case .members: return target.isEmpty ? nil : .member(from: from, into: target)
            case .types: return target.isEmpty ? nil : FieldMerge(fields: ["type"], from: from, into: target)
            case .priorities: return target.isEmpty ? nil : FieldMerge(fields: ["priority"], from: from, into: target)
            case .epics:
                // Tasks hold an epic's id. An epic added in this window is on no task yet.
                guard let old = merge.from.epic?.id, let new = epicIDs[merge.into] else { return nil }
                return FieldMerge(fields: ["epic"], from: old, into: new)
            case .lanes, .general, .docs, .products: return nil
            }
        }
    }

    private func slug(_ text: String, used: inout Set<String>) -> String {
        let base = text.lowercased().replacingOccurrences(of: " ", with: "-")
        var slug = base
        var k = 2
        while used.contains(slug) { slug = "\(base)-\(k)"; k += 1 }
        used.insert(slug)
        return slug
    }

    private func buildLanes() -> [Lane] {
        var used = Set(lanes.compactMap { $0.lane?.id })
        var result: [Lane] = []
        for (index, item) in lanes.enumerated() {
            let n = item.text.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { continue }
            if let origin = item.lane {
                result.append(Lane(id: origin.id, name: n, folder: origin.folder, status: origin.status,
                                   terminal: origin.terminal, backlog: origin.backlog))
            } else {
                let id = slug(n, used: &used)
                result.append(Lane(id: id, name: n, folder: "\(index + 1). \(n)", status: id))
            }
        }
        return result
    }

    private func buildEpics() -> [(row: UUID, epic: Epic)] {
        var used = Set(epics.compactMap { $0.epic?.id })
        return epics.compactMap { item in
            let n = item.text.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return nil }
            if let origin = item.epic { return (item.id, Epic(id: origin.id, name: n)) }
            return (item.id, Epic(id: slug(n, used: &used), name: n))
        }
    }
}
