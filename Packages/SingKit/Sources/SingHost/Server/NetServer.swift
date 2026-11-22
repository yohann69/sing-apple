import Foundation
import Network

/// Minimal HTTP/1.1 request and response, enough for the pad API.
public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    /// Token from the Authorization header, or from `?token=` so plain <img> tags in the web remote work.
    public var bearer: String? {
        if let a = headers["authorization"], a.hasPrefix("Bearer ") { return String(a.dropFirst(7)) }
        return query["token"]
    }

    static func parse(_ data: Data) -> (HTTPRequest, needed: Int)? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(first[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        let available = data.count - (bodyStart - data.startIndex)
        let body = available >= length ? data.subdata(in: bodyStart..<(bodyStart + length)) : Data()
        let req = HTTPRequest(method: String(first[0]), path: comps?.path ?? target, query: query, headers: headers, body: body)
        return (req, available >= length ? 0 : length - available)
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    public var extraHeaders: [String: String] = [:]

    public init(status: Int = 200, contentType: String = "application/json; charset=utf-8", body: Data, extraHeaders: [String: String] = [:]) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.extraHeaders = extraHeaders
    }

    var serialized: Data {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// HTTP server on Network.framework. One request per connection keeps it simple and robust.
final class HTTPListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "sing.http")
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse

    init(port: Int, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(port))!)
        self.handler = handler
    }

    func start(onState: @escaping @Sendable (NWListener.State) -> Void) {
        listener.stateUpdateHandler = onState
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 4 << 20 || error != nil { conn.cancel(); return }
            if let (req, needed) = HTTPRequest.parse(buf), needed == 0 {
                let handler = self.handler
                Task {
                    let resp = await handler(req)
                    conn.send(content: resp.serialized, completion: .contentProcessed { _ in conn.cancel() })
                }
            } else if done {
                conn.cancel()
            } else {
                self.read(conn, buffer: buf)
            }
        }
    }
}

/// WebSocket server on Network.framework.
final class WebSocketListener: @unchecked Sendable {
    final class Client: @unchecked Sendable {
        let id = UUID()
        let connection: NWConnection
        init(_ c: NWConnection) { connection = c }

        func send(_ text: String) {
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
            connection.send(content: Data(text.utf8), contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in })
        }

        func close() { connection.cancel() }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "sing.ws")
    var onOpen: (@Sendable (Client) -> Void)?
    var onText: (@Sendable (Client, String) -> Void)?
    var onClose: (@Sendable (Client) -> Void)?

    init(port: Int) throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 1 << 20
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: UInt16(port))!)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            let client = Client(conn)
            conn.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.onOpen?(client)
                case .failed, .cancelled: self?.onClose?(client)
                default: break
                }
            }
            conn.start(queue: self.queue)
            self.receive(client)
        }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    private func receive(_ client: Client) {
        client.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if error != nil { client.close(); return }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                if meta.opcode == .close { client.close(); return }
                if meta.opcode == .text, let data { self.onText?(client, String(decoding: data, as: UTF8.self)) }
            }
            self.receive(client)
        }
    }
}
