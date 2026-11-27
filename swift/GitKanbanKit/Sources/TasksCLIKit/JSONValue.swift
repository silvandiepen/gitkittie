import Foundation

/// A JSON value: what a command turns into tool arguments, comparable in tests.
public enum JSONValue: Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    /// From what `JSONSerialization` gives back.
    public init?(any value: Any) {
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { self = .bool(number.boolValue) } else { self = .number(number.doubleValue) }
        case let string as String: self = .string(string)
        case let array as [Any]:
            var out: [JSONValue] = []
            for element in array {
                guard let converted = JSONValue(any: element) else { return nil }
                out.append(converted)
            }
            self = .array(out)
        case let object as [String: Any]:
            var out: [String: JSONValue] = [:]
            for (key, element) in object {
                guard let converted = JSONValue(any: element) else { return nil }
                out[key] = converted
            }
            self = .object(out)
        default: return nil
        }
    }

    /// For `JSONSerialization`. Whole numbers go out as integers (`"hours": 2`, not `2.0`).
    public var any: Any {
        switch self {
        case .string(let value): return value
        case .number(let value):
            if value.rounded() == value, abs(value) < 9_007_199_254_740_992 { return Int(value) }
            return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map(\.any)
        case .object(let values): return values.mapValues(\.any)
        }
    }

    /// Parse JSON text (any value, not only an object).
    public static func parse(_ text: String) throws -> JSONValue {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        guard let value = JSONValue(any: object) else { throw CLIError.usage("That is not JSON this tool can send.") }
        return value
    }

    public var string: String? { if case .string(let value) = self { return value }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// The arguments as a JSON object, keys sorted (stable for tests and logs).
    func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: mapValues(\.any), options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
