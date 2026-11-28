import GitKanbanKit
import GitKittieKit
import SwiftUI

// The parts of the review screens for actions, assignment, due dates and browser checks
// (GITKITTIE-135 on the Mac, GITKITTIE-136 on iPhone and iPad). They are drawn the same way on
// both, over `ReviewPresentation` and `ReviewCheckSession` in GitKanbanKit, which say what to
// show; the screens place them.

// MARK: - Small tags

/// "Due tomorrow", red when overdue.
struct ReviewDueTag: View {
    let label: ReviewDueLabel

    var body: some View {
        Label(label.text, systemImage: label.overdue ? "exclamationmark.circle.fill" : "calendar")
            .font(.caption.weight(label.overdue || label.soon ? .semibold : .regular))
            .foregroundStyle(label.overdue ? AnyShapeStyle(Color.red) : label.soon ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
            .accessibilityIdentifier("reviewDue")
    }
}

/// "For Sil": who decides the request.
struct ReviewForChip: View {
    let text: String
    /// The request is someone else's: drawn quieter.
    var others = false

    var body: some View {
        Label(text, systemImage: "person.fill")
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background((others ? Color.secondary : Theme.accent).opacity(0.18), in: Capsule())
            .foregroundStyle(others ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.accentText))
            .accessibilityIdentifier("reviewForChip")
    }
}

/// "Round 2": the request redoes earlier entries.
struct ReviewRoundTag: View {
    var body: some View {
        Label("Round 2", systemImage: "arrow.triangle.2.circlepath")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.purple.opacity(0.18), in: Capsule())
            .foregroundStyle(.purple)
            .accessibilityIdentifier("reviewRoundTag")
    }
}

/// "For Herma. You can comment." on top of someone else's request.
struct ReviewReadOnlyNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "eye")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("reviewReadOnlyNotice")
    }
}

// MARK: - Who you are

/// "Which one are you on Pets?": asked once per board whose users your login matches none of,
/// when it has requests for named people. Kept on this device.
struct ReviewIdentityPrompt: View {
    @Environment(AppModel.self) private var model
    let board: BoardReviews

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which one are you on \(board.boardName)?").font(.subheadline.weight(.semibold))
            Text("Requests can be for one person. Your sign-in matches nobody on this board, so say who you are here. Only this device remembers it.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 6) {
                ForEach(model.reviewIdentityCandidates(boardKey: board.id), id: \.id) { user in
                    Button(user.name ?? user.id) { model.setReviewIdentity(user.id, boardKey: board.id) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("reviewIdentity-\(user.id)")
                }
                Button("None of These") { model.setReviewIdentity(nil, boardKey: board.id) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("reviewIdentityNone")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reviewIdentityPrompt")
    }
}

// MARK: - Actions

/// What happened after a decision ran a request's actions: "Moved PETS-1 to Testing · Undo"
/// for eight seconds (⌘Z on the Mac), "PETS-2 is claimed by herma — Move anyway?", and what
/// could not run. Shown wherever a decision can be made.
struct ReviewActionBannerView: View {
    @Environment(AppModel.self) private var model
    /// Light text on the full-screen viewer's black.
    var onDark = false
    /// Undo was offered for eight seconds and the time is up (the banner stays while something
    /// still waits for an answer).
    @State private var undoExpired: UUID?
    @State private var working = false

    var body: some View {
        if let report = model.reviewActionReport {
            let banner = model.reviewActionBanner(report)
            if !banner.isEmpty {
                content(banner, reportID: report.id)
                    .task(id: report.id) {
                        try? await Task.sleep(nanoseconds: UInt64(ReviewActionBanner.undoSeconds * 1_000_000_000))
                        guard !Task.isCancelled, model.reviewActionReport?.id == report.id else { return }
                        if banner.autoDismissAfter != nil { model.dismissReviewActionReport() } else { undoExpired = report.id }
                    }
            }
        }
    }

    private func content(_ banner: ReviewActionBanner, reportID: UUID) -> some View {
        let canUndo = !banner.undoable.isEmpty && undoExpired != reportID
        return VStack(alignment: .leading, spacing: 8) {
            if !banner.message.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(.green)
                    Text(banner.message).font(.callout.weight(.medium))
                        .lineLimit(2)
                        .accessibilityIdentifier("reviewActionMessage")
                    Spacer(minLength: 8)
                    if canUndo {
                        Button("Undo") { undo(banner) }
                            .font(.callout.weight(.semibold))
                            .disabled(working)
                            .help("Move the card back (⌘Z)")
                            .accessibilityIdentifier("reviewActionUndo")
                        #if os(macOS)
                            .keyboardShortcut("z", modifiers: .command)
                        #endif
                    }
                }
            }
            ForEach(banner.prompts) { prompt in
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(prompt.text).font(.callout).lineLimit(3)
                        .accessibilityIdentifier("reviewActionPrompt")
                    Spacer(minLength: 8)
                    Button(prompt.button) {
                        working = true
                        Task { await model.moveAnyway(prompt.conflict); working = false }
                    }
                    .font(.callout.weight(.semibold))
                    .disabled(working)
                    .accessibilityIdentifier("reviewActionMoveAnyway")
                }
            }
            ForEach(banner.failures, id: \.self) { failure in
                Label(failure, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red).lineLimit(3)
            }
        }
        .padding(.leading, 14).padding(.trailing, 34).padding(.vertical, 10)
        .overlay(alignment: .topTrailing) {
            Button { model.dismissReviewActionReport() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("reviewActionClose")
        }
        .frame(maxWidth: 560, alignment: .leading)
        .background(onDark ? AnyShapeStyle(Color.white.opacity(0.14)) : AnyShapeStyle(Theme.card), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.stroke) }
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .padding(.horizontal, 16).padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reviewActionBanner")
    }

    private func undo(_ banner: ReviewActionBanner) {
        working = true
        Task {
            await model.undoReviewActions(banner)
            working = false
        }
    }
}

/// A request's "When decided" section (what deciding it will do, in words) and its "Actions"
/// history (what deciding it did, with Undo while the card is untouched).
struct ReviewActionsSection: View {
    @Environment(AppModel.self) private var model
    let request: ReviewRequest
    /// History entries the board says can still be undone, by index.
    @State private var undoable: Set<Int> = []
    @State private var undoing: Int?

    var body: some View {
        let lines = model.reviewActionLines(request)
        let history = model.reviewActionHistory(request)
        if !lines.isEmpty || !history.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("When decided").font(.subheadline.weight(.semibold))
                        ForEach(lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: line.ran ? "checkmark.circle.fill" : symbol(line.outcome))
                                    .foregroundStyle(line.ran ? AnyShapeStyle(Color.green) : AnyShapeStyle(color(line.outcome)))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((line.entry.map { "\($0): " } ?? "") + line.text)
                                        .font(.callout)
                                        .foregroundStyle(line.laneFound ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.red))
                                        .accessibilityIdentifier("reviewWhenDecided")
                                    if let detail = line.detail {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    if !line.laneFound {
                                        Text("“\(line.lane)” is no lane of this board, so this will not run.")
                                            .font(.caption).foregroundStyle(.red)
                                    }
                                }
                            }
                        }
                    }
                }
                if !history.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Actions").font(.subheadline.weight(.semibold))
                        ForEach(history) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: historySymbol(line.run))
                                    .foregroundStyle(line.run.result == .skipped ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(line.text).font(.callout)
                                        .foregroundStyle(line.run.result == .skipped ? AnyShapeStyle(Color.red) : AnyShapeStyle(.primary))
                                        .accessibilityIdentifier("reviewActionHistory")
                                    Text("\(line.run.on.title) · \(line.run.by) · \(ReviewTime.relative(line.run.at))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if undoable.contains(line.index) {
                                    Button("Undo") { undo(line.index) }
                                        .font(.callout)
                                        .disabled(undoing != nil)
                                        .help("Move \(line.run.card) back")
                                        .accessibilityIdentifier("reviewActionHistoryUndo")
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: 680, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reviewActionsSection")
            // Asked again whenever the history changes (an undo, a new run).
            .task(id: history.map { "\($0.index)|\($0.run.undoneAt ?? "")" }.joined(separator: ",")) {
                var ok: Set<Int> = []
                for line in history where line.mayUndo {
                    if await model.canUndoReviewAction(request.ref, index: line.index) { ok.insert(line.index) }
                }
                undoable = ok
            }
        }
    }

    private func undo(_ index: Int) {
        undoing = index
        Task {
            await model.undoReviewAction(request.ref, index: index)
            undoing = nil
        }
    }

    private func symbol(_ outcome: ReviewOutcome) -> String {
        switch outcome {
        case .accept: return "checkmark.circle"
        case .changes: return "pencil.circle"
        case .reject: return "xmark.circle"
        }
    }

    private func color(_ outcome: ReviewOutcome) -> Color {
        switch outcome {
        case .accept: return .green
        case .changes: return .orange
        case .reject: return .red
        }
    }

    private func historySymbol(_ run: ActionRun) -> String {
        if run.undoneAt != nil { return "arrow.uturn.backward.circle" }
        switch run.result {
        case .moved: return "arrow.right.circle.fill"
        case .already: return "equal.circle"
        case .skipped: return "exclamationmark.circle"
        case .undone: return "arrow.uturn.backward.circle"
        }
    }
}

enum ReviewTime {
    static func relative(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Browser checks

/// A check's sizes × appearance, each cell pass, fail or how far it is. Tapping a cell opens the
/// check at that size when `open` is given.
struct CheckGridView: View {
    let check: ReviewCheck
    /// The cell on screen, drawn filled.
    var current: String?
    var open: ((String) -> Void)?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            if !check.appearance.isEmpty {
                GridRow {
                    Text("")
                    ForEach(check.appearance, id: \.self) { look in
                        Label(look == .dark ? "Dark" : "Light", systemImage: look == .dark ? "moon.fill" : "sun.max.fill")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(check.grid) { row in
                GridRow {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.size.label).font(.caption.weight(.semibold))
                        if let viewport = row.size.viewport {
                            Text(viewport.replacingOccurrences(of: "x", with: " × ")).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    ForEach(row.cells) { cell in
                        cellView(cell)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("checkGrid")
    }

    @ViewBuilder private func cellView(_ cell: CheckGridRow.Cell) -> some View {
        let (text, symbol, tint) = describe(cell.state)
        let label = Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold)).monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(minWidth: 74, alignment: .leading)
            .background(tint.opacity(cell.key == current ? 0.35 : 0.14), in: RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(tint == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
        if let open {
            Button { open(cell.key) } label: { label }
                .buttonStyle(.plain)
                .help("Check \(check.label(forKey: cell.key))")
                .accessibilityLabel("\(check.label(forKey: cell.key)): \(text)")
                .accessibilityIdentifier("checkCell-\(cell.key)")
        } else {
            label
                .accessibilityLabel("\(check.label(forKey: cell.key)): \(text)")
                .accessibilityIdentifier("checkCell-\(cell.key)")
        }
    }

    private func describe(_ state: CheckCellState) -> (String, String, Color) {
        switch state {
        case .untouched: return ("Pending", "circle.dashed", .secondary)
        case .partial(let answered, let total): return ("\(answered)/\(total)", "circle.lefthalf.filled", Theme.accent)
        case .passed: return ("Pass", "checkmark.circle.fill", .green)
        case .noted: return ("Noted", "text.bubble.fill", .teal)
        case .failed(let count): return (count == 1 ? "1 fail" : "\(count) fail", "xmark.circle.fill", .red)
        }
    }
}

/// The checklist for the size on screen: each statement with Pass, Fail and Note; a note field
/// opens on Fail and Note.
struct CheckChecklistView: View {
    @Environment(AppModel.self) private var model
    let session: ReviewCheckSession
    /// The line chosen with the keyboard on the Mac (↑ / ↓, P, F, N).
    var focusedLine: String?
    @State private var notes: [String: String] = [:]
    @State private var writingNote: Set<String> = []
    @FocusState private var noteFocus: String?

    var body: some View {
        let check = session.check
        VStack(alignment: .leading, spacing: 10) {
            ForEach(check?.checklist ?? []) { line in
                row(line)
            }
            if check?.checklist.isEmpty ?? true {
                Text("This check has no checklist: look at the page and decide.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .disabled(session.isReadOnly)
        .onChange(of: session.key) { _, _ in notes = [:]; writingNote = [] }
    }

    private func row(_ line: CheckLine) -> some View {
        let answer = session.answer(line.id)
        let showsNote = writingNote.contains(line.id) || answer?.note != nil
        return VStack(alignment: .leading, spacing: 6) {
            Text(line.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                choice("Pass", "checkmark", .green, selected: answer?.result == .pass, id: "checkPass-\(line.id)") {
                    toggle(line, .pass)
                }
                choice("Fail", "xmark", .red, selected: answer?.result == .fail, id: "checkFail-\(line.id)") {
                    toggle(line, .fail)
                    writingNote.insert(line.id)
                }
                choice("Note", "text.bubble", .teal, selected: answer?.result == .note, id: "checkNote-\(line.id)") {
                    writingNote.insert(line.id)
                    if answer?.result == .note { session.setAnswer(line.id, nil); writingNote.remove(line.id) }
                }
            }
            if showsNote {
                HStack(spacing: 6) {
                    TextField(answer?.result == .fail ? "What is wrong (optional)" : "Note", text: Binding(
                        get: { notes[line.id] ?? answer?.note ?? "" },
                        set: { notes[line.id] = $0 }), axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .focused($noteFocus, equals: line.id)
                        .onSubmit { saveNote(line) }
                        .accessibilityIdentifier("checkNoteField-\(line.id)")
                    Button("Save") { saveNote(line) }
                        .disabled((notes[line.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("checkNoteSave-\(line.id)")
                }
            }
        }
        .padding(10)
        .background(focusedLine == line.id ? Theme.accent.opacity(0.18) : Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("checkLine-\(line.id)")
    }

    private func toggle(_ line: CheckLine, _ result: CheckAnswerResult) {
        let current = session.answer(line.id)
        if current?.result == result {
            session.setAnswer(line.id, nil)
        } else {
            session.setAnswer(line.id, result, note: current?.note)
        }
    }

    /// A note on a failed line stays a fail with a note; on any other line it is a note.
    private func saveNote(_ line: CheckLine) {
        let text = (notes[line.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let result: CheckAnswerResult = session.answer(line.id)?.result == .fail ? .fail : .note
        if session.setAnswer(line.id, result, note: text) {
            notes[line.id] = nil
            noteFocus = nil
        }
    }

    private func choice(_ title: String, _ symbol: String, _ tint: Color, selected: Bool, id: String,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(selected ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.12)), in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Approve, Changes (with the failed lines filled in, since Changes needs a message) and Reject
/// for a whole check, like a file.
struct CheckDecisionButtons: View {
    @Environment(AppModel.self) private var model
    let session: ReviewCheckSession
    /// ⌘↩ approves and ⌥⌘↩ asks for changes (the Check in Browser window, where there is one check).
    var shortcuts = false
    @State private var changes: ReviewCommentRequest?

    var body: some View {
        let status = session.storedCheck?.status ?? .pending
        HStack(spacing: 8) {
            button("Approve", "checkmark", .approved, .green, selected: status == .approved) {
                Task { await session.decide(.approved) }
            }
            .modifier(MacShortcut(key: .return, modifiers: .command, enabled: shortcuts))
            button("Changes", "pencil", .changesRequested, .orange, selected: status == .changesRequested) { askChanges() }
                .modifier(MacShortcut(key: .return, modifiers: [.command, .option], enabled: shortcuts))
            button("Reject", "xmark", .rejected, .red, selected: status == .rejected) {
                Task { await session.decide(.rejected) }
            }
        }
        .disabled(session.isReadOnly || session.isWriting || model.isSaving)
        .help(session.readOnlyNotice ?? "")
        .sheet(item: $changes) { ReviewCommentSheet(request: $0) }
    }

    private func askChanges() {
        let session = session
        let title = session.storedCheck?.title ?? session.checkID
        changes = ReviewCommentRequest(
            purpose: .changes(files: 1), subject: title,
            suggestions: session.request?.commentSuggestions() ?? [],
            initialText: session.changesDraft,
            send: { text in Task { await session.decide(.changesRequested, comment: text) } })
    }

    private func button(_ title: String, _ symbol: String, _ status: ReviewStatus, _ tint: Color, selected: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(selected ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(0.14)), in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("checkDecision\(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A keyboard shortcut on the Mac only.
struct MacShortcut: ViewModifier {
    let key: KeyEquivalent
    let modifiers: EventModifiers
    var enabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        if enabled { content.keyboardShortcut(key, modifiers: modifiers) } else { content }
        #else
        content
        #endif
    }
}
