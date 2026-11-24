import Foundation
import MailCore
import MailStore
import Observation

/// The size filter of the attachment library.
enum AttachmentSizeFilter: String, CaseIterable, Identifiable {
    case any, overOneMB, overTenMB
    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: "Any Size"
        case .overOneMB: "Over 1 MB"
        case .overTenMB: "Over 10 MB"
        }
    }

    var minimumBytes: Int? {
        switch self {
        case .any: nil
        case .overOneMB: 1_000_000
        case .overTenMB: 10_000_000
        }
    }
}

/// The library's filter chips.
struct AttachmentFilters: Equatable {
    var kind: AttachmentKind?
    var name = ""
    var sender = ""
    var date = DateFilter.any
    var account: MailAccountID?
    var space: MailSpaceID?
    var size = AttachmentSizeFilter.any
    var includeInline = false

    var isEmpty: Bool { self == AttachmentFilters() }
}

/// The attachment library (GKM-023): every attachment across accounts, from the index. The bytes
/// are read only when the person asks: Quick Look of a quarantined copy (the reader's path),
/// Save As, which also marks the saved file as downloaded so Gatekeeper checks it (ThreatModel §4).
@MainActor
@Observable
final class AttachmentLibraryModel {
    static let pageSize = 200

    private(set) var filters = AttachmentFilters()
    /// The space the library is shown inside (the space view's Attachments tab), or nil for all.
    private(set) var space: MailSpaceID?
    private(set) var items: [AttachmentItem] = []
    private(set) var totalCount = 0
    private(set) var totalBytes = 0
    private(set) var canLoadMore = false
    private(set) var selectedItemID: String?
    var actionError: String?

    private var store: MailStore?
    private weak var browser: MailBrowser?
    private var generation = 0
    var calendar = Calendar.current
    var now: () -> Date = Date.init

    func attach(_ store: MailStore, browser: MailBrowser) {
        self.store = store
        self.browser = browser
        items = []
        selectedItemID = nil
    }

    var selectedItem: AttachmentItem? { selectedItemID.flatMap { id in items.first { $0.id == id } } }

    /// The store query: the chips, inside the space the library is shown in.
    var query: AttachmentQuery {
        AttachmentQuery(kind: filters.kind, name: filters.name.trimmingCharacters(in: .whitespaces),
                        sender: filters.sender.trimmingCharacters(in: .whitespaces), account: filters.account,
                        space: space ?? filters.space, after: filters.date.start(now: now(), calendar: calendar),
                        minimumSize: filters.size.minimumBytes, includeInline: filters.includeInline)
    }

    // MARK: Intents

    func setFilters(_ filters: AttachmentFilters) async {
        guard filters != self.filters else { return }
        self.filters = filters
        await reload()
    }

    func show(in space: MailSpaceID?) async {
        guard space != self.space || items.isEmpty else { return }
        self.space = space
        selectedItemID = nil
        await reload()
    }

    func reload() async {
        guard let store else { return }
        generation += 1
        let mine = generation
        do {
            let query = query
            let found = try await store.attachments(query, limit: Self.pageSize)
            let totals = try await store.attachmentTotals(query)
            guard mine == generation else { return }
            items = found
            totalCount = totals.count
            totalBytes = totals.bytes
            canLoadMore = found.count == Self.pageSize
            if let selected = selectedItemID, !items.contains(where: { $0.id == selected }) { selectedItemID = nil }
        } catch {
            actionError = String(describing: error)
        }
    }

    func loadMore() async {
        guard let store, canLoadMore else { return }
        let mine = generation
        do {
            let more = try await store.attachments(query, limit: Self.pageSize, offset: items.count)
            guard mine == generation else { return }
            items += more
            canLoadMore = more.count == Self.pageSize
        } catch {
            actionError = String(describing: error)
        }
    }

    /// Selects an attachment and opens its message in the reader ("Show Message").
    func select(_ itemID: String?) async {
        selectedItemID = itemID
        guard let item = selectedItem else { return }
        await browser?.show(item.message, threadID: item.threadID)
    }

    /// A quarantined private copy for Quick Look: the reader's own path (MailBrowser.previewFile).
    func previewFile(for item: AttachmentItem) async throws -> URL {
        guard let browser else { throw CocoaError(.fileNoSuchFile) }
        return try await browser.previewFile(for: item.reference)
    }

    /// The name Save As suggests: the sender's name made safe, with a matching extension.
    func suggestedFileName(for item: AttachmentItem) -> String { MailBrowser.previewName(item.reference) }

    /// Save As: the hash-checked bytes, written whole, then marked as downloaded (quarantine).
    func save(_ item: AttachmentItem, to url: URL) async throws {
        guard let store else { throw CocoaError(.fileNoSuchFile) }
        let data = try await store.attachmentData(item.reference)
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload,
                                       kLSQuarantineAgentNameKey as String: "GitKittie Mail"]
        var marked = url
        try marked.setResourceValues(values)
    }
}
