import Foundation
import GitKittieKit

/// Every SF Symbol this device has, with the system's search words, for the board icon
/// picker. The system ships the list as property lists next to the symbols themselves;
/// when they cannot be read, the catalogue is the short built-in list.
public struct SymbolCatalog: Sendable {
    public struct Symbol: Sendable, Equatable, Identifiable {
        public let name: String
        /// Lowercased name and search words, matched against the filter.
        let haystack: String
        public var id: String { name }
    }

    public let symbols: [Symbol]

    /// Script-specific variants (`character.ar`, `1.circle.hi`) are left out: they are the
    /// same picture in another script and triple the list.
    static let scriptSuffixes: Set<String> = [
        "ar", "hi", "he", "ja", "ko", "th", "zh", "rtl", "bn", "gu", "kn", "ml", "mr", "or", "pa",
        "ta", "te", "my", "km", "mni", "sat", "si", "el", "ru", "vi", "en",
    ]

    public init(names: [String], order: [String] = [], search: [String: [String]] = [:], first: [String] = BoardAppearance.icons) {
        let known = Set(names)
        var seen = Set<String>()
        var ordered: [String] = []
        // The built-in suggestions lead, then the system's own order, then anything left.
        for name in first + order + names.sorted() where known.contains(name) || first.contains(name) {
            guard seen.insert(name).inserted else { continue }
            if let last = name.split(separator: ".").last, name.contains("."), Self.scriptSuffixes.contains(String(last)) { continue }
            ordered.append(name)
        }
        symbols = ordered.map { name in
            let words = [name.replacingOccurrences(of: ".", with: " ")] + (search[name] ?? [])
            return Symbol(name: name, haystack: words.joined(separator: " ").lowercased())
        }
    }

    /// The symbols whose name or search words contain every word of `query`; all of them
    /// for an empty query.
    public func matching(_ query: String) -> [Symbol] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "." }).map(String.init)
        guard !words.isEmpty else { return symbols }
        return symbols.filter { symbol in words.allSatisfy { symbol.haystack.contains($0) } }
    }

    /// The catalogue of this device, read once.
    public static let system: SymbolCatalog = {
        let folder = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")
        func plist(_ name: String) -> Any? {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
            return try? PropertyListSerialization.propertyList(from: data, format: nil)
        }
        guard let availability = plist("name_availability.plist") as? [String: Any],
              let names = (availability["symbols"] as? [String: Any])?.keys, !names.isEmpty else {
            return SymbolCatalog(names: BoardAppearance.icons)
        }
        return SymbolCatalog(names: Array(names),
                             order: plist("symbol_order.plist") as? [String] ?? [],
                             search: plist("symbol_search.plist") as? [String: [String]] ?? [:])
    }()
}
