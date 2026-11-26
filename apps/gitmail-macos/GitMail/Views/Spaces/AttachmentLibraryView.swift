import MailCore
import MailStore
import QuickLook
import SwiftUI

/// Every attachment across accounts (or in one space), newest first, with filters. Selecting
/// one opens its message in the reader; Quick Look shows a quarantined copy; Save As writes one
/// the person chooses where to keep (GKM-023).
struct AttachmentLibraryView: View {
    @Environment(AppModel.self) private var model
    /// The space it is shown inside, or nil for the whole library.
    let space: MailSpaceID?
    @State private var previewURL: URL?
    @FocusState private var focused: Bool

    private var library: AttachmentLibraryModel { model.library }

    var body: some View {
        VStack(spacing: 0) {
            AttachmentFilterBar(showsSpace: space == nil)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if library.items.isEmpty {
                QuietNote(library.filters.isEmpty ? "No attachments here." : "No attachments match.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.window)
        .quickLookPreview($previewURL)
        .task(id: space) { await library.show(in: space) }
        .alert("Something went wrong", isPresented: Binding(
            get: { library.actionError != nil }, set: { if !$0 { library.actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.actionError ?? "")
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(library.items) { item in
                    AttachmentRow(item: item, isSelected: item.id == library.selectedItemID,
                                  accountName: model.accounts.count > 1 ? model.accounts.first { $0.id == item.account }?.displayName : nil)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { quickLook(item) }
                        .onTapGesture {
                            focused = true
                            Task { await library.select(item.id) }
                        }
                        .contextMenu { menu(for: item) }
                        // VoiceOver: VO-Space selects it (and shows its message); the menu's
                        // items are its actions.
                        .accessibilityAction { Task { await library.select(item.id) } }
                        .accessibilityAction(named: "Quick Look") { quickLook(item) }
                        .accessibilityAction(named: "Save As…") { save(item) }
                        .onAppear {
                            if item.id == library.items.last?.id { Task { await library.loadMore() } }
                        }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space) {
            guard let item = library.selectedItem else { return .ignored }
            quickLook(item)
            return .handled
        }
        .onMoveCommand { direction in
            guard let index = library.items.firstIndex(where: { $0.id == library.selectedItemID }) ?? (direction == .down ? -1 : nil)
            else { return }
            let next = direction == .down ? index + 1 : direction == .up ? index - 1 : index
            guard library.items.indices.contains(next) else { return }
            Task { await library.select(library.items[next].id) }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(library.totalCount) \(library.totalCount == 1 ? "attachment" : "attachments"), \(ByteCountFormatter.string(fromByteCount: Int64(library.totalBytes), countStyle: .file))")
            Spacer()
            if let item = library.selectedItem {
                Button("Quick Look", systemImage: "eye") { quickLook(item) }
                    .labelStyle(.iconOnly)
                    .help("Quick Look (Space)")
                Button("Save As…", systemImage: "square.and.arrow.down") { save(item) }
                    .labelStyle(.iconOnly)
                    .help("Save a copy…")
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func menu(for item: AttachmentItem) -> some View {
        Button("Quick Look") { quickLook(item) }
        Button("Save As…") { save(item) }
        Divider()
        Button("Show Message") { Task { await library.select(item.id) } }
    }

    private func quickLook(_ item: AttachmentItem) {
        Task {
            do { previewURL = try await library.previewFile(for: item) } catch { library.actionError = String(describing: error) }
        }
    }

    private func save(_ item: AttachmentItem) {
        Task {
            guard let url = await Platform.chooseSaveLocation(suggestedName: library.suggestedFileName(for: item)) else { return }
            do { try await library.save(item, to: url) } catch { library.actionError = String(describing: error) }
        }
    }
}

/// One attachment: what it is, how big, who sent it and when.
private struct AttachmentRow: View {
    let item: AttachmentItem
    let isSelected: Bool
    let accountName: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    // The real extension is part of the displayed name; bidi controls were
                    // stripped when the name was stored (ThreatModel §4).
                    Text(item.reference.fileName.isEmpty ? "Untitled" : item.reference.fileName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.reference.size), countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text(item.from?.displayName ?? "Unknown sender").lineLimit(1)
                    Text("·")
                    Text(MessageDate.short(item.date))
                    if let accountName { Text("·"); Text(accountName).lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(item.subject?.isEmpty == false ? item.subject! : "(No subject)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Theme.accent.opacity(0.22) : .clear))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private var icon: String {
        switch item.kind {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .archive: "doc.zipper"
        case .audio: "waveform"
        case .video: "film"
        case .calendar: "calendar"
        case .other: "doc"
        }
    }
}

/// The library's chips: kind, name, sender, date, account, space, size, inline parts.
private struct AttachmentFilterBar: View {
    @Environment(AppModel.self) private var model
    let showsSpace: Bool
    @State private var name = ""
    @State private var sender = ""

    private var filters: AttachmentFilters { model.library.filters }

    private func update(_ change: (inout AttachmentFilters) -> Void) {
        var next = filters
        change(&next)
        Task { await model.library.setFilters(next) }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                TextField("File name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { update { $0.name = name } }
                TextField("Sender", text: $sender)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { update { $0.sender = sender } }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chipMenu(title: filters.kind?.title ?? "Kind", systemImage: "doc.on.doc", active: filters.kind != nil) {
                        Button("Any Kind") { update { $0.kind = nil } }
                        Divider()
                        ForEach(AttachmentKind.allCases) { kind in Button(kind.title) { update { $0.kind = kind } } }
                    }
                    chipMenu(title: filters.date == .any ? "Date" : filters.date.title, systemImage: "calendar", active: filters.date != .any) {
                        ForEach(DateFilter.allCases) { date in Button(date.title) { update { $0.date = date } } }
                    }
                    if model.accounts.count > 1 {
                        chipMenu(title: filters.account.flatMap { id in model.accounts.first { $0.id == id }?.displayName } ?? "Account",
                                 systemImage: "person.crop.circle", active: filters.account != nil) {
                            Button("Any Account") { update { $0.account = nil } }
                            Divider()
                            ForEach(model.accounts) { account in Button(account.displayName) { update { $0.account = account.id } } }
                        }
                    }
                    if showsSpace, !model.spaces.spaces.isEmpty {
                        chipMenu(title: filters.space.flatMap { model.spaces.space($0)?.name } ?? "Space",
                                 systemImage: "square.stack.3d.up", active: filters.space != nil) {
                            Button("Any Space") { update { $0.space = nil } }
                            Divider()
                            ForEach(model.spaces.spaces) { space in Button(space.name) { update { $0.space = space.id } } }
                        }
                    }
                    chipMenu(title: filters.size == .any ? "Size" : filters.size.title, systemImage: "scalemass", active: filters.size != .any) {
                        ForEach(AttachmentSizeFilter.allCases) { size in Button(size.title) { update { $0.size = size } } }
                    }
                    Button { update { $0.includeInline.toggle() } } label: {
                        Chip(title: "Inline Images", systemImage: "photo.on.rectangle", isActive: filters.includeInline)
                    }
                    .buttonStyle(.plain)
                    .help("Also list pictures placed in messages, such as signature logos")
                    if !filters.isEmpty {
                        Button("Clear") {
                            name = ""
                            sender = ""
                            update { $0 = AttachmentFilters() }
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                    }
                }
            }
        }
        .onAppear {
            name = filters.name
            sender = filters.sender
        }
    }

    private func chipMenu<Content: View>(title: String, systemImage: String, active: Bool,
                                         @ViewBuilder content: () -> Content) -> some View {
        Menu(content: content) {
            Chip(title: title, systemImage: systemImage, isActive: active)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
