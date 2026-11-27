import Foundation
import Network
import TasksAgentTools

// A small Model Context Protocol server over HTTP ("Streamable HTTP" with plain JSON
// answers), so an agent can use the app's boards as tools. Loopback only, and every
// request needs the bearer token. The protocol part (`MCPDispatcher`) knows nothing about
// boards or sockets; the tools are handed in.

/// JSON-RPC for MCP: `initialize`, `ping`, `tools/list`, `tools/call`.
public struct MCPDispatcher: Sendable {
    public static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    let serverName: String
    let serverVersion: String
    let instructions: String
    let tools: [MCPTool]
    /// Runs a tool: arguments in (a JSON object as data), result out (JSON text). Throws
    /// with a message the agent can act on.
    let call: @Sendable (_ name: String, _ arguments: Data) async throws -> String

    public init(serverName: String, serverVersion: String, instructions: String, tools: [MCPTool],
                call: @escaping @Sendable (_ name: String, _ arguments: Data) async throws -> String) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.instructions = instructions
        self.tools = tools
        self.call = call
    }

    /// The answer to one JSON-RPC message, or `nil` for a notification (nothing to answer).
    public func respond(to body: Data) async -> Data? {
        guard let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return Self.error(id: NSNull(), code: -32700, message: "Parse error: the body is not a JSON object.")
        }
        guard let id = message["id"], !(id is NSNull) else { return nil }
        guard let method = message["method"] as? String else {
            return Self.error(id: id, code: -32600, message: "Invalid request: no method.")
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let wanted = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(wanted) ? wanted : Self.supportedVersions[0]
            return Self.result(id: id, [
                "protocolVersion": version,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": serverName, "version": serverVersion],
                "instructions": instructions,
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": tools.map { tool -> [String: Any] in
                let schema = (try? JSONSerialization.jsonObject(with: Data(tool.inputSchema.utf8))) ?? ["type": "object"]
                return ["name": tool.name, "description": tool.description, "inputSchema": schema]
            }])
        case "tools/call":
            guard let name = params["name"] as? String, tools.contains(where: { $0.name == name }) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(params["name"] as? String ?? "")")
            }
            let arguments = (try? JSONSerialization.data(withJSONObject: params["arguments"] as? [String: Any] ?? [:])) ?? Data("{}".utf8)
            do {
                let text = try await call(name, arguments)
                return Self.result(id: id, ["content": [["type": "text", "text": text]], "isError": false])
            } catch {
                // A tool that could not do its job is a result the agent reads, not a protocol error.
                return Self.result(id: id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true])
            }
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private static func result(id: Any, _ result: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result])) ?? Data()
    }

    private static func error(id: Any, code: Int, message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])) ?? Data()
    }
}

/// An HTTP request as far as this server reads one.
struct MCPHTTPRequest {
    var method = ""
    var path = ""
    var headers: [String: String] = [:]
    var body = Data()

    /// Parse a complete request out of `buffer`; `nil` while more bytes are needed.
    /// Throws for a request that will never be valid.
    static func parse(_ buffer: Data, maxBody: Int) throws -> MCPHTTPRequest? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 64_000 { throw MCPHTTPError(status: 431, reason: "Request Header Fields Too Large") }
            return nil
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            throw MCPHTTPError(status: 400, reason: "Bad Request")
        }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { throw MCPHTTPError(status: 400, reason: "Bad Request") }
        var request = MCPHTTPRequest(method: String(start[0]).uppercased(), path: String(start[1]))
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            request.headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if request.headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            throw MCPHTTPError(status: 411, reason: "Length Required")
        }
        let length = Int(request.headers["content-length"] ?? "0") ?? 0
        guard length >= 0, length <= maxBody else { throw MCPHTTPError(status: 413, reason: "Payload Too Large") }
        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return nil }
        request.body = Data(buffer[bodyStart..<(bodyStart + length)])
        return request
    }
}

struct MCPHTTPError: Error {
    let status: Int
    let reason: String
}

/// The listener: `POST /mcp` on 127.0.0.1, bearer token required.
public actor MCPHTTPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "app.hakobs.gitkanban.mcp")
    private let token: String
    private let dispatcher: MCPDispatcher
    /// Attachments arrive as base64 inside the JSON, so this has to hold a screenshot.
    static let maxBody = 24_000_000

    public init(token: String, dispatcher: MCPDispatcher) {
        self.token = token
        self.dispatcher = dispatcher
    }

    /// Start listening. `port` 0 lets the system pick one. Returns the port in use.
    public func start(port: UInt16) async throws -> UInt16 {
        stop()
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Loopback only: never reachable from another machine.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        let listener = try NWListener(using: parameters)
        let (token, dispatcher, queue) = (token, dispatcher, queue)
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            MCPHTTPConnection.read(connection, buffer: Data(), token: token, dispatcher: dispatcher)
        }
        let (states, continuation) = AsyncStream<NWListener.State>.makeStream()
        listener.stateUpdateHandler = { continuation.yield($0) }
        listener.start(queue: queue)
        for await state in states {
            switch state {
            case .ready:
                self.listener = listener
                return listener.port?.rawValue ?? port
            case .failed(let error):
                listener.cancel()
                throw error
            case .cancelled:
                throw CancellationError()
            default:
                continue
            }
        }
        throw CancellationError()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// One HTTP exchange on a connection: read a request, answer it, close.
enum MCPHTTPConnection {
    static func read(_ connection: NWConnection, buffer: Data, token: String, dispatcher: MCPDispatcher) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            do {
                if let request = try MCPHTTPRequest.parse(buffer, maxBody: MCPHTTPServer.maxBody) {
                    Task { await answer(request, on: connection, token: token, dispatcher: dispatcher) }
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    read(connection, buffer: buffer, token: token, dispatcher: dispatcher)
                }
            } catch let failure as MCPHTTPError {
                send(status: failure.status, reason: failure.reason, body: nil, on: connection)
            } catch {
                connection.cancel()
            }
        }
    }

    static func answer(_ request: MCPHTTPRequest, on connection: NWConnection, token: String, dispatcher: MCPDispatcher) async {
        // A browser page must never reach this: a request that names a web origin is refused
        // (DNS-rebinding protection). Agents send no Origin header.
        if let origin = request.headers["origin"], !origin.isEmpty {
            return send(status: 403, reason: "Forbidden", body: nil, on: connection)
        }
        guard request.path == "/mcp" || request.path.hasPrefix("/mcp?") else {
            return send(status: 404, reason: "Not Found", body: nil, on: connection)
        }
        guard sameToken(request.headers["authorization"] ?? "", "Bearer \(token)") else {
            return send(status: 401, reason: "Unauthorized", body: Data(#"{"error":"missing or wrong bearer token"}"#.utf8), on: connection)
        }
        guard request.method == "POST" else {
            // No server-to-client stream is offered, which the protocol allows.
            return send(status: 405, reason: "Method Not Allowed", body: nil, on: connection, extra: ["Allow": "POST"])
        }
        if let response = await dispatcher.respond(to: request.body) {
            send(status: 200, reason: "OK", body: response, on: connection)
        } else {
            send(status: 202, reason: "Accepted", body: nil, on: connection)
        }
    }

    /// Compared in constant time for equal lengths.
    static func sameToken(_ given: String, _ expected: String) -> Bool {
        let a = Array(given.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }

    static func send(status: Int, reason: String, body: Data?, on connection: NWConnection, extra: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body?.count ?? 0)\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        for (name, value) in extra { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
}
