import AppKit
import GitKanbanKit
import GitKittieKit
import SwiftUI
import UniformTypeIdentifiers

/// The board for the active project, in **lanes** (horizontal kanban) or **list** mode.
/// Backlog lanes are ordered last. Click a card for its detail; drag between lanes to
/// move. Edits commit over the provider API (git-pont) and reload.
struct BoardScreen: View {
    @Environment(AppModel.self) private var model
    @State private var showNewProject = false
    @State private var betterFolder: String?
    @State private var showLiveUpdates = false
    @State private var settingsProject: BoardProject?
    @State private var setupProject: BoardProject?
    @State private var setupConfig: DetectedBoardConfig?
    @State private var offeredSetup: Set<String> = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    private var projects: [BoardProject] { model.workspace?.projects ?? [] }

    var body: some View {
        @Bindable var model = model
        return boardContent
        .background(Theme.window)
        .inspector(isPresented: Binding(
            get: { model.selectedCard != nil },
            set: { if !$0 { model.selectedCard = nil } }
        )) {
            if let card = model.selectedCard {
                CardDetailInspector(card: card)
                    .environment(model)
                    .background(Theme.panel.ignoresSafeArea())
                    .inspectorColumnWidth(min: 340, ideal: 400, max: 500)
            }
        }
        // The window's title is the app's name in the sidebar; the board names itself in its header.
        .navigationTitle("")
        .overlay(alignment: .top) { savingBanner }
        .toolbar { toolbarContent }
        // Typing in the toolbar's field narrows the board to the tasks that match.
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search tasks…  ⌘K")
        .background {
            // ⌘K puts the cursor in that field; Find (⌘F) asks for the same.
            Button("Search Tasks") { focusSearchField() }.keyboardShortcut("k").hidden()
        }
        .onChange(of: model.isShowingSearch) { _, wanted in
            if wanted { model.isShowingSearch = false; focusSearchField() }
        }
        .sheet(item: $model.newTaskLane) { lane in NewTaskSheet(lane: lane).environment(model) }
        .sheet(isPresented: $model.showQuickCreate) { QuickCreateSheet().environment(model) }
        .sheet(isPresented: $showNewProject) { ProjectSheet(editing: nil).environment(model) }
        .sheet(isPresented: $showLiveUpdates) { LiveUpdatesSheet().environment(model) }
        .sheet(item: $settingsProject) { project in ProjectSheet(editing: project).environment(model) }
        .sheet(item: $setupProject) { project in ProjectSheet(editing: project, prefill: setupConfig).environment(model) }
        .task(id: model.selectedProject?.id) { await maybeOfferSetup() }
        // "Board Settings…" on a board in the sidebar asks for the open board's settings.
        .onChange(of: model.wantsProjectSettings, initial: true) { _, wanted in
            guard wanted, let project = model.selectedProject else { return }
            model.wantsProjectSettings = false
            settingsProject = project
        }
        .onChange(of: model.wantsNewProject, initial: true) { _, wanted in
            if wanted { model.wantsNewProject = false; showNewProject = true }
        }
        .onChange(of: model.wantsLiveUpdates, initial: true) { _, wanted in
            if wanted { model.wantsLiveUpdates = false; showLiveUpdates = true }
        }
    }

    @ViewBuilder private var boardContent: some View {
        if model.isLoadingBoard && model.board == nil {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading \(model.activeRepo?.boards.first { $0.folder == model.activeBoardFolder }?.name ?? "board")…")
                    .font(.headline)
                Text(model.activeRepo?.kind.isFolder == true ? "Reading the folder" : "Reading the cards from \(model.activeRepo?.fullName ?? "the repository")")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.openBoardIsEmpty {
            // Nothing in it: say so, and offer the folder that was probably meant.
            ContentUnavailableView {
                Label("No cards in \(model.activeBoardFolder ?? "this folder")", systemImage: "tray")
            } description: {
                if let betterFolder {
                    Text("This folder has no cards in any lane. There is a board at \(betterFolder).")
                } else {
                    Text("This folder has no cards in any lane. If the board lives in another folder, pick it with Browse Boards… in the sidebar.")
                }
            } actions: {
                if let betterFolder {
                    Button("Use \(betterFolder) Instead") { Task { await model.moveOpenBoard(to: betterFolder) } }
                        .buttonStyle(.borderedProminent)
                }
                if let lane = model.board?.columns.first?.lane { Button("New Task") { model.newTaskLane = lane } }
            }
            .task(id: model.activeBoardFolder) { betterFolder = await model.betterFolderForOpenBoard() }
        } else if let board = model.board {
            VStack(spacing: 0) {
                header
                switch model.boardViewMode {
                case .lanes: LanesView(columns: displayColumns(board))
                case .list: ListBoardView(columns: displayColumns(board))
                case .calendar: CalendarBoardView(columns: displayColumns(board))
                }
            }
        } else {
            ContentUnavailableView("No board", systemImage: "square.stack.3d.up",
                                   description: Text("This repo has no project boards."))
        }
    }

    @ViewBuilder private var savingBanner: some View {
        if model.isSaving {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Saving…").font(.caption) }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
        }
    }

    /// What is on screen, with a + for a new task and the board's own menu.
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder").font(.title3).foregroundStyle(.tint)
            Text(model.filterProduct.flatMap { id in model.products.first { $0.id == id }?.name } ?? "Tasks")
                .font(.title3.weight(.semibold))
            if let lane = firstLane {
                Menu {
                    Button("New Task…", systemImage: "plus") { model.newTaskLane = lane }
                    Button("Quick Create with AI…", systemImage: "sparkles") { model.showQuickCreate = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(.quaternary, in: Circle())
                } primaryAction: {
                    model.newTaskLane = lane
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("New task")
                .accessibilityLabel("New task")
                .accessibilityIdentifier("boardNewTask")
            }
            if model.hasActiveFilters {
                Button { model.clearFilters() } label: {
                    Label("Filtered", systemImage: "xmark.circle.fill").font(.caption)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Clear filters")
            }
            Spacer()
            overflowMenu
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 4)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        // Without a sidebar (the demo) this is the way back.
        if model.isDemo {
            ToolbarItem(placement: .navigation) {
                Button { model.closeRepo() } label: {
                    HStack(spacing: 2) { Image(systemName: "chevron.left"); Text("Boards") }
                }
            }
        }
        ToolbarItem(placement: .principal) {
            @Bindable var model = model
            Picker("View", selection: $model.boardViewMode) {
                Label("Board", systemImage: "rectangle.split.3x1").tag(BoardViewMode.lanes)
                Label("List", systemImage: "list.bullet").tag(BoardViewMode.list)
                Label("Calendar", systemImage: "calendar").tag(BoardViewMode.calendar)
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .accessibilityIdentifier("boardViewMode")
        }
        ToolbarItem(placement: .primaryAction) { filterMenu }
    }

    private func focusSearchField() {
        let items = (NSApp.keyWindow ?? NSApp.mainWindow)?.toolbar?.items ?? []
        items.compactMap { $0 as? NSSearchToolbarItem }.first?.beginSearchInteraction()
    }

    /// A task matches the search when its title, id, people, labels or text contain it.
    private func matchesSearch(_ card: Card) -> Bool {
        let query = model.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        let f = card.fields
        return ([f.title, f.id, f.type ?? "", f.assignee ?? "", card.body] + f.tags).contains { $0.lowercased().contains(query) }
    }

    private func isShown(_ card: Card) -> Bool { model.matchesFilters(card) && matchesSearch(card) }

    private func maybeOfferSetup() async {
        guard model.boardNeedsSetup, let project = model.selectedProject,
              !offeredSetup.contains(project.id) else { return }
        offeredSetup.insert(project.id)
        setupConfig = await model.detectConfig(for: project)
        setupProject = project
    }

    private var firstLane: Lane? {
        model.board?.config.lanes.first { !$0.folder.isEmpty && !$0.isBacklog }
            ?? model.board?.config.lanes.first { !$0.folder.isEmpty }
    }

    private var overflowMenu: some View {
        Menu {
            if !model.isDemo {
                Button("Live Updates…", systemImage: "dot.radiowaves.left.and.right") { showLiveUpdates = true }
            }
            Button("New Project…", systemImage: "plus") { showNewProject = true }
            if let project = model.selectedProject {
                Button("Board Settings…", systemImage: "gearshape") { settingsProject = project }
            }
        } label: {
            Image(systemName: "ellipsis").font(.body.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Board")
        .accessibilityLabel("Board menu")
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
            if !model.products.isEmpty {
                Menu("Product") {
                    Button("Any") { model.filterProduct = nil }
                    ForEach(model.products) { product in
                        Button { model.filterProduct = product.id } label: { filterLabel(product.name, model.filterProduct == product.id) }
                    }
                }
            }
            if model.hasActiveFilters {
                Divider()
                Button("Clear Filters", role: .destructive) { model.clearFilters() }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .symbolVariant(model.hasActiveFilters ? .fill : .none)
                .foregroundStyle(model.hasActiveFilters ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .help("Filter")
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
        let filtered = board.columns.map { Column(lane: $0.lane, cards: $0.cards.filter(isShown)) }
        var cols = filtered.filter { !$0.lane.isBacklog } + filtered.filter { $0.lane.isBacklog }
        let uncategorised = board.uncategorised.filter(isShown)
        if !uncategorised.isEmpty {
            cols.append(Column(
                lane: Lane(id: "_uncategorised", name: "Uncategorised", folder: "", status: ""),
                cards: uncategorised
            ))
        }
        return cols
    }
}

// MARK: - Lanes (horizontal kanban)

private struct LanesView: View {
    @Environment(AppModel.self) private var model
    let columns: [Column]

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size.width
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(columns) { column in
                        LaneColumn(column: column, maxHeight: geo.size.height - 24)
                            .visualEffect { content, proxy in
                                content.scaleEffect(
                                    laneScale(frame: proxy.frame(in: .scrollView(axis: .horizontal)), viewport: viewport),
                                    anchor: .top)
                            }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

/// 1.0 when a lane is fully inside the viewport; shrinks toward 0.85 as it scrolls off
/// either edge, so the focused lanes stay large and the rest recede subtly.
private func laneScale(frame: CGRect, viewport: CGFloat) -> CGFloat {
    let overflow = max(max(0, -frame.minX), max(0, frame.maxX - viewport))
    let width = frame.width > 0 ? frame.width : 1
    return 1 - min(1, overflow / width) * 0.15
}

private struct LaneColumn: View {
    @Environment(AppModel.self) private var model
    let column: Column
    let maxHeight: CGFloat
    @State private var isTargeted = false
    /// Where the dragged task would go: the position among the lane's tasks, counted with
    /// the tasks that are on screen.
    @State private var slot: Int?
    /// Where each task on screen sits in the lane, to turn the pointer into a position.
    @State private var cardFrames: [String: CGRect] = [:]

    private var space: String { "lane-\(column.lane.id)" }

    private var color: Color { laneColor(column.lane, model.board?.config ?? EffectiveConfig()) }
    private var isLane: Bool { !column.lane.folder.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The lane's own header: colour, name, how many, and its menu.
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 11, height: 11)
                Text(column.lane.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text("\(column.cards.count)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                if isLane {
                    Menu {
                        Button("New Task…", systemImage: "plus") { model.newTaskLane = column.lane }
                        if column.lane.isBacklog, !model.loadedBacklogLanes.contains(column.lane.id) {
                            Button("Load Backlog", systemImage: "tray.and.arrow.down") { Task { await model.loadBacklogLane(column.lane) } }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("\(column.lane.name) menu")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.stroke))

            if column.lane.isBacklog && !model.loadedBacklogLanes.contains(column.lane.id) {
                Button {
                    Task { await model.loadBacklogLane(column.lane) }
                } label: {
                    if model.loadingBacklogLane == column.lane.id {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else {
                        Label("Load Backlog", systemImage: "tray.and.arrow.down")
                            .font(.callout)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.vertical, 24)
                Spacer(minLength: 0)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(column.cards.enumerated()), id: \.element.id) { index, card in
                            // The lane opens a gap where the dragged task will go.
                            if slot == index { dropSlot }
                            LaneCardCell(card: card)
                                .background(GeometryReader { proxy in
                                    Color.clear.preference(key: CardFrames.self,
                                                           value: [card.fields.id: proxy.frame(in: .named(space))])
                                })
                                .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                        if let slot, slot >= column.cards.count { dropSlot }
                        if isLane {
                            Button { model.newTaskLane = column.lane } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus")
                                    Text("Add task")
                                }
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    // Cards settle into their place with a little bounce when one arrives or leaves.
                    .animation(.bouncy(duration: 0.45, extraBounce: 0.2), value: column.cards.map(\.id))
                    .animation(.bouncy(duration: 0.3, extraBounce: 0.25), value: slot)
                }
                .onPreferenceChange(CardFrames.self) { cardFrames = $0 }
            }
        }
        .frame(width: 280)
        // The full height of the board, so a task can be dropped anywhere in the lane and
        // not only on the tasks that are already there.
        .frame(height: maxHeight, alignment: .top)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .coordinateSpace(name: space)
        .background(isTargeted ? color.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(color.opacity(isTargeted ? 0.55 : 0), lineWidth: 1.5))
        // The lane the task hovers over leans in a little.
        .scaleEffect(isTargeted ? 1.015 : 1, anchor: .top)
        .animation(.bouncy(duration: 0.3, extraBounce: 0.3), value: isTargeted)
        .onDrop(of: [.utf8PlainText, .plainText], delegate: LaneDrop(
            isLane: isLane,
            entered: {
                isTargeted = true
                // A tick in the trackpad when the task crosses into a lane.
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            },
            moved: { point in
                let position = position(at: point)
                guard position != slot else { return }
                if slot != nil { NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now) }
                slot = position
            },
            exited: { isTargeted = false; slot = nil },
            dropped: { id, point in
                let position = position(at: point)
                isTargeted = false; slot = nil
                place(id, at: position)
            }))
    }

    private var dropSlot: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .frame(height: 54)
            .transition(.scale(scale: 0.6, anchor: .top).combined(with: .opacity))
    }

    /// The position a task dropped at `point` takes: before the first task whose middle is
    /// below the pointer, or after the last one. Tasks scrolled out of view have no frame
    /// and are skipped, which is right: the pointer is not near them.
    private func position(at point: CGPoint) -> Int {
        for (index, card) in column.cards.enumerated() {
            if let frame = cardFrames[card.fields.id], point.y < frame.midY { return index }
        }
        return column.cards.count
    }

    private func place(_ id: String, at position: Int) {
        guard isLane, let card = model.allCards.first(where: { $0.fields.id == id }) else { return }
        // "Before this task" survives filters: the lane may hold tasks that are not shown.
        let shown = column.cards.filter { $0.fields.id != id }
        let own = column.cards.firstIndex { $0.fields.id == id }
        let index = own.map { position > $0 ? position - 1 : position } ?? position
        let before = index < shown.count ? shown[index].fields.id : nil
        if own == index { return } // dropped where it was
        BoardMotion.shared.land(id)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        Task { await model.placeCard(card, in: column.lane, before: before) }
    }
}

private struct CardFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A lane as the place to drop a task: reports where the pointer is while a task hangs
/// over it, and which task was let go.
private struct LaneDrop: DropDelegate {
    let isLane: Bool
    let entered: () -> Void
    let moved: (CGPoint) -> Void
    let exited: () -> Void
    let dropped: (String, CGPoint) -> Void

    func validateDrop(info: DropInfo) -> Bool { isLane }
    /// A drag is only under way while the button is held. The system still reports a
    /// position after the task was let go, which would open a gap for nothing.
    private var isDragging: Bool { NSEvent.pressedMouseButtons & 1 == 1 }

    func dropEntered(info: DropInfo) {
        guard isDragging else { return }
        entered(); moved(info.location)
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if isDragging { moved(info.location) }
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { exited() }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.utf8PlainText, .plainText]).first else { exited(); return false }
        let point = info.location
        // Close the gap now, not when the task's id has been read.
        exited()
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            let id = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor in
                if id.isEmpty { exited() } else { dropped(id, point) }
            }
        }
        return true
    }
}

/// Which task was just dropped, so the card that shows up in its new lane can land with
/// a pop instead of simply being there.
@MainActor
@Observable
final class BoardMotion {
    static let shared = BoardMotion()
    private(set) var landing: String?

    func land(_ id: String) {
        landing = id
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if landing == id { landing = nil }
        }
    }
}

private struct LaneCardCell: View {
    @Environment(AppModel.self) private var model
    let card: Card
    private var priorities: [Priority] { model.board?.config.priorities ?? [] }
    private var isSelected: Bool { model.selectedCard?.id == card.id }
    @Environment(\.openWindow) private var openWindow
    private var isLanding: Bool { BoardMotion.shared.landing == card.fields.id }
    /// False for the first moment of a landing: the card starts small and tilted, then springs upright.
    @State private var settled = true

    var body: some View {
        face
            .scaleEffect(settled ? 1 : 0.86)
            .rotationEffect(.degrees(settled ? 0 : -4), anchor: .top)
            .shadow(color: .black.opacity(isLanding ? 0.35 : 0), radius: isLanding ? 10 : 0, y: isLanding ? 6 : 0)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(isLanding ? 0.7 : 0), lineWidth: 2))
            .animation(.easeOut(duration: 0.6), value: isLanding)
            .onAppear {
                guard isLanding else { return }
                settled = false
                withAnimation(.bouncy(duration: 0.6, extraBounce: 0.4)) { settled = true }
            }
            .draggable(card.fields.id) {
                // What hangs from the pointer: the card itself, lifted and tilted.
                face
                    .frame(width: 256)
                    .rotationEffect(.degrees(3))
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                    .padding(18)
            }
            .contextMenu { cardMenu(card, model: model) }
    }

    @State private var isHovered = false
    private var isDone: Bool { model.location(ofCard: card)?.terminal == true }

    private var face: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 6) {
                Text(card.fields.title.isEmpty ? card.fields.id : card.fields.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // The task's menu, there when the pointer is or the task is selected.
                Menu { cardMenu(card, model: model) } label: {
                    Image(systemName: "ellipsis")
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 16).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .opacity(isHovered || isSelected ? 1 : 0)
                .accessibilityLabel("Task menu")
            }
            TaskMetaLine(card: card, priorities: priorities, done: isDone)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(Theme.card))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Theme.stroke), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { model.selectedCard = card }
        // A double-click opens the task in a window of its own. Alongside the single
        // click, not instead of it, so selecting stays immediate.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            openWindow(id: TaskPanel.windowID, value: card.fields.id)
        })
    }
}

// MARK: - List

private struct ListBoardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let columns: [Column]

    var body: some View {
        List {
            ForEach(columns) { column in
                Section {
                    if column.lane.isBacklog && !model.loadedBacklogLanes.contains(column.lane.id) {
                        Button {
                            Task { await model.loadBacklogLane(column.lane) }
                        } label: {
                            Label(model.loadingBacklogLane == column.lane.id ? "Loading…" : "Load Backlog",
                                  systemImage: "tray.and.arrow.down")
                        }
                    } else if column.cards.isEmpty {
                        Text("No tasks").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ForEach(column.cards) { card in
                            Button { model.selectedCard = card } label: {
                                CardRow(card: card, priorities: model.board?.config.priorities ?? [])
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture(count: 2).onEnded {
                                openWindow(id: TaskPanel.windowID, value: card.fields.id)
                            })
                            .contextMenu { cardMenu(card, model: model) }
                        }
                        .onMove { indices, newOffset in
                            guard !column.lane.folder.isEmpty, !model.hasActiveFilters else { return }
                            var ids = column.cards.map { $0.fields.id }
                            ids.move(fromOffsets: indices, toOffset: newOffset)
                            Task { await model.reorderCards(in: column.lane, orderedIDs: ids) }
                        }
                    }
                } header: {
                    HStack(spacing: 7) {
                        Circle().fill(laneColor(column.lane, model.board?.config ?? EffectiveConfig()))
                            .frame(width: 8, height: 8)
                        Text(column.lane.name)
                        Text("\(column.cards.count)").foregroundStyle(.secondary)
                        Spacer()
                        if !column.lane.folder.isEmpty {
                            Button { model.newTaskLane = column.lane } label: { Image(systemName: "plus.circle") }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}

struct CardRow: View {
    let card: Card
    let priorities: [Priority]

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(card.fields.title.isEmpty ? card.fields.id : card.fields.title)
                    .font(.body).lineLimit(1).truncationMode(.tail)
                if !card.fields.id.isEmpty {
                    Text(card.fields.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            ForEach(card.fields.tags.prefix(2), id: \.self) { LabelChip(text: $0) }
            TaskMetaLine(card: card, priorities: priorities).fixedSize()
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

// MARK: - Shared card context menu

@MainActor @ViewBuilder
func cardMenu(_ card: Card, model: AppModel) -> some View {
    let config = model.board?.config ?? EffectiveConfig()

    OpenTaskPanelButton(card: card)
    Divider()

    if !config.lanes.isEmpty {
        Menu("Move to", systemImage: "arrow.left.arrow.right") {
            ForEach(config.lanes, id: \.id) { lane in
                menuCheck(lane.name, card.fields.status == lane.status) { Task { await model.moveCard(card, to: lane) } }
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
        Button("Copy Link", systemImage: "link") { Platform.copy(url.absoluteString) }
        Button("Open on GitHub", systemImage: "safari") { Platform.open(url) }
    }
    // The .md itself, in whatever app opens Markdown. A repository's file is a downloaded copy.
    Button(model.cardFilesAreLocal ? "Open File" : "Open a Copy of the File", systemImage: "doc.text") {
        Task { if let url = await model.fileURL(for: card) { Platform.open(url) } }
    }
    Button("Copy ID", systemImage: "number") { Platform.copy(card.fields.id) }

    Divider()
    Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.deleteCard(card) } }
}

@ViewBuilder
private func menuCheck(_ text: String, _ selected: Bool, _ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        if selected { Label(text, systemImage: "checkmark") } else { Text(text) }
    }
}

// MARK: - Colours

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
