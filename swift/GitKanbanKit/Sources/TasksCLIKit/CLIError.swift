import Foundation
import TasksAgentTools

/// Why a command failed, and the exit code that says so.
public enum CLIError: Error, Equatable, LocalizedError {
    /// The command line itself is wrong (unknown command or option, a missing value).
    case usage(String)
    /// The app answered, and refused or could not do it: unknown card, board or lane, a
    /// field the board does not allow, someone else's claim.
    case tool(String)
    /// Tasks is not running and could not be opened, or it does not answer.
    case unreachable(String)
    /// The app turned the token down.
    case auth(String)
    /// Agent Access was never turned on on this Mac: there is nothing to connect to.
    case notSetUp(String)

    /// The exit code and its meaning, from the table the guide prints.
    public var status: ExitStatus {
        switch self {
        case .tool: .refused
        case .usage: .usage
        case .unreachable: .unreachable
        case .auth: .auth
        case .notSetUp: .notSetUp
        }
    }

    public var exitCode: Int32 { status.rawValue }

    public var message: String {
        switch self {
        case .usage(let text), .tool(let text), .unreachable(let text), .auth(let text), .notSetUp(let text): text
        }
    }

    public var kind: String { status.kind }

    public var errorDescription: String? { message }
}
