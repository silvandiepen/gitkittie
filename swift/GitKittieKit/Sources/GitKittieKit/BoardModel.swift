import Foundation

/// Swift mirror of `@gitkittie/gitkanban-core`'s board schema. The TypeScript package
/// is the source of truth; these types must stay in step with it. See
/// `project-assets/Tasks/README.md` for the canonical contract.

public struct Lane: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Directory name under the project (e.g. "1. To do"). Must exist on disk.
    public var folder: String
    /// The card `status` value this lane holds.
    public var status: String
    public var terminal: Bool?
    /// A backlog lane holds not-yet-scheduled work; it renders apart from the
    /// pipeline lanes (below the board, not as a pipeline column).
    public var backlog: Bool?

    public init(id: String, name: String, folder: String, status: String, terminal: Bool? = nil, backlog: Bool? = nil) {
        self.id = id
        self.name = name
        self.folder = folder
        self.status = status
        self.terminal = terminal
        self.backlog = backlog
    }

    /// Whether this lane is a backlog: either flagged `backlog: true` in config, or
    /// named `backlog` by convention (id or status).
    public var isBacklog: Bool {
        backlog == true || status == "backlog" || id == "backlog"
    }
}

public struct User: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var kind: String?
    public var github: String?
    public var role: String?

    public init(id: String, name: String? = nil, kind: String? = nil, github: String? = nil, role: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.github = github
        self.role = role
    }
}

public struct Epic: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var description: String?
    public var project: String?

    public init(id: String, name: String? = nil, description: String? = nil, project: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.project = project
    }
}

public struct Priority: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var description: String?

    public init(id: String, name: String? = nil, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// Where a card's fields come from: YAML frontmatter (default) or a named markdown
/// body section (the legacy `audit/tasks` format).
public enum FieldSource: Equatable, Sendable {
    case frontmatter
    case bodySection(section: String?, map: [String: String])
}

/// Root board configuration.
public struct BoardConfig: Equatable, Sendable {
    public var lanes: [Lane]
    public var users: [User]
    public var epics: [Epic]
    public var priorities: [Priority]
    public var types: [String]
    public var tags: [String]
    public var fieldSource: FieldSource?
    /// `review_path`: where review requests live, relative to each project folder (see `Review`).
    public var reviewPath: String?

    public init(
        lanes: [Lane] = [],
        users: [User] = [],
        epics: [Epic] = [],
        priorities: [Priority] = [],
        types: [String] = [],
        tags: [String] = [],
        fieldSource: FieldSource? = nil,
        reviewPath: String? = nil
    ) {
        self.lanes = lanes
        self.users = users
        self.epics = epics
        self.priorities = priorities
        self.types = types
        self.tags = tags
        self.fieldSource = fieldSource
        self.reviewPath = reviewPath
    }
}

/// Per-project configuration overlaid on the root.
public struct ProjectConfig: Equatable, Sendable {
    public var project: String?
    public var lanes: [Lane]?
    public var users: [User]?
    public var epics: [Epic]?
    public var priorities: [Priority]?
    public var types: [String]?
    public var tags: [String]?
    public var fieldSource: FieldSource?
    /// `review_path`: where review requests live, relative to each project folder (see `Review`).
    public var reviewPath: String?
    /// `icon`: the board's SF Symbol name, and `color`: one of `BoardAppearance.colors`.
    /// How the board looks in every app that lists it; kept in the board's own README.
    public var icon: String?
    public var color: String?

    public init(
        project: String? = nil,
        lanes: [Lane]? = nil,
        users: [User]? = nil,
        epics: [Epic]? = nil,
        priorities: [Priority]? = nil,
        types: [String]? = nil,
        tags: [String]? = nil,
        fieldSource: FieldSource? = nil,
        reviewPath: String? = nil,
        icon: String? = nil,
        color: String? = nil
    ) {
        self.icon = icon
        self.color = color
        self.project = project
        self.lanes = lanes
        self.users = users
        self.epics = epics
        self.priorities = priorities
        self.types = types
        self.tags = tags
        self.fieldSource = fieldSource
        self.reviewPath = reviewPath
    }
}

/// The resolved configuration a board is rendered from.
public struct EffectiveConfig: Equatable, Sendable {
    public var project: String?
    public var lanes: [Lane]
    public var users: [User]
    public var epics: [Epic]
    public var priorities: [Priority]
    public var types: [String]
    public var tags: [String]
    public var fieldSource: FieldSource?
    /// `review_path`: where review requests live, relative to each project folder (see `Review`).
    public var reviewPath: String?

    public init(
        project: String? = nil,
        lanes: [Lane] = [],
        users: [User] = [],
        epics: [Epic] = [],
        priorities: [Priority] = [],
        types: [String] = [],
        tags: [String] = [],
        fieldSource: FieldSource? = nil,
        reviewPath: String? = nil
    ) {
        self.project = project
        self.lanes = lanes
        self.users = users
        self.epics = epics
        self.priorities = priorities
        self.types = types
        self.tags = tags
        self.fieldSource = fieldSource
        self.reviewPath = reviewPath
    }
}

/// A product a board works on: a board can cover several (GitKittie has Folder, Tasks and
/// Bud). Tasks name the product they are for, the board can be filtered on it, and a
/// product may number its tasks with its own prefix.
public struct BoardProduct: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// When set, a new task for this product gets `<PREFIX>-<number>` as its id.
    public var prefix: String?
    public var icon: String?
    public var color: String?

    public init(id: String, name: String, prefix: String? = nil, icon: String? = nil, color: String? = nil) {
        self.id = id; self.name = name; self.prefix = prefix; self.icon = icon; self.color = color
    }

    /// `GitKittie Tasks` → `gitkittie-tasks`.
    public static func id(for name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { text, character in if !(character == "-" && text.hasSuffix("-")) { text.append(character) } }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// A prefix as ids need it: capitals and digits, starting with a letter. Nil when nothing is left.
    public static func cleanPrefix(_ raw: String?) -> String? {
        let kept = (raw ?? "").uppercased().filter { $0.isLetter || $0.isNumber }
        guard let first = kept.first, first.isLetter else { return nil }
        return String(kept.prefix(12))
    }
}

/// The fields GitKanban models on a card. Unknown frontmatter is preserved on `Card`.
public struct CardFields: Equatable, Sendable {
    public var id: String
    public var title: String
    public var project: String
    public var status: String
    public var priority: String?
    public var type: String?
    public var epic: String?
    /// The product of the board this card belongs to (`product:`), by its id.
    public var product: String?
    public var assignee: String?
    public var order: String?
    /// `updated_at`, ISO-8601 as written.
    public var updatedAt: String?
    /// `read_at` / `read_by`: when the reviewer last read the card (see `BoardProgress`).
    public var readAt: String?
    public var readBy: String?
    /// `tags`: the task's labels.
    public var tags: [String] = []
    /// `due`: the day the task is due, as `yyyy-MM-dd`.
    public var due: String?
    /// `created_at`, ISO-8601 as written.
    public var createdAt: String?

    public init(
        id: String = "", title: String = "", project: String = "", status: String = "",
        priority: String? = nil, type: String? = nil, epic: String? = nil,
        assignee: String? = nil, order: String? = nil,
        updatedAt: String? = nil, readAt: String? = nil, readBy: String? = nil,
        product: String? = nil
    ) {
        self.product = product
        self.updatedAt = updatedAt
        self.readAt = readAt
        self.readBy = readBy
        self.id = id
        self.title = title
        self.project = project
        self.status = status
        self.priority = priority
        self.type = type
        self.epic = epic
        self.assignee = assignee
        self.order = order
    }
}

/// A card resolved for display: its modelled fields plus the markdown body.
/// (Full frontmatter round-tripping for the editor is a later ticket; the board
/// renders from `fields`.)
public struct Card: Equatable, Sendable, Identifiable {
    public var fields: CardFields
    public var body: String
    /// File name on disk, when loaded from a folder.
    public var fileName: String?

    public var id: String { !fields.id.isEmpty ? fields.id : (fileName ?? fields.title) }

    public init(fields: CardFields, body: String, fileName: String? = nil) {
        self.fields = fields
        self.body = body
        self.fileName = fileName
    }
}

/// A board column: a lane and the cards currently in it, in display order.
public struct Column: Equatable, Sendable, Identifiable {
    public var lane: Lane
    public var cards: [Card]
    public var id: String { lane.id }

    public init(lane: Lane, cards: [Card]) {
        self.lane = lane
        self.cards = cards
    }
}

/// The icons and colours a board can be given (`icon:` / `color:` in its README).
public enum BoardAppearance {
    public static let defaultIcon = "square.stack.3d.up.fill"
    /// Colour names as written in the README; the apps map them to system colours.
    public static let colors = ["blue", "indigo", "purple", "pink", "red", "orange", "yellow", "green", "mint", "teal", "brown", "gray"]
    /// SF Symbols offered in the picker. Any other symbol name in a README still shows.
    public static let icons = [
        "square.stack.3d.up.fill", "checklist", "list.bullet.rectangle.fill", "tray.full.fill", "folder.fill", "doc.text.fill",
        "hammer.fill", "wrench.and.screwdriver.fill", "terminal.fill", "chevron.left.forwardslash.chevron.right", "cpu.fill", "ladybug.fill",
        "iphone", "macbook", "globe", "cloud.fill", "server.rack", "shippingbox.fill",
        "paintbrush.fill", "paintpalette.fill", "photo.fill", "camera.fill", "film.fill", "music.note",
        "gamecontroller.fill", "book.fill", "graduationcap.fill", "pencil.and.outline", "megaphone.fill", "envelope.fill",
        "cart.fill", "creditcard.fill", "chart.bar.fill", "banknote.fill", "briefcase.fill", "building.2.fill",
        "house.fill", "leaf.fill", "heart.fill", "star.fill", "bolt.fill", "flame.fill",
        "pawprint.fill", "fork.knife", "airplane", "car.fill", "map.fill", "sparkles",
    ]
}
