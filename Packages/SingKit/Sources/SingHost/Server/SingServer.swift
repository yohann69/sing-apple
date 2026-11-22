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
    func rate(_ r: SongRating) async throws
    func ratings(singerID: SingerID) async throws -> [SongRating]
    func unlockOwner(pin: String, pad: PadIdentity) async throws -> OwnerSession
    func isOwner(_ pad: PadIdentity, token: String?) async -> Bool
    func ownerOverview() async -> OwnerOverview
    func storageReport() async -> StorageReport
    func clearCache(_ req: ClearCacheRequest) async -> ClearCacheResult
    func revokePad(_ id: String) async
    func applyOwnerSettings(_ s: SingSettings) async
    func setPinned(_ id: SongID, _ pinned: Bool) async
    func recordings(singerID: SingerID?) async -> [RecordingInfo]
    func recordingAudio(id: Int64) async -> Data?
    func sharedRecording(token: String) async -> (info: RecordingInfo, audio: URL)?
    func keepRecording(_ id: Int64, _ keep: Bool) async
    func deleteRecording(_ id: Int64) async
    func replay(_ id: Int64) async throws
    func canSeeStats(_ pad: PadIdentity) async -> Bool
    func songSettings(_ id: SongID) async -> SongSettings?
    func updateSongSettings(_ id: SongID, _ s: SongSettings) async
    func exportDatabase() async throws -> Data
    func latestRecap() async -> PartyRecap?
    func humSearch(_ audio: Data) async throws -> [SongSummary]
    func reelFile(token: String) async -> URL?
    func displayPitch(songID: SongID) async -> PitchTrack?
    func createSinger(name: String, emoji: String?, guest: Bool, pad: PadIdentity) async throws -> Singer
    func updateSingerPrefs(_ id: SingerID, _ p: SingerPrefs, pad: PadIdentity?) async throws
    func renameSinger(_ id: SingerID, name: String, emoji: String?, colorHex: String?) async
    func setSingerPIN(_ id: SingerID, pin: String?, pad: PadIdentity?) async throws
    func verifySingerPIN(_ id: SingerID, pin: String, pad: PadIdentity) async throws
    func mergeSingers(from: SingerID, into: SingerID, by who: String) async throws
    func deleteSinger(_ id: SingerID, by who: String) async
    func smartKey(songID: SongID, singerID: SingerID) async -> SmartKey?
    func wishes(_ singerID: SingerID) async -> [SongSummary]
    func setWish(_ singerID: SingerID, songID: SongID, on: Bool, pad: PadIdentity?) async throws
    func queueWish(_ singerID: SingerID, pad: PadIdentity) async throws -> SongSummary?
    func settingsProfiles() async -> [SettingsProfile]
    func saveSettingsProfile(_ name: String) async
    func applySettingsProfile(_ name: String, by who: String) async
    func auditLog(limit: Int) async -> [AuditEntry]
    func ask(_ sentence: String) async throws -> SearchResponse
    func duetSuggestions(_ a: SingerID, _ b: SingerID) async throws -> [Suggestion]
}

public struct NewSinger: Codable, Sendable {
    public var name: String
    public var emoji: String?
    public var guest: Bool?

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

    func disconnect(padID: String) {
        for (id, c) in clients where c.pad?.padID == padID {
            c.client.close()
            clients[id] = nil
        }
    }

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

    public func disconnect(padID: String) async { await hub.disconnect(padID: padID) }

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

    /// Serves audio with byte ranges, which Safari and AVPlayer need to play and seek.
    static func audio(_ data: Data, _ req: HTTPRequest) -> HTTPResponse {
        let type = "audio/mp4"
        guard let range = req.headers["range"], range.hasPrefix("bytes=") else {
            return HTTPResponse(contentType: type, body: data, extraHeaders: ["Accept-Ranges": "bytes"])
        }
        let spec = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        let start = Int(spec.first ?? "") ?? 0
        let end = min(data.count - 1, spec.count > 1 ? Int(spec[1]) ?? data.count - 1 : data.count - 1)
        guard start <= end, start < data.count else { return HTTPResponse(status: 416, contentType: type, body: Data()) }
        return HTTPResponse(status: 206, contentType: type, body: data.subdata(in: start..<(end + 1)),
                            extraHeaders: ["Accept-Ranges": "bytes", "Content-Range": "bytes \(start)-\(end)/\(data.count)"])
    }

    static func error(_ status: Int, _ code: String, _ message: String) -> HTTPResponse {
        json(ErrorBody(code: code, message: message), status: status)
    }

    static func route(_ req: HTTPRequest, api: any HostAPI) async -> HTTPResponse {
        let parts = req.path.split(separator: "/").map(String.init)
        if req.method == "GET", parts.first == "r", parts.count >= 2, let reel = await api.reelFile(token: parts[1]) {
            if parts.count == 3, parts[2] == "audio", let data = try? Data(contentsOf: reel) { return audio(data, req) }
            let info = RecordingInfo(id: 0, songID: nil, songTitle: "Highlights of the night", artist: "Sing!", singers: [], recordedAt: .now, durationMs: 0, score: nil, kept: true, shareToken: parts[1])
            return WebRemote.sharePage(info, audioPath: "/r/\(parts[1])/audio")
        }
        if req.method == "GET", parts.first == "r", parts.count >= 2 {
            guard let shared = await api.sharedRecording(token: parts[1]) else { return HTTPResponse(status: 404, contentType: "text/plain", body: Data("This recording is gone.".utf8)) }
            if parts.count == 3, parts[2] == "audio", let data = try? Data(contentsOf: shared.audio) { return audio(data, req) }
            return WebRemote.sharePage(shared.info, audioPath: "/r/\(parts[1])/audio")
        }
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
            let statsAllowed = await api.canSeeStats(pad)
            switch (req.method, rest) {
            case ("GET", ["state"]):
                return json(await api.liveState())
            case ("GET", ["songs"]):
                let q = req.query
                let filters = SearchFilters(readyOnly: q["ready"] == "1", duetOnly: q["duet"] == "1", decade: q["decade"].flatMap { Int($0) }, genre: q["genre"], language: q["language"], favoritesOf: q["favorites"].flatMap { Int64($0) })
                return json(try await api.search(q["q"] ?? "", filters: filters))
            case ("GET", let p) where p.count == 3 && p[0] == "songs" && p[2] == "artwork":
                guard let id = Int64(p[1]), let data = await api.artwork(songID: id) else { return error(404, "notFound", "No artwork") }
                return HTTPResponse(contentType: "image/jpeg", body: data, extraHeaders: ["Cache-Control": "max-age=86400"])
            case ("GET", let p) where p.count == 3 && p[0] == "songs" && p[2] == "lyrics":
                guard let id = Int64(p[1]), let l = await api.lyrics(songID: id, translateTo: req.query["translate"].flatMap { $0.isEmpty ? nil : $0 }) else { return error(404, "notFound", "No lyrics") }
                return json(l)
            case ("GET", let p) where p.count == 3 && p[0] == "songs" && p[2] == "pitch":
                guard let id = Int64(p[1]), let t = await api.displayPitch(songID: id) else { return error(404, "notFound", "No melody yet") }
                return json(t)
            case ("GET", ["translation", "languages"]):
                return json(await api.translationLanguages())
            case ("GET", ["singers"]):
                return json(await api.singers())
            case ("POST", ["singers"]):
                let body = try SingProtocol.decoder().decode(NewSinger.self, from: req.body)
                return json(try await api.createSinger(name: body.name, emoji: body.emoji, guest: body.guest ?? false, pad: pad))
            case (_, let p) where p.count >= 3 && p[0] == "singers":
                guard let id = Int64(p[1]) else { return error(400, "badRequest", "Bad singer id") }
                return try await singerRoute(req, id, Array(p.dropFirst(2)), pad: pad, api: api)
            case ("POST", ["singers", "merge"]):
                guard pad.role == .host else { return error(403, "rejected", "Only the host can do that.") }
                let m = try SingProtocol.decoder().decode(MergeSingers.self, from: req.body)
                try await api.mergeSingers(from: m.from, into: m.into, by: pad.name)
                return json(["ok": true])
            case ("DELETE", let p) where p.count == 2 && p[0] == "singers":
                guard pad.role == .host, let id = Int64(p[1]) else { return error(403, "rejected", "Only the host can do that.") }
                await api.deleteSinger(id, by: pad.name)
                return json(["ok": true])
            case ("GET", ["ask"]):
                return json(try await api.ask(req.query["q"] ?? ""))
            case ("GET", ["suggestions", "duet"]):
                guard let a = req.query["a"].flatMap({ Int64($0) }), let b = req.query["b"].flatMap({ Int64($0) }) else { return error(400, "badRequest", "a and b are required") }
                return json(try await api.duetSuggestions(a, b))
            case ("GET", let p) where p.count == 3 && p[0] == "songs" && p[2] == "smartkey":
                guard let id = Int64(p[1]), let s = req.query["singer"].flatMap({ Int64($0) }), let k = await api.smartKey(songID: id, singerID: s) else { return error(404, "notFound", "Not enough singing to know this range yet") }
                return json(k)
            case ("GET", ["settings", "profiles"]):
                return json(await api.settingsProfiles())
            case ("POST", let p) where p.count == 4 && p[0] == "settings" && p[1] == "profiles":
                guard pad.role == .host else { return error(403, "rejected", "Only the host can do that.") }
                let name = p[2].removingPercentEncoding ?? p[2]
                if p[3] == "apply" { await api.applySettingsProfile(name, by: pad.name) } else { await api.saveSettingsProfile(name) }
                return json(["ok": true])
            case ("GET", let p) where p.first == "stats" && !statsAllowed:
                return error(403, "notAllowed", "The host keeps stats private tonight.")
            case ("GET", let p) where p.count == 3 && p[0] == "songs" && p[2] == "settings":
                guard pad.role == .host, let id = Int64(p[1]), let s = await api.songSettings(id) else { return error(404, "notFound", "Unknown song") }
                return json(s)
            case ("PUT", let p) where p.count == 3 && p[0] == "songs" && p[2] == "settings":
                guard pad.role == .host, let id = Int64(p[1]) else { return error(403, "rejected", "Only the host can do that.") }
                let s = try SingProtocol.decoder().decode(SongSettings.self, from: req.body)
                await api.updateSongSettings(id, s)
                return json(s)
            case ("POST", ["hum"]):
                guard req.body.count > 1000 else { return error(400, "badRequest", "Hum for a few seconds") }
                return json(SearchResponse(songs: try await api.humSearch(req.body), total: 0))
            case ("GET", ["recap"]):
                guard let r = await api.latestRecap() else { return error(404, "notFound", "No party yet") }
                return json(r)
            case ("GET", ["stats"]):
                return json(try await api.stats(req.query["period"].flatMap(StatsPeriod.init(rawValue:)) ?? .tonight))
            case ("GET", let p) where p.count == 3 && p[0] == "stats" && p[1] == "singers":
                guard let id = Int64(p[2]), let s = try await api.singerStats(id) else { return error(404, "notFound", "Unknown singer") }
                return json(s)
            case ("GET", ["suggestions"]):
                return json(try await api.suggestions(singerID: req.query["singer"].flatMap { Int64($0) }))
            case ("GET", ["ratings"]):
                guard let id = req.query["singer"].flatMap({ Int64($0) }) else { return error(400, "badRequest", "singer is required") }
                return json(try await api.ratings(singerID: id))
            case ("POST", ["ratings"]):
                let r = try SingProtocol.decoder().decode(SongRating.self, from: req.body)
                try await api.rate(r)
                return json(r)
            case ("GET", ["recordings"]):
                let singer = req.query["singer"].flatMap { Int64($0) }
                guard singer != nil || pad.role == .host else { return error(400, "badRequest", "singer is required") }
                return json(await api.recordings(singerID: singer))
            case ("GET", let p) where p.count == 3 && p[0] == "recordings" && p[2] == "audio":
                guard let id = Int64(p[1]), let data = await api.recordingAudio(id: id) else { return error(404, "notFound", "No recording") }
                return audio(data, req)
            case ("POST", let p) where p.count == 3 && p[0] == "recordings" && (p[2] == "keep" || p[2] == "unkeep"):
                guard let id = Int64(p[1]) else { return error(400, "badRequest", "Bad id") }
                await api.keepRecording(id, p[2] == "keep")
                return json(["ok": true])
            case ("POST", let p) where p.count == 3 && p[0] == "recordings" && p[2] == "replay":
                guard pad.role == .host, let id = Int64(p[1]) else { return error(403, "rejected", "Only the host can do that.") }
                try await api.replay(id)
                return json(["ok": true])
            case ("DELETE", let p) where p.count == 2 && p[0] == "recordings":
                guard pad.role == .host, let id = Int64(p[1]) else { return error(403, "rejected", "Only the host can do that.") }
                await api.deleteRecording(id)
                return json(["ok": true])
            case ("POST", ["owner", "unlock"]):
                let body = try SingProtocol.decoder().decode(OwnerUnlock.self, from: req.body)
                return json(try await api.unlockOwner(pin: body.pin, pad: pad))
            case (_, let p) where p.first == "owner":
                guard await api.isOwner(pad, token: req.headers["x-sing-owner"] ?? req.query["owner"]) else {
                    return error(403, "owner", "Enter the owner PIN to open this.")
                }
                return try await ownerRoute(req, Array(p.dropFirst()), api: api)
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

extension SingServer {
    static func singerRoute(_ req: HTTPRequest, _ id: SingerID, _ p: [String], pad: PadIdentity, api: any HostAPI) async throws -> HTTPResponse {
        let dec = SingProtocol.decoder()
        switch (req.method, p) {
        case ("PUT", ["prefs"]):
            try await api.updateSingerPrefs(id, try dec.decode(SingerPrefs.self, from: req.body), pad: pad)
        case ("PUT", ["profile"]):
            guard pad.role == .host else { return error(403, "rejected", "Only the host can do that.") }
            let s = try dec.decode(Singer.self, from: req.body)
            await api.renameSinger(id, name: s.name, emoji: s.emoji, colorHex: s.colorHex)
        case ("POST", ["pin"]):
            try await api.setSingerPIN(id, pin: try dec.decode(SingerPINRequest.self, from: req.body).pin, pad: pad)
        case ("POST", ["unlock"]):
            try await api.verifySingerPIN(id, pin: try dec.decode(SingerPINRequest.self, from: req.body).pin ?? "", pad: pad)
        case ("GET", ["wishes"]):
            return json(await api.wishes(id))
        case ("POST", ["wishes", "next"]):
            return json(SearchResponse(songs: try await api.queueWish(id, pad: pad).map { [$0] } ?? [], total: 0))
        case (let m, let q) where q.count == 2 && q[0] == "wishes" && (m == "PUT" || m == "DELETE"):
            guard let song = Int64(q[1]) else { return error(400, "badRequest", "Bad song id") }
            try await api.setWish(id, songID: song, on: m == "PUT", pad: pad)
        default:
            return error(404, "notFound", "Unknown path")
        }
        return json(["ok": true])
    }

    static func ownerRoute(_ req: HTTPRequest, _ p: [String], api: any HostAPI) async throws -> HTTPResponse {
        switch (req.method, p) {
        case ("GET", []):
            return json(await api.ownerOverview())
        case ("GET", ["audit"]):
            return json(await api.auditLog(limit: 300))
        case ("GET", ["backup"]):
            return HTTPResponse(contentType: "application/vnd.sqlite3", body: try await api.exportDatabase(),
                                extraHeaders: ["Content-Disposition": "attachment; filename=\"sing-backup.sqlite\""])
        case ("GET", ["storage"]):
            return json(await api.storageReport())
        case ("POST", ["storage", "clear"]):
            return json(await api.clearCache(try SingProtocol.decoder().decode(ClearCacheRequest.self, from: req.body)))
        case ("PUT", ["settings"]):
            await api.applyOwnerSettings(try SingProtocol.decoder().decode(SingSettings.self, from: req.body))
            return json(await api.liveState().settings)
        case ("DELETE", let q) where q.count == 2 && q[0] == "pads":
            await api.revokePad(q[1])
            return json(["ok": true])
        case ("POST", let q) where q.count == 3 && q[0] == "songs" && (q[2] == "pin" || q[2] == "unpin"):
            guard let id = Int64(q[1]) else { return error(400, "badRequest", "Bad song id") }
            await api.setPinned(id, q[2] == "pin")
            return json(["ok": true])
        default:
            return error(404, "notFound", "Unknown path")
        }
    }
}

/// The web remote: one page any phone opens from the TV's QR code, no app needed.
enum WebRemote {
    static let html: Data? = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "web").flatMap { try? Data(contentsOf: $0) }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The page a shared QR code opens: one song, one player, nothing else from the party.
    static func sharePage(_ r: RecordingInfo, audioPath: String) -> HTTPResponse {
        let who = r.singers.map(\.name).joined(separator: " & ")
        let html = ##"""
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\##(esc(r.songTitle)) · Sing!</title>
        <style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:radial-gradient(circle at 20% 10%,#5a2410,#0F0A08 60%);color:#FFF4EC;font:17px -apple-system,system-ui,sans-serif}
        main{width:min(92vw,440px);padding:28px;border-radius:28px;background:rgba(255,255,255,.07);border:1px solid rgba(255,255,255,.12);backdrop-filter:blur(30px)}
        h1{margin:0 0 4px;font-size:26px}p{margin:0 0 18px;opacity:.7}audio{width:100%}a{color:#F26B1D}small{display:block;margin-top:18px;opacity:.5}</style></head>
        <body><main><h1>\##(esc(r.songTitle))</h1><p>\##(esc(r.artist))\##(who.isEmpty ? "" : " · sung by " + esc(who))\##(r.score.map { " · \($0) pts" } ?? "")</p>
        <audio controls preload="metadata" src="\##(audioPath)"></audio><p style="margin-top:14px"><a href="\##(audioPath)" download="\##(esc(r.songTitle)).m4a">Download</a></p>
        <small>Shared from Sing! on this Wi-Fi. The link works while the Mac is on.</small></main></body></html>
        """##
        return HTTPResponse(contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }

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
