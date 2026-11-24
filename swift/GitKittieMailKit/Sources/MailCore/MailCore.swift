import Foundation

/// An account as GitKittie Mail knows it: a local, stable id that never changes, whatever
/// the provider does to its own ids. See Architecture.md, Storage and identity.
public struct MailAccountID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init() { self.rawValue = UUID().uuidString.lowercased() }
    public var description: String { rawValue }
}

/// One email address with an optional display name, as written in a header.
public struct MailAddress: Hashable, Codable, Sendable {
    public var name: String?
    public var address: String
    public init(name: String? = nil, address: String) {
        self.name = name
        self.address = address
    }
}
