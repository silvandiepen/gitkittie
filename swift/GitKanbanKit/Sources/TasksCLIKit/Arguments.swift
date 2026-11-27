import Foundation

/// One option a command takes.
public struct OptionSpec: Sendable {
    public let name: String
    public let short: Character?
    /// What the value is called in help (`<lane>`); nil for a flag.
    public let value: String?
    public let help: String

    public init(_ name: String, short: Character? = nil, value: String? = nil, _ help: String) {
        self.name = name
        self.short = short
        self.value = value
        self.help = help
    }

    var takesValue: Bool { value != nil }
}

/// A command line split into options and positionals.
public struct ParsedArguments: Equatable, Sendable {
    /// Every value given for an option, in order (an option given twice has two).
    public var values: [String: [String]] = [:]
    public var flags: Set<String> = []
    public var positionals: [String] = []

    public func value(_ name: String) -> String? { values[name]?.last }
    public func has(_ name: String) -> Bool { flags.contains(name) }
}

extension ParsedArguments {
    /// Split `arguments` with the options `specs` allows. `--name value`, `--name=value`,
    /// `-x value`; `--` ends the options; a lone `-` is a positional (standard input).
    static func parse(_ arguments: [String], specs: [OptionSpec], command: String) throws -> ParsedArguments {
        var parsed = ParsedArguments()
        var index = 0
        var optionsEnded = false
        func spec(named name: String) throws -> OptionSpec {
            if let found = specs.first(where: { $0.name == name }) { return found }
            throw CLIError.usage("\(command): unknown option --\(name). See `tasks \(command) --help`.")
        }
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if optionsEnded || argument == "-" || !argument.hasPrefix("-") || Self.isNegativeNumber(argument) {
                parsed.positionals.append(argument)
                continue
            }
            if argument == "--" { optionsEnded = true; continue }
            let option: OptionSpec
            var inline: String?
            if argument.hasPrefix("--") {
                let body = argument.dropFirst(2)
                if let equals = body.firstIndex(of: "=") {
                    option = try spec(named: String(body[..<equals]))
                    inline = String(body[body.index(after: equals)...])
                } else {
                    option = try spec(named: String(body))
                }
            } else {
                let letters = Array(argument.dropFirst())
                guard letters.count == 1, let found = specs.first(where: { $0.short == letters[0] }) else {
                    throw CLIError.usage("\(command): unknown option \(argument). See `tasks \(command) --help`.")
                }
                option = found
            }
            if option.takesValue {
                let value: String
                if let inline { value = inline } else {
                    guard index < arguments.count else { throw CLIError.usage("\(command): --\(option.name) needs a value (\(option.value ?? "")).") }
                    value = arguments[index]
                    index += 1
                }
                parsed.values[option.name, default: []].append(value)
            } else {
                if inline != nil { throw CLIError.usage("\(command): --\(option.name) takes no value.") }
                parsed.flags.insert(option.name)
            }
        }
        return parsed
    }

    private static func isNegativeNumber(_ text: String) -> Bool {
        text.count > 1 && text.hasPrefix("-") && Double(text) != nil
    }
}
