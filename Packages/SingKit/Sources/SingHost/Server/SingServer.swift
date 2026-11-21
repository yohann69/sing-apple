import Foundation
import Network
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
    func lyrics(songID: SongID, translateTo: String?) async -> Lyrics?
    func translationLanguages() async -> [TranslationLanguage]
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
    private var clients: [UUID: (pad: PadIdentity?, client: WebSocketListener.Client)] = [:]

    func open(_ c: WebSocketListener.Client) { clients[c.id] = (nil, c) }
    func authenticate(_ id: UUID, as pad: PadIdentity) { clients[id]?.pad = pad }
    func pad(_ id: UUID) -> PadIdentity? { clients[id]?.pad }
    func close(_ id: UUID) -> PadIdentity? { clients.removeValue(forKey: id)?.pad }
    var pads: [PadIdentity] { clients.values.compactMap(\.pad) }

    func send(_ message: ServerMessage, to padID: String? = nil) {
        guard let data = try? SingProtocol.encoder().encode(message) else { return }
        let text = String(decoding: data, as: UTF8.self)
        for (_, c) in clients where c.pad != nil && (padID == nil || c.pad?.padID == padID) {
            c.client.send(text)
        }
    }
}

/// HTTP on `port` for requests and artwork, WebSocket on `port + 1` for live state.
public final class SingServer: Sendable {
    let api: any HostAPI
    let hub = ConnectionHub()
    public let port: Int
    public var livePort: Int { port + 1 }
    private let listeners = Listeners()

    final class Listeners: @unchecked Sendable {
        var http: HTTPListener?
        var ws: WebSocketListener?
    }

    public init(api: any HostAPI, port: Int = SingProtocol.defaultPort) {
        self.api = api
        self.port = port
    }

    public func broadcast(_ message: ServerMessage, to padID: String? = nil) async {
        await hub.send(message, to: padID)
    }

    public func connectedPads() async -> [PadIdentity] { await hub.pads }

    public func stop() {
        listeners.http?.stop()
        listeners.ws?.stop()
    }

    /// Starts both listeners and returns once HTTP is ready, or throws.
    public func start() async throws {
        let api = self.api
        let hub = self.hub
        let http = try HTTPListener(port: port) { req in await Self.route(req, api: api) }
        let ws = try WebSocketListener(port: livePort)
        ws.onOpen = { client in Task { await hub.open(client) } }
        ws.onClose = { client in
            Task {
                if let pad = await hub.close(client.id) { await api.padConnected(pad, connected: false) }
            }
        }
        ws.onText = { client, text in
            Task {
                guard let msg = try? SingProtocol.decoder().decode(ClientMessage.self, from: Data(text.utf8)) else { return }
                await Self.handleLive(msg, client: client, hub: hub, api: api)
            }
        }
        listeners.http = http
        listeners.ws = ws
        ws.start()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let once = Once()
            http.start { state in
                switch state {
                case .ready: if once.fire() { cont.resume() }
                case .failed(let e): if once.fire() { cont.resume(throwing: e) }
                default: break
                }
            }
        }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func fire() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    static func handleLive(_ msg: ClientMessage, client: WebSocketListener.Client, hub: ConnectionHub, api: any HostAPI) async {
        let enc = SingProtocol.encoder()
        func send(_ m: ServerMessage) {
            if let d = try? enc.encode(m) { client.send(String(decoding: d, as: UTF8.self)) }
        }
        if case .auth(let token) = msg {
            guard let pad = await api.authenticate(token: token) else {
                send(.error(ErrorBody(code: "unauthorized", message: "This device is no longer paired. Pair it again.")))
                client.close()
                return
            }
            await hub.open(client)
            await hub.authenticate(client.id, as: pad)
            send(.hello(.init(server: await api.serverInfo(), role: pad.role, padID: pad.padID)))
            send(.state(await api.liveState()))
            await api.padConnected(pad, connected: true)
            return
        }
        guard let pad = await hub.pad(client.id) else {
            send(.error(ErrorBody(code: "unauthorized", message: "Authenticate first")))
            return
        }
        do {
            try await api.handle(msg, from: pad)
        } catch {
            send(.error(ErrorBody(code: "rejected", message: (error as? LocalizedError)?.errorDescription ?? "\(error)")))
        }
    }

    static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? SingProtocol.encoder().encode(value)) ?? Data())
    }

    static func error(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
        json(ErrorBody(code: code, message: message), status: status)
    }

    static func route(_ req: HTTPRequest, api: any HostAPI) async -> HTTPResponse {
        let parts = req.path.split(separator: "/").map(String.init)
        if req.method == "GET", parts.first != "v1" { return WebRemote.page(req.path) }
        guard parts.first == "v1" else { return error(404, "notFound", "Unknown path") }
        let rest = Array(parts.dropFirst())
        do {
            switch (req.method, rest.first) {
            case ("GET", "info"):
                return json(await api.serverInfo())
            case ("POST", "pair"):
                let body = try SingProtocol.decoder().decode(PairRequest.self, from: req.body)
                return json(try await api.pair(body))
            default: break
            }
            guard let token = req.bearer, let pad = await api.authenticate(token: token) else {
                return error(401, "unauthorized", "This device is no longer paired. Pair it again.")
            }
            switch (req.method, rest) {
            case ("GET", ["state"]):
                return json(await api.liveState())
            case ("GET", ["songs"]):
                let q = req.query
                let filters = SearchFilters(readyOnly: q["ready"] == "1", duetOnly: q["duet"] == "1", decade: q["decade"].flatMap { Int($0) }, genre: q["genre"], language: q["language"])
                return json(try await api.search(q["q"] ?? "", filters: filters))
            case ("GET", let p) where p.count == 3 && p[0] == "songs" && p[2] == "artwork":
                guard let id = Int64(p[1]), let data = await api.artwork(songID: id) else { return error(404, "notFound", "No artwork") }
                return HTTPResponse(contentType: "image/jpeg", body: data, extraHeaders: ["Cache-Control": "max-age=86400"])
            case ("GET", let p) where p.count == 3 && p[0] == "songs" && p[2] == "lyrics":
                guard let id = Int64(p[1]), let l = await api.lyrics(songID: id, translateTo: req.query["translate"].flatMap { $0.isEmpty ? nil : $0 }) else { return error(404, "notFound", "No lyrics") }
                return json(l)
            case ("GET", ["translation", "languages"]):
                return json(await api.translationLanguages())
            case ("GET", ["singers"]):
                return json(await api.singers())
            case ("POST", ["singers"]):
                let body = try SingProtocol.decoder().decode(NewSinger.self, from: req.body)
                return json(try await api.createSinger(name: body.name, emoji: body.emoji, pad: pad))
            case ("GET", ["stats"]):
                return json(try await api.stats(req.query["period"].flatMap(StatsPeriod.init(rawValue:)) ?? .tonight))
            case ("GET", let p) where p.count == 3 && p[0] == "stats" && p[1] == "singers":
                guard let id = Int64(p[2]), let s = try await api.singerStats(id) else { return error(404, "notFound", "Unknown singer") }
                return json(s)
            case ("GET", ["suggestions"]):
                return json(try await api.suggestions(singerID: req.query["singer"].flatMap { Int64($0) }))
            default:
                return error(404, "notFound", "Unknown path")
            }
        } catch let e as ErrorBody {
            return json(e, status: 400)
        } catch let e as LocalizedError {
            return error(400, "rejected", e.errorDescription ?? "\(e)")
        } catch {
            return self.error(400, "badRequest", "\(error)")
        }
    }
}

/// The web remote: one page any phone opens from the TV's QR code, no app needed.
enum WebRemote {
    static let html: Data? = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "web").flatMap { try? Data(contentsOf: $0) }

    static func page(_ path: String) -> HTTPResponse {
        if path == "/manifest.webmanifest" {
            let m = ##"{"name":"Sing!","short_name":"Sing!","start_url":"/","display":"standalone","background_color":"#0F0A08","theme_color":"#F26B1D"}"##
            return HTTPResponse(contentType: "application/manifest+json", body: Data(m.utf8))
        }
        if path == "/sing.apk" {
            guard let apk = try? Data(contentsOf: SingPaths.default.root.appendingPathComponent("Sing.apk")) else {
                return HTTPResponse(status: 404, contentType: "text/plain", body: Data("No Android app on this Mac".utf8))
            }
            return HTTPResponse(contentType: "application/vnd.android.package-archive", body: apk, extraHeaders: ["Content-Disposition": "attachment; filename=\"Sing.apk\""])
        }
        guard let html else { return HTTPResponse(status: 404, contentType: "text/plain", body: Data("Web remote missing".utf8)) }
        return HTTPResponse(contentType: "text/html; charset=utf-8", body: html, extraHeaders: ["Cache-Control": "no-cache"])
    }
}
