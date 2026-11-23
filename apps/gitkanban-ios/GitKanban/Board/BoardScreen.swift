import GitKittieKit
import GitKanbanKit
import SwiftUI
import UIKit

/// The board for the active project, in either **lanes** (horizontal kanban) or
/// **list** mode. Backlog lanes are ordered last. Tap a card for its detail (rendered
/// description + edit), use a lane's ﹢ to add, and the toolbar to switch view, filter,
/// or search. Edits commit over the provider API (git-pont) and reload.
struct BoardScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showNewProject = false
    @State private var showLiveUpdates = false
    @State private var settingsProject: BoardProject?
    @State private var setupProject: BoardProject?
    @State private var setupConfig: DetectedBoardConfig?
    @State private var offeredSetup: Set<String> = []
    @State private var showReviews = false

    private var projects: [BoardProject] { model.workspace?.projects ?? [] }

    var body: some View {
        @Bindable var model = model
        return Group {
            if model.isLoadingBoard && model.board == nil {
                ProgressView("Loading board…")
            } else if let board = model.board {
                VStack(spacing: 0) {
                    modeBar
                    switch model.boardViewMode {
                    // The calendar is a Mac view; on iPhone it shows as the board.
                    case .lanes, .calendar: LanesView(columns: displayColumns(board))
                    case .list: ListBoardView(columns: displayColumns(board))
                    }
                }
                .background(Theme.window)
            } else {
                ContentUnavailableView("No board", systemImage: "square.stack.3d.up",
                                       description: Text("This repo has no project boards."))
            }
        }
        .navigationTitle(model.selectedProject?.name ?? model.activeRepo?.name ?? "Board")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .overlay(alignment: .top) { savingBanner }
        .toolbar { toolbarContent }
        .sheet(item: $model.selectedCard) { card in CardDetailSheet(card: card).environment(model) }
        .sheet(item: $model.newTaskLane) { lane in NewTaskSheet(lane: lane).environment(model) }
        .sheet(isPresented: $model.isShowingSearch) { SearchSheet().environment(model) }
        .sheet(isPresented: $showReviews) { NavigationStack { ReviewListView() }.environment(model) }
        .sheet(isPresented: $model.showQuickCreate) { QuickCreateSheet().environment(model) }
        // Moving a card that carries this project's id prefix: keep the id, or take the
        // next one in the project it is going to.
        .confirmationDialog(
            model.pendingProjectMove.map { "Move “\($0.cardTitle)” to \($0.target.name)" } ?? "",
            isPresented: Binding(get: { model.pendingProjectMove != nil }, set: { if !$0 { model.pendingProjectMove = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingProjectMove
        ) { plan in
            if let newID = plan.suggestedID {
                Button("Renumber to \(newID)") { Task { await model.finishMove(plan, renumber: true) } }
            }
            Button("Keep \(plan.cardID)") { Task { await model.finishMove(plan, renumber: false) } }
            Button("Cancel", role: .cancel) { model.pendingProjectMove = nil }
        } message: { plan in
            Text("It lands in \(plan.lane.name). Renumbering changes the id other tasks and review requests may refer to.")
        }
        .sheet(isPresented: $showNewProject) { ProjectSheet(editing: nil).environment(model) }
        .sheet(isPresented: $showLiveUpdates) { LiveUpdatesSheet().environment(model) }
        .sheet(item: $settingsProject) { project in ProjectSheet(editing: project).environment(model) }
        .sheet(item: $setupProject) { project in ProjectSheet(editing: project, prefill: setupConfig).environment(model) }
        .task(id: model.selectedProject?.id) { await maybeOfferSetup() }
    }

    @ViewBuilder private var savingBanner: some View {
        if model.isSaving {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Saving…").font(.caption) }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
        }
    }

    /// Under the title: the board as lanes or as a list, and the filters.
    private var modeBar: some View {
        HStack(spacing: 0) {
            modeButton("rectangle.split.3x1", "Board", isOn: model.boardViewMode != .list) { model.boardViewMode = .lanes }
            modeButton("list.bullet", "List", isOn: model.boardViewMode == .list) { model.boardViewMode = .list }
                .accessibilityIdentifier("viewModeButton")
            Divider().frame(height: 20).padding(.horizontal, 4)
            filterMenu.frame(width: 76, height: 36)
        }
        .padding(4)
        .background(Theme.panel, in: Capsule())
        .padding(.top, 6).padding(.bottom, 8)
    }

    private func modeButton(_ symbol: String, _ name: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy(duration: 0.2)) { action() } } label: {
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(isOn ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 76, height: 36)
                .background(isOn ? Theme.card : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { model.closeRepo() } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel("Boards")
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 7) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                Text(model.selectedProject?.name ?? model.activeRepo?.name ?? "Board").font(.headline).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !model.reviews.isEmpty {
                Button { showReviews = true } label: {
                    Image(systemName: model.pendingReviewCount > 0 ? "checkmark.seal.fill" : "checkmark.seal")
                        .overlay(alignment: .topTrailing) {
                            // A dot, not the number: a count like 211 does not fit on an icon.
                            // The number is on the Reviews screen and on the home row.
                            if model.pendingReviewCount > 0 {
                                Circle().fill(Color.orange).frame(width: 8, height: 8).offset(x: 3, y: -2)
                            }
                        }
                }
                .accessibilityLabel(model.pendingReviewCount > 0 ? "Reviews, \(model.pendingReviewCount) waiting" : "Reviews")
                .accessibilityIdentifier("reviewsButton")
                .help("Reviews")
            }
            if let lane = firstLane {
                Button { model.newTaskLane = lane } label: { Image(systemName: "plus") }
                    .help("New task")
                    .accessibilityLabel("New task")
                    .accessibilityIdentifier("newTaskButton")
            }
            overflowMenu
        }
    }

    /// If a board opens unconfigured (cards but no matching lanes), detect a config and
    /// present the setup sheet prefilled — once per board.
    private func maybeOfferSetup() async {
        guard model.boardNeedsSetup, let project = model.selectedProject,
              !offeredSetup.contains(project.id) else { return }
        offeredSetup.insert(project.id)
        setupConfig = await model.detectConfig(for: project)
        setupProject = project
    }

    /// The first real (non-backlog) lane — the default target for the header + button.
    private var firstLane: Lane? {
        model.board?.config.lanes.first { !$0.folder.isEmpty && !$0.isBacklog }
            ?? model.board?.config.lanes.first { !$0.folder.isEmpty }
    }

    /// Less-frequent actions folded into one menu so the bar doesn't overflow.
    private var overflowMenu: some View {
        @Bindable var model = model
        return Menu {
            Button("Search…", systemImage: "magnifyingglass") { model.isShowingSearch = true }
            Button("Quick Create with AI…", systemImage: "sparkles") { model.showQuickCreate = true }
            Divider()
            Picker("Sort", selection: $model.cardSort) {
                ForEach(CardSort.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            if model.unseenCount > 0 {
                Button("Mark \(model.unseenCount) Updated as Seen", systemImage: "eye") { model.markAllSeen() }
            }
            Divider()
            if !model.isDemo {
                Button("Live Updates…", systemImage: "dot.radiowaves.left.and.right") { showLiveUpdates = true }
            }
            Button("New Project…", systemImage: "plus") { showNewProject = true }
            if let project = model.selectedProject {
                Button("Project Settings…", systemImage: "gearshape") { settingsProject = project }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
    }

    private var filterMenu: some View {
        @Bindable var model = model
        return Menu {
            if projects.count > 1 {
                Picker("Project", selection: Binding(
                    get: { model.selectedProject?.id ?? "" },
                    set: { id in if let p = projects.first(where: { $0.id == id }) { Task { await model.selectProject(p) } } }
                )) { ForEach(projects) { Text($0.name).tag($0.id) } }
            }
            Menu("Assignee") {
                Button("Anyone") { model.filterAssignee = nil }
                ForEach(assignees, id: \.self) { a in
                    Button { model.filterAssignee = a } label: { filterLabel(a, model.filterAssignee == a) }
                }
            }
            if !priorities.isEmpty {
                Menu("Priority") {
                    Button("Any") { model.filterPriority = nil }
                    ForEach(priorities, id: \.id) { p in
                        Button { model.filterPriority = p.id } label: { filterLabel(p.name ?? p.id, model.filterPriority == p.id) }
                    }
                }
            }
            if !types.isEmpty {
                Menu("Type") {
                    Button("Any") { model.filterType = nil }
                    ForEach(types, id: \.self) { t in
                        Button { model.filterType = t } label: { filterLabel(t, model.filterType == t) }
                    }
                }
            }
            if model.hasActiveFilters {
                Divider()
                Button("Clear Filters", role: .destructive) { model.clearFilters() }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.body.weight(.medium))
                .foregroundStyle(model.hasActiveFilters ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(model.hasActiveFilters ? "Filters, on" : "Filters")
    }

    @ViewBuilder private func filterLabel(_ text: String, _ selected: Bool) -> some View {
        if selected { Label(text, systemImage: "checkmark") } else { Text(text) }
    }

    // MARK: Data

    private var config: EffectiveConfig? { model.board?.config }
    private var assignees: [String] {
        let fromConfig = config?.users.map(\.id) ?? []
        let fromCards = model.allCards.compactMap(\.fields.assignee)
        return Array(Set(fromConfig + fromCards)).sorted()
    }
    private var priorities: [Priority] { config?.priorities ?? [] }
    private var types: [String] {
        let fromConfig = config?.types ?? []
        let fromCards = model.allCards.compactMap(\.fields.type)
        return Array(Set(fromConfig + fromCards)).sorted()
    }

    /// Filtered columns ordered pipeline-lanes → backlog lanes → uncategorised.
    private func displayColumns(_ board: LoadedBoard) -> [Column] {
        let filtered = board.columns.map { Column(lane: $0.lane, cards: $0.cards.filter(model.matchesFilters)) }
        var cols = filtered.filter { !$0.lane.isBacklog } + filtered.filter { $0.lane.isBacklog }
        let uncategorised = board.uncategorised.filter(model.matchesFilters)
        if !uncategorised.isEmpty {
            cols.append(Column(
                lane: Lane(id: "_uncategorised", name: "Uncategorised", folder: "", status: ""),
                cards: uncategorised
            ))
        }
        return cols
    }
}

// MARK: - Lanes (one under the other)

/// The board on a phone: each lane a section that folds, its tasks as cards, and a way
/// to add one at the end. A card dragged onto another lane moves there.
private struct LanesView: View {
    @Environment(AppModel.self) private var model
    let columns: [Column]
    /// Lanes folded shut, by id. Done and the backlog start folded: they are the long ones.
    @State private var folded: Set<String>?

    private func isFolded(_ lane: Lane) -> Bool {
        (folded ?? Set(columns.map(\.lane).filter { $0.terminal == true || $0.isBacklog }.map(\.id))).contains(lane.id)
    }

    private func toggle(_ lane: Lane) {
        var now = folded ?? Set(columns.map(\.lane).filter { $0.terminal == true || $0.isBacklog }.map(\.id))
        if now.contains(lane.id) { now.remove(lane.id) } else { now.insert(lane.id) }
        withAnimation(.snappy(duration: 0.25)) { folded = now }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(columns) { column in
                    LaneSection(column: column, isFolded: isFolded(column.lane)) { toggle(column.lane) }
                }
            }
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 32)
        }
        .refreshable { if let project = model.selectedProject { await model.selectProject(project) } }
    }
}

private struct LaneSection: View {
    @Environment(AppModel.self) private var model
    let column: Column
    let isFolded: Bool
    let toggle: () -> Void
    @State private var isTargeted = false

    private var color: Color { laneColor(column.lane, model.board?.config ?? EffectiveConfig()) }
    private var isLane: Bool { !column.lane.folder.isEmpty }
    private var needsLoading: Bool { column.lane.isBacklog && !model.loadedBacklogLanes.contains(column.lane.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 10) {
                    Circle().fill(color).frame(width: 13, height: 13)
                    Text(column.lane.name).font(.headline)
                    Text("\(column.cards.count)").font(.body).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    Image(systemName: "chevron.down").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isFolded ? -90 : 0))
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(column.lane.name), \(column.cards.count) tasks, \(isFolded ? "folded" : "open")")

            if !isFolded {
                if needsLoading {
                    Button {
                        Task { await model.loadBacklogLane(column.lane) }
                    } label: {
                        if model.loadingBacklogLane == column.lane.id {
                            ProgressView().frame(maxWidth: .infinity)
                        } else {
                            Label("Load \(column.lane.name)", systemImage: "tray.and.arrow.down").font(.callout).frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                } else {
                    ForEach(model.sorted(column.cards)) { card in
                        LaneCardCell(card: card, done: column.lane.terminal == true)
                    }
                    if isLane {
                        Button { model.newTaskLane = column.lane } label: {
                            Label("Add task", systemImage: "plus")
                                .font(.callout).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(isTargeted ? 8 : 0)
        .background(isTargeted ? color.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 14))
        .animation(.snappy(duration: 0.2), value: isTargeted)
        .dropDestination(for: String.self) { ids, _ in handleDrop(ids) } isTargeted: { isTargeted = $0 && isLane }
    }

    /// Move dropped cards (by id) into this lane.
    private func handleDrop(_ ids: [String]) -> Bool {
        guard isLane else { return false }
        var moved = false
        for id in ids {
            if let card = model.allCards.first(where: { $0.fields.id == id }),
               card.fields.status != column.lane.status {
                Task { await model.moveCard(card, to: column.lane) }
                moved = true
            }
        }
        return moved
    }
}

private struct LaneCardCell: View {
    @Environment(AppModel.self) private var model
    let card: Card
    var done = false
    private var priorities: [Priority] { model.board?.config.priorities ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                if model.isUnseen(card) {
                    Circle().fill(Color.blue).frame(width: 8, height: 8).padding(.top, 6)
                        .accessibilityLabel("Updated since you last looked")
                }
                Text(card.fields.title.isEmpty ? card.fields.id : card.fields.title)
                    .font(.body.weight(model.isUnseen(card) ? .semibold : .medium))
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                Menu { cardMenu(card, model: model) } label: {
                    Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.tertiary)
                        .frame(width: 32, height: 24).contentShape(Rectangle())
                }
                .accessibilityLabel("Task menu")
            }
            TaskMetaLine(card: card, priorities: priorities, done: done)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { model.selectedCard = card }
        .draggable(card.fields.id) {
            // Drag preview: a compact chip of the card title.
            Text(card.fields.title.isEmpty ? card.fields.id : card.fields.title)
                .font(.callout).lineLimit(1).padding(10)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        }
        .contextMenu { cardMenu(card, model: model) }
    }
}

// MARK: - List

/// The board as three stages — Working on, Up next, Checked off — so agent work can be
/// followed at a glance. Checked-off cards carry a read mark (`read_at`); unread ones come
/// first. Lane-by-lane management stays in the Lanes view.
private struct ListBoardView: View {
    @Environment(AppModel.self) private var model
    let columns: [Column]

    private var groups: [ProgressGroup] {
        let groups = BoardProgress.groups(columns, lanes: model.board?.config.lanes)
        guard model.cardSort != .board else { return groups }
        return groups.map { group in
            let order = model.sorted(group.entries.map(\.card)).map(\.id)
            var sorted = group
            sorted.entries = order.compactMap { id in group.entries.first { $0.id == id } }
            return sorted
        }
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section {
                    if group.entries.isEmpty {
                        Text(emptyText(group.stage)).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(group.entries) { entry in
                        Button { model.selectedCard = entry.card } label: {
                            ProgressRow(entry: entry, stage: group.stage,
                                        hasAttachments: model.attachmentCardIDs.contains(entry.card.fields.id))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { cardMenu(entry.card, model: model) }
                        .swipeActions(edge: .leading) {
                            if group.stage == .checkedOff {
                                if BoardProgress.isUnread(entry.card.fields) {
                                    Button { Task { await model.markRead([entry.card]) } } label: {
                                        Label("Read", systemImage: "checkmark.circle")
                                    }
                                    .tint(.blue)
                                } else {
                                    Button { Task { await model.markUnread(entry.card) } } label: {
                                        Label("Unread", systemImage: "circle.fill")
                                    }
                                    .tint(.gray)
                                }
                            }
                        }
                    }
                    if group.stage == .pipeline { backlogLoaders }
                } header: {
                    header(group)
                }
                .listRowBackground(Theme.panel)
            }
        }
        .listStyle(.insetGrouped)
        .themedList()
        .refreshable {
            if let project = model.selectedProject { await model.selectProject(project) }
            await model.loadAttachmentIndex()
        }
        .task(id: model.selectedProject?.id) { await model.loadAttachmentIndex() }
    }

    @ViewBuilder private var backlogLoaders: some View {
        ForEach(columns.filter { $0.lane.isBacklog && !model.loadedBacklogLanes.contains($0.lane.id) }) { column in
            Button {
                Task { await model.loadBacklogLane(column.lane) }
            } label: {
                Label(model.loadingBacklogLane == column.lane.id ? "Loading…" : "Load \(column.lane.name)",
                      systemImage: "tray.and.arrow.down")
            }
        }
    }

    private func header(_ group: ProgressGroup) -> some View {
        let unread = group.stage == .checkedOff
            ? group.entries.filter { BoardProgress.isUnread($0.card.fields) } : []
        return HStack(spacing: 7) {
            Image(systemName: icon(group.stage)).foregroundStyle(tint(group.stage))
            Text(group.stage.title)
            Text("\(group.entries.count)").foregroundStyle(.secondary)
            if !unread.isEmpty {
                Text("\(unread.count) unread").foregroundStyle(.blue)
            }
            Spacer()
            if !unread.isEmpty {
                Button("Mark All Read") { Task { await model.markRead(unread.map(\.card)) } }
                    .font(.caption)
                    .textCase(nil)
                    .accessibilityIdentifier("markAllRead")
            }
        }
    }

    private func emptyText(_ stage: ProgressStage) -> String {
        switch stage {
        case .working: "Nothing in progress."
        case .pipeline: "Nothing queued."
        case .checkedOff: "Nothing finished yet."
        }
    }

    private func icon(_ stage: ProgressStage) -> String {
        switch stage {
        case .working: "hammer"
        case .pipeline: "tray.full"
        case .checkedOff: "checkmark.circle"
        }
    }

    private func tint(_ stage: ProgressStage) -> Color {
        switch stage {
        case .working: .orange
        case .pipeline: .secondary
        case .checkedOff: .green
        }
    }
}

/// One card in the progress list: title, lane, who, when, and what happened last.
private struct ProgressRow: View {
    @Environment(AppModel.self) private var model
    let entry: ProgressEntry
    let stage: ProgressStage
    let hasAttachments: Bool

    private var fields: CardFields { entry.card.fields }
    /// Needs a look: an unread checked-off card, or any card updated since it was last opened.
    private var unread: Bool { (stage == .checkedOff && BoardProgress.isUnread(fields)) || model.isUnseen(entry.card) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(unread ? Color.blue : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityLabel(unread ? "Unread" : "")
            VStack(alignment: .leading, spacing: 3) {
                Text(fields.title.isEmpty ? fields.id : fields.title)
                    .font(.body.weight(unread ? .semibold : .regular))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(entry.lane.name)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(laneColor(entry.lane, model.board?.config ?? EffectiveConfig()).opacity(0.16), in: Capsule())
                        .foregroundStyle(laneColor(entry.lane, model.board?.config ?? EffectiveConfig()))
                    if !fields.id.isEmpty {
                        Text(fields.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    if let assignee = fields.assignee {
                        Text("@\(assignee)").font(.caption2).foregroundStyle(.secondary)
                    }
                    if hasAttachments {
                        Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                            .accessibilityLabel("Has attachments")
                    }
                    Spacer(minLength: 0)
                    if let updated = fields.updatedAt {
                        Text(ReviewFormat.relative(updated)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if stage != .pipeline, let activity = BoardProgress.latestActivity(entry.card.body) {
                    Text(Self.inlineMarkdown(Self.stripTimestamp(activity)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// Activity lines use inline markdown (`claude`, **bold**); show it rendered.
    static func inlineMarkdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    /// Drop the leading "2026-11-08T20:15:00Z — " the age is already shown on the row.
    static func stripTimestamp(_ line: String) -> String {
        guard let range = line.range(of: " — ") ?? line.range(of: " - "),
              BoardProgress.date(String(line[..<range.lowerBound]).trimmingCharacters(in: CharacterSet(charactersIn: "`"))) != nil
        else { return line }
        return String(line[range.upperBound...])
    }
}

struct CardRow: View {
    let card: Card
    let priorities: [Priority]

    var body: some View {
        HStack(spacing: 10) {
            if let priority = card.fields.priority,
               let color = PriorityPalette.color(priority, priorities) {
                Text(priority)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(color.opacity(0.16), in: Capsule())
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(card.fields.title.isEmpty ? card.fields.id : card.fields.title)
                    .font(.body).lineLimit(2)
                if !card.fields.id.isEmpty {
                    Text(card.fields.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let assignee = card.fields.assignee {
                Text("@\(assignee)").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

// MARK: - Shared card context menu

@MainActor @ViewBuilder
func cardMenu(_ card: Card, model: AppModel) -> some View {
    let config = model.board?.config ?? EffectiveConfig()

    Button("Open", systemImage: "arrow.up.forward.square") { model.selectedCard = card }
    Divider()

    if !config.lanes.isEmpty {
        Menu("Move to", systemImage: "arrow.left.arrow.right") {
            ForEach(config.lanes, id: \.id) { lane in
                menuCheck(lane.name, card.fields.status == lane.status) {
                    Task { await model.moveCard(card, to: lane) }
                }
            }
        }
    }
    if !model.otherProjects.isEmpty {
        Menu("Move to Project", systemImage: "arrowshape.turn.up.right") {
            ForEach(model.otherProjects) { board in
                Button(board.name) { Task { await model.startMove(card, to: board) } }
            }
        }
    }
    if !config.priorities.isEmpty {
        Menu("Priority", systemImage: "flag") {
            menuCheck("None", card.fields.priority == nil) { Task { await model.setCardField(card, ["priority": nil]) } }
            ForEach(config.priorities, id: \.id) { p in
                menuCheck(p.name ?? p.id, card.fields.priority == p.id) { Task { await model.setCardField(card, ["priority": p.id]) } }
            }
        }
    }
    if !config.users.isEmpty {
        Menu("Assignee", systemImage: "person.crop.circle") {
            menuCheck("Unassigned", card.fields.assignee == nil) { Task { await model.setCardField(card, ["assignee": nil]) } }
            ForEach(config.users, id: \.id) { u in
                menuCheck(u.name ?? u.id, card.fields.assignee == u.id) { Task { await model.setCardField(card, ["assignee": u.id]) } }
            }
        }
    }
    if !config.types.isEmpty {
        Menu("Type", systemImage: "tag") {
            menuCheck("None", card.fields.type == nil) { Task { await model.setCardField(card, ["type": nil]) } }
            ForEach(config.types, id: \.self) { t in
                menuCheck(t, card.fields.type == t) { Task { await model.setCardField(card, ["type": t]) } }
            }
        }
    }
    if !config.epics.isEmpty {
        Menu("Epic", systemImage: "square.stack.3d.up") {
            menuCheck("None", card.fields.epic == nil) { Task { await model.setCardField(card, ["epic": nil]) } }
            ForEach(config.epics, id: \.id) { e in
                menuCheck(e.name ?? e.id, card.fields.epic == e.id) { Task { await model.setCardField(card, ["epic": e.id]) } }
            }
        }
    }

    Divider()
    Button("Duplicate", systemImage: "plus.square.on.square") { Task { await model.duplicateCard(card) } }
    if let url = model.githubURL(for: card) {
        Button("Copy Link", systemImage: "link") { UIPasteboard.general.url = url }
        Button("Open on GitHub", systemImage: "safari") { UIApplication.shared.open(url) }
    }
    Button("Copy ID", systemImage: "number") { UIPasteboard.general.string = card.fields.id }

    Divider()
    Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.deleteCard(card) } }
}

@ViewBuilder
private func menuCheck(_ text: String, _ selected: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        if selected { Label(text, systemImage: "checkmark") } else { Text(text) }
    }
}

// MARK: - Colours (local to iOS)

func laneColor(_ lane: Lane, _ config: EffectiveConfig) -> Color {
    if lane.isBacklog { return Color(red: 0.45, green: 0.50, blue: 0.58) }
    if lane.folder.isEmpty { return .gray }
    let palette: [Color] = [
        Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.23, green: 0.51, blue: 0.96),
        Color(red: 0.96, green: 0.62, blue: 0.09), Color(red: 0.91, green: 0.70, blue: 0.05),
        Color(red: 0.13, green: 0.77, blue: 0.37), Color(red: 0.09, green: 0.64, blue: 0.72),
    ]
    let index = config.lanes.firstIndex { $0.id == lane.id } ?? 0
    return palette[index % palette.count]
}

enum PriorityPalette {
    private static let ramp: [Color] = [
        Color(red: 0.90, green: 0.26, blue: 0.21), Color(red: 0.96, green: 0.55, blue: 0.09),
        Color(red: 0.23, green: 0.51, blue: 0.96), Color(red: 0.45, green: 0.50, blue: 0.58),
    ]
    static func color(_ id: String, _ priorities: [Priority]) -> Color? {
        guard let rank = priorities.firstIndex(where: { $0.id == id }) else { return .gray }
        return ramp[min(rank, ramp.count - 1)]
    }
}
