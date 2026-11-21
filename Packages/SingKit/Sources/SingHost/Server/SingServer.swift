import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import SingCore

public struct PadIdentity: Sendable, Hashable {
    public var padID: String
    public var name: String
    public var role: PadRole
}

/// What the server needs from the host. Implemented by `HostController` on the main actor.
public protocol HostAPI: AnyObject, Sendable {
    func serverInfo() async -> ServerInfo
    func pair(_ request: PairRequest) async throws -> PairResponse
    func authenticate(token: String) async -> PadIdentity?
    func search(_ q: String, filters: SearchFilters) async throws -> SearchResponse
    func artwork(songID: SongID) async -> Data?
    func lyrics(songID: SongID) async -> Lyrics?
    func singers() async -> [Singer]
    func createSinger(name: String, emoji: String?, pad: PadIdentity) async throws -> Singer
    func stats(_ period: StatsPeriod) async throws -> StatsResponse
    func singerStats(_ id: SingerID) async throws -> SingerStats?
    func suggestions(singerID: SingerID?) async throws -> [Suggestion]
    func liveState() async -> LiveState
    func handle(_ message: ClientMessage, from pad: PadIdentity) async throws
    func padConnected(_ pad: PadIdentity, connected: Bool) async
}

public struct NewSinger: Codable, Sendable {
    public var name: String
    public var emoji: String?

    public init(name: String, emoji: String?) {
        self.name = name
        self.emoji = emoji
    }
}

actor ConnectionHub {
    struct Client {
        var pad: PadIdentity
        var outbound: WebSocketOutboundWriter
    }

    private var clients: [UUID: Client] = [:]

    func add(_ id: UUID, _ c: Client) { clients[id] = c }
    func remove(_ id: UUID) { clients[id] = nil }
    var count: Int { clients.count }
    var pads: [PadIdentity] { clients.values.map(\.pad) }

    func send(_ message: ServerMessage, to padID: String? = nil) async {
        guard let data = try? SingProtocol.encoder().encode(message) else { return }
        let text = String(decoding: data, as: UTF8.self)
        for (id, c) in clients where padID == nil || c.pad.padID == padID {
            do { try await c.outbound.write(.text(text)) } catch { clients[id] = nil }
        }
    }
}

public final class SingServer: Sendable {
    let api: any HostAPI
    let hub = ConnectionHub()
    public let port: Int

    public init(api: any HostAPI, port: Int = SingProtocol.defaultPort) {
        self.api = api
        self.port = port
    }

    public func broadcast(_ message: ServerMessage, to padID: String? = nil) async {
        await hub.send(message, to: padID)
    }

    public func connectedPads() async -> [PadIdentity] { await hub.pads }

    public func run() async throws {
        let router = Router(context: BasicRequestContext.self)
        let api = self.api
        router.add(middleware: ErrorMiddleware())

        router.get("v1/info") { _, _ in try json(await api.serverInfo()) }
        router.post("v1/pair") { req, ctx in
            let body = try await req.decode(as: PairRequest.self, context: ctx)
            return try json(try await api.pair(body))
        }

        let authed = router.group("v1").add(middleware: AuthMiddleware(api: api))
        authed.get("state") { _, _ in try json(await api.liveState()) }
        authed.get("songs") { req, _ in
            let q = req.uri.queryParameters
            let filters = SearchFilters(
                readyOnly: q["ready"] == "1", duetOnly: q["duet"] == "1",
                decade: q["decade"].flatMap { Int(String($0)) }, genre: q["genre"].map(String.init), language: q["language"].map(String.init)
            )
            return try json(try await api.search(q["q"].map(String.init) ?? "", filters: filters))
        }
        authed.get("songs/:id/artwork") { req, ctx in
            guard let id = ctx.parameters.get("id", as: Int64.self), let data = await api.artwork(songID: id) else { throw HTTPError(.notFound) }
            var headers = HTTPFields()
            headers[.contentType] = "image/jpeg"
            headers[.cacheControl] = "max-age=86400"
            return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }
        authed.get("songs/:id/lyrics") { _, ctx in
            guard let id = ctx.parameters.get("id", as: Int64.self), let l = await api.lyrics(songID: id) else { throw HTTPError(.notFound) }
            return try json(l)
        }
        authed.get("singers") { _, _ in try json(await api.singers()) }
        authed.post("singers") { req, ctx in
            let body = try await req.decode(as: NewSinger.self, context: ctx)
            guard let token = bearer(req), let pad = await api.authenticate(token: token) else { throw HTTPError(.unauthorized) }
            return try json(try await api.createSinger(name: body.name, emoji: body.emoji, pad: pad))
        }
        authed.get("stats") { req, _ in
            let p = req.uri.queryParameters["period"].flatMap { StatsPeriod(rawValue: String($0)) } ?? .tonight
            return try json(try await api.stats(p))
        }
        authed.get("stats/singers/:id") { _, ctx in
            guard let id = ctx.parameters.get("id", as: Int64.self), let s = try await api.singerStats(id) else { throw HTTPError(.notFound) }
            return try json(s)
        }
        authed.get("suggestions") { req, _ in
            let singer = req.uri.queryParameters["singer"].flatMap { Int64(String($0)) }
            return try json(try await api.suggestions(singerID: singer))
        }

        let wsRouter = Router(context: BasicWebSocketRequestContext.self)
        let hub = self.hub
        wsRouter.ws("v1/live") { req, _ in
            guard let token = req.uri.queryParameters["token"].map(String.init), await api.authenticate(token: token) != nil else { return .dontUpgrade }
            return .upgrade([:])
        } onUpgrade: { inbound, outbound, ctx in
            guard let token = ctx.request.uri.queryParameters["token"].map(String.init), let pad = await api.authenticate(token: token) else { return }
            let id = UUID()
            await hub.add(id, .init(pad: pad, outbound: outbound))
            await api.padConnected(pad, connected: true)
            defer { Task { await hub.remove(id); await api.padConnected(pad, connected: false) } }
            let enc = SingProtocol.encoder()
            if let hello = try? enc.encode(ServerMessage.hello(.init(server: await api.serverInfo(), role: pad.role, padID: pad.padID))) {
                try await outbound.write(.text(String(decoding: hello, as: UTF8.self)))
            }
            if let state = try? enc.encode(ServerMessage.state(await api.liveState())) {
                try await outbound.write(.text(String(decoding: state, as: UTF8.self)))
            }
            for try await message in inbound.messages(maxSize: 1 << 20) {
                guard case .text(let text) = message,
                      let msg = try? SingProtocol.decoder().decode(ClientMessage.self, from: Data(text.utf8)) else { continue }
                do {
                    try await api.handle(msg, from: pad)
                } catch {
                    let body = ErrorBody(code: "rejected", message: (error as? LocalizedError)?.errorDescription ?? "\(error)")
                    if let data = try? enc.encode(ServerMessage.error(body)) {
                        try? await outbound.write(.text(String(decoding: data, as: UTF8.self)))
                    }
                }
            }
        }

        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: wsRouter),
            configuration: .init(address: .hostname("0.0.0.0", port: port), serverName: "Sing")
        )
        try await app.runService(gracefulShutdownSignals: [])
    }
}

func json<T: Encodable>(_ value: T) throws -> Response {
    let data = try SingProtocol.encoder().encode(value)
    var headers = HTTPFields()
    headers[.contentType] = "application/json; charset=utf-8"
    return Response(status: .ok, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
}

func bearer(_ req: Request) -> String? {
    guard let auth = req.headers[.authorization], auth.hasPrefix("Bearer ") else { return nil }
    return String(auth.dropFirst(7))
}

struct AuthMiddleware<Context: RequestContext>: RouterMiddleware {
    let api: any HostAPI

    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        guard let token = bearer(request), await api.authenticate(token: token) != nil else {
            throw HTTPError(.unauthorized, message: "Pair this device again")
        }
        return try await next(request, context)
    }
}

struct ErrorMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        do {
            return try await next(request, context)
        } catch let e as ErrorBody {
            var r = try json(e)
            r.status = .badRequest
            return r
        } catch let e as QueueError {
            var r = try json(ErrorBody(code: "queue", message: e.errorDescription ?? ""))
            r.status = .badRequest
            return r
        }
    }
}
