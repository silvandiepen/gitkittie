import Foundation
import Network

/// A real HTTP/1.1 server on 127.0.0.1 that records every request it receives (method, path,
/// headers, body) and answers each path as scripted. Used to prove which unsubscribe endpoints
/// are contacted, when, and how (GKM-020). Shared with the app's tests (project.yml).
@MainActor
final class RecordingHTTPServer {
    struct Request: Equatable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: String

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body = ""
    }

    private let listener: NWListener
    private(set) var requests: [Request] = []
    /// Connections opened, whether or not a full request arrived.
    private(set) var connections = 0
    private(set) var port: UInt16 = 0
    private var isReady = false
    /// Scripted answers by path; anything else gets 200.
    var responses: [String: Response] = [:]

    private init(listener: NWListener) { self.listener = listener }

    static func start() async throws -> RecordingHTTPServer {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let server = RecordingHTTPServer(listener: try NWListener(using: parameters))
        server.listener.newConnectionHandler = { [weak server] connection in
            MainActor.assumeIsolated { server?.accept(connection) }
        }
        server.listener.stateUpdateHandler = { [weak server] state in
            MainActor.assumeIsolated { if case .ready = state { server?.isReady = true } }
        }
        server.listener.start(queue: .main)
        for _ in 0..<500 where !server.isReady { try await Task.sleep(for: .milliseconds(10)) }
        server.port = server.listener.port?.rawValue ?? 0
        guard server.isReady, server.port != 0 else { throw URLError(.cannotConnectToHost) }
        return server
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    func url(_ path: String) -> URL { URL(string: baseURL + path)! }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connections += 1
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
            MainActor.assumeIsolated {
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = Self.parse(buffer) {
                    self.requests.append(request)
                    self.answer(request, on: connection)
                } else if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(connection, buffer: buffer)
                }
            }
        }
    }

    private func answer(_ request: Request, on connection: NWConnection) {
        let response = responses[request.path] ?? Response(status: 200)
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.utf8.count)"
        headers["Connection"] = "close"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data((head + response.body).utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A complete request (headers and a body of Content-Length bytes), or nil while incomplete.
    private static func parse(_ data: Data) -> Request? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = headers.first { $0.key.lowercased() == "content-length" }.flatMap { Int($0.value) } ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(start[0]), path: String(start[1]), headers: headers,
                       body: String(decoding: body.prefix(length), as: UTF8.self))
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 302: "Found"
        case 307: "Temporary Redirect"
        case 308: "Permanent Redirect"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        default: "Status"
        }
    }
}
