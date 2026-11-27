import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Where the running Tasks app listens, as its `AgentAccess/connection.json` says.
public struct Connection: Equatable, Sendable {
    public var port: Int
    public var token: String
    /// The copy of Tasks.app that wrote the file: the one to open when nothing listens.
    public var app: String?

    public init(port: Int, token: String, app: String?) {
        self.port = port
        self.token = token
        self.app = app
    }
}

/// Finds the connection file the app writes when Agent Access is on, the same file the
/// stdio bridge (`tasks-mcp.sh`) reads.
public struct ConnectionLocator: Sendable {
    public static let bundleID = "app.hakobs.gitkanban"

    /// The files to look at; the newest one that exists wins.
    public var candidates: [URL]

    public init(candidates: [URL]) { self.candidates = candidates }

    /// `TASKS_CONNECTION` when set; otherwise the App Store (sandboxed) app's container,
    /// then the folder an unsandboxed build writes to.
    public static func standard(environment: [String: String]) -> ConnectionLocator {
        if let path = environment["TASKS_CONNECTION"], !path.isEmpty {
            return ConnectionLocator(candidates: [URL(fileURLWithPath: (path as NSString).expandingTildeInPath)])
        }
        let home = realHome()
        let tail = "Library/Application Support/\(bundleID)/AgentAccess/connection.json"
        return ConnectionLocator(candidates: [
            home.appendingPathComponent("Library/Containers/\(bundleID)/Data/\(tail)"),
            home.appendingPathComponent(tail),
        ])
    }

    /// The person's home folder, also when this tool runs sandboxed (where `NSHomeDirectory`
    /// is the tool's own container).
    public static func realHome() -> URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The newest connection file, read. `nil` when there is none.
    public func load() throws -> Connection? {
        let manager = FileManager.default
        let existing = candidates.filter { manager.fileExists(atPath: $0.path) }
        func modified(_ url: URL) -> Date {
            (try? manager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
        }
        guard let newest = existing.max(by: { modified($0) < modified($1) }) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: newest) } catch {
            throw CLIError.notSetUp("Could not read \(newest.path): \(error.localizedDescription)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let port = (object["port"] as? NSNumber)?.intValue else {
            throw CLIError.notSetUp("\(newest.path) is not a connection file the Tasks app wrote. Turn Agent Access off and on again in Tasks.")
        }
        var token = object["token"] as? String ?? ""
        if token.isEmpty {
            // Older apps kept the token only in the `token` file next to it.
            let file = newest.deletingLastPathComponent().appendingPathComponent("token")
            token = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        return Connection(port: port, token: token, app: object["app"] as? String)
    }
}

/// Opens the Tasks app in the background, as `open -g` does.
public protocol AppLauncher: Sendable {
    /// Open the app at `path` (or, when that is gone, the one with the bundle id). Returns
    /// whether something was opened.
    func open(appAt path: String?) async -> Bool
}

/// Opens the app through Launch Services.
public struct WorkspaceLauncher: AppLauncher {
    public init() {}

    public func open(appAt path: String?) async -> Bool {
        #if canImport(AppKit)
        var url: URL?
        if let path, FileManager.default.fileExists(atPath: path) { url = URL(fileURLWithPath: path) }
        if url == nil { url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ConnectionLocator.bundleID) }
        guard let url else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return true
        } catch {
            return false
        }
        #else
        return false
        #endif
    }
}

/// What a tool call gave back.
public struct ToolResult: Equatable, Sendable {
    /// The tool's text: JSON for every tool the app offers.
    public var text: String
    public var isError: Bool
}

/// Talks to the Tasks app's agent server: JSON-RPC `tools/call` over `POST /mcp` with the
/// bearer token, exactly what the bridge forwards. Opens the app when nothing listens.
public actor TasksClient {
    let locator: ConnectionLocator
    let launcher: AppLauncher?
    let session: URLSession
    /// How long to wait for the app to start listening after opening it.
    let wakeTimeout: TimeInterval
    private var connection: Connection?
    private var nextID = 1

    /// `launcher` nil: never open the app (`TASKS_NO_WAKE`).
    public init(locator: ConnectionLocator, launcher: AppLauncher?, wakeTimeout: TimeInterval = 30) {
        self.locator = locator
        self.launcher = launcher
        self.wakeTimeout = wakeTimeout
        let configuration = URLSessionConfiguration.ephemeral
        // `wait_for_reviews` may hold a call for up to 240 seconds.
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 300
        configuration.connectionProxyDictionary = [:]
        self.session = URLSession(configuration: configuration)
    }

    /// Call one of the app's tools.
    public func call(_ tool: String, _ arguments: [String: JSONValue]) async throws -> ToolResult {
        let params: [String: Any] = ["name": tool, "arguments": arguments.mapValues(\.any)]
        let response = try await send(method: "tools/call", params: params)
        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "The Tasks app refused the call."
            throw CLIError.tool(message)
        }
        guard let result = response["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]] else {
            throw CLIError.unreachable("The Tasks app gave an answer this tool does not understand.")
        }
        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        return ToolResult(text: text, isError: result["isError"] as? Bool ?? false)
    }

    /// Call a tool and decode its JSON answer; a refusal becomes `CLIError.tool`.
    public func callJSON(_ tool: String, _ arguments: [String: JSONValue]) async throws -> Any {
        let result = try await call(tool, arguments)
        if result.isError { throw CLIError.tool(result.text) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(result.text.utf8), options: [.fragmentsAllowed]) else {
            throw CLIError.tool(result.text)
        }
        return object
    }

    // MARK: Transport

    private func currentConnection(reload: Bool) throws -> Connection {
        if !reload, let connection { return connection }
        guard let loaded = try locator.load() else {
            throw CLIError.notSetUp("Tasks has not set up Agent Access on this Mac. Open Tasks, then account menu ▸ Agent Access… ▸ Let agents connect.")
        }
        connection = loaded
        return loaded
    }

    private func requestID() -> Int {
        nextID += 1
        return nextID
    }

    private func send(method: String, params: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": requestID(), "method": method, "params": params])
        var connection = try currentConnection(reload: false)
        do {
            return try await post(body, to: connection)
        } catch let failure as TransportFailure {
            guard failure.isNotListening else { throw failure.cliError }
            // Nothing listens: the app is closed (or moved to another port). Open it and retry.
            connection = try await wake(after: connection)
            do { return try await post(body, to: connection) } catch let again as TransportFailure { throw again.cliError }
        }
    }

    struct TransportFailure: Error {
        var isNotListening: Bool
        var cliError: CLIError
    }

    private func post(_ body: Data, to connection: Connection) async throws -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(connection.port)/mcp") else {
            throw TransportFailure(isNotListening: false, cliError: .notSetUp("The connection file names no usable port."))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet:
                throw TransportFailure(isNotListening: true, cliError: .unreachable("The Tasks app is not listening on port \(connection.port)."))
            case .timedOut:
                throw TransportFailure(isNotListening: false, cliError: .unreachable("The Tasks app did not answer in time."))
            default:
                throw TransportFailure(isNotListening: false, cliError: .unreachable("Could not reach the Tasks app: \(error.localizedDescription)"))
            }
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: break
        case 401:
            throw TransportFailure(isNotListening: false, cliError: .auth(
                "The Tasks app turned the token down. If a new token was made in Agent Access, the connection file should have it; turn Agent Access off and on again in Tasks."))
        default:
            throw TransportFailure(isNotListening: false, cliError: .unreachable("The Tasks app answered HTTP \(status)."))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TransportFailure(isNotListening: false, cliError: .unreachable("The Tasks app gave an answer that is not JSON."))
        }
        return object
    }

    /// Open the app in the background and wait until it answers a ping. The port is read
    /// again each time: the app writes the connection file once it listens.
    private func wake(after stale: Connection) async throws -> Connection {
        guard let launcher else {
            throw CLIError.unreachable("The Tasks app is not running (nothing listens on port \(stale.port)). Open Tasks, or unset TASKS_NO_WAKE to let this tool open it.")
        }
        guard await launcher.open(appAt: stale.app) else {
            throw CLIError.unreachable("The Tasks app is not running and could not be opened. Open Tasks and turn on Agent Access (account menu).")
        }
        let ping = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 0, "method": "ping"])
        let deadline = Date().addingTimeInterval(wakeTimeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 500_000_000)
            guard let connection = try? currentConnection(reload: true) else { continue }
            do {
                _ = try await post(ping, to: connection)
                return connection
            } catch let failure as TransportFailure where failure.isNotListening {
                continue
            }
        }
        throw CLIError.unreachable("Opened Tasks, but it did not start listening within \(Int(wakeTimeout)) seconds. Check that Agent Access is on (account menu ▸ Agent Access…).")
    }
}
