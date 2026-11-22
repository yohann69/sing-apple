import Foundation
import Network
import SingCore

public struct ServerEndpoint: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var host: String
    public var port: Int
    public var id: String { "\(host):\(port)" }

    public init(name: String, host: String, port: Int) {
        self.name = name
        self.host = host
        self.port = port
    }

    public var baseURL: URL {
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return URL(string: "http://\(h):\(port)")!
    }

    /// Parses `sing://host:port?code=123456&name=Mac`.
    public static func parse(joinURL: URL) -> (ServerEndpoint, code: String)? {
        guard ["sing", "http", "https"].contains(joinURL.scheme ?? ""), let host = joinURL.host, let c = URLComponents(url: joinURL, resolvingAgainstBaseURL: false),
              let code = c.queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
        let name = c.queryItems?.first(where: { $0.name == "name" })?.value ?? host
        return (ServerEndpoint(name: name, host: host, port: joinURL.port ?? SingProtocol.defaultPort), code)
    }
}

public struct ClientError: Error, LocalizedError, Sendable {
    public var message: String
    public var code: String
    public var errorDescription: String? { message }

    public init(_ message: String, code: String = "client") {
        self.message = message
        self.code = code
    }
}

/// HTTP calls to the Mac. Stateless apart from the token.
public struct SingAPIClient: Sendable {
    public var endpoint: ServerEndpoint
    public var token: String?
    /// From `unlockOwner`, for owner-only calls when the Mac has an owner PIN.
    public var ownerToken: String?
    let session: URLSession

    public init(endpoint: ServerEndpoint, token: String? = nil) {
        self.endpoint = endpoint
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func info() async throws -> ServerInfo { try await get("v1/info") }

    public func pair(code: String, deviceName: String, deviceModel: String) async throws -> PairResponse {
        try await send("v1/pair", method: "POST", body: PairRequest(code: code, deviceName: deviceName, deviceModel: deviceModel))
    }

    public func state() async throws -> LiveState { try await get("v1/state") }

    public func search(_ q: String, filters: SearchFilters = SearchFilters()) async throws -> SearchResponse {
        var items = [URLQueryItem(name: "q", value: q)]
        if filters.readyOnly { items.append(URLQueryItem(name: "ready", value: "1")) }
        if filters.duetOnly { items.append(URLQueryItem(name: "duet", value: "1")) }
        if let d = filters.decade { items.append(URLQueryItem(name: "decade", value: String(d))) }
        if let g = filters.genre { items.append(URLQueryItem(name: "genre", value: g)) }
        if let l = filters.language { items.append(URLQueryItem(name: "language", value: l)) }
        if let f = filters.favoritesOf { items.append(URLQueryItem(name: "favorites", value: String(f))) }
        return try await get("v1/songs", query: items)
    }

    public func lyrics(_ id: SongID, translateTo: String? = nil) async throws -> Lyrics {
        try await get("v1/songs/\(id)/lyrics", query: translateTo.map { [URLQueryItem(name: "translate", value: $0)] } ?? [])
    }

    public struct Language: Codable, Sendable, Hashable { public var code: String; public var name: String }
    public func translationLanguages() async throws -> [Language] { try await get("v1/translation/languages") }
    public func singers() async throws -> [Singer] { try await get("v1/singers") }
    public func createSinger(name: String, emoji: String?) async throws -> Singer {
        try await send("v1/singers", method: "POST", body: ["name": name, "emoji": emoji ?? ""])
    }
    public func stats(_ period: StatsPeriod) async throws -> StatsResponse { try await get("v1/stats", query: [URLQueryItem(name: "period", value: period.rawValue)]) }
    public func singerStats(_ id: SingerID) async throws -> SingerStats { try await get("v1/stats/singers/\(id)") }
    public func suggestions(singer: SingerID?) async throws -> [Suggestion] {
        try await get("v1/suggestions", query: singer.map { [URLQueryItem(name: "singer", value: String($0))] } ?? [])
    }

    public func ratings(singer: SingerID) async throws -> [SongRating] {
        try await get("v1/ratings", query: [URLQueryItem(name: "singer", value: String(singer))])
    }
    @discardableResult
    public func rate(_ r: SongRating) async throws -> SongRating { try await send("v1/ratings", method: "POST", body: r) }

    public func unlockOwner(pin: String) async throws -> OwnerSession { try await send("v1/owner/unlock", method: "POST", body: OwnerUnlock(pin: pin)) }
    public func ownerOverview() async throws -> OwnerOverview { try await get("v1/owner") }
    public func storage() async throws -> StorageReport { try await get("v1/owner/storage") }
    public func clearCache(_ req: ClearCacheRequest) async throws -> ClearCacheResult { try await send("v1/owner/storage/clear", method: "POST", body: req) }
    @discardableResult
    public func updateOwnerSettings(_ s: SingSettings) async throws -> SingSettings { try await send("v1/owner/settings", method: "PUT", body: s) }
    public func unpair(padID: String) async throws {
        let _: [String: Bool] = try await send("v1/owner/pads/\(padID)", method: "DELETE", body: [String: String]())
    }

    /// Sends a short hummed recording; the Mac answers with the songs whose melody matches.
    public func humSearch(_ audio: Data) async throws -> [SongSummary] {
        var r = request(endpoint.baseURL.appendingPathComponent("v1/hum"), method: "POST")
        r.httpBody = audio
        r.timeoutInterval = 30
        r.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.data(for: r)
        try check(resp, data)
        return try SingProtocol.decoder().decode(SearchResponse.self, from: data).songs
    }

    public func displayPitch(_ id: SongID) async throws -> PitchTrack { try await get("v1/songs/\(id)/pitch") }

    public func searchLines(_ q: String) async throws -> SearchResponse { try await get("v1/lines", query: [URLQueryItem(name: "q", value: q)]) }
    public func ask(_ sentence: String) async throws -> SearchResponse { try await get("v1/ask", query: [URLQueryItem(name: "q", value: sentence)]) }
    public func duetSuggestions(_ a: SingerID, _ b: SingerID) async throws -> [Suggestion] {
        try await get("v1/suggestions/duet", query: [URLQueryItem(name: "a", value: String(a)), URLQueryItem(name: "b", value: String(b))])
    }
    public func smartKey(song: SongID, singer: SingerID) async throws -> SmartKey {
        try await get("v1/songs/\(song)/smartkey", query: [URLQueryItem(name: "singer", value: String(singer))])
    }
    public func updateSingerPrefs(_ id: SingerID, _ p: SingerPrefs) async throws { let _: [String: Bool] = try await send("v1/singers/\(id)/prefs", method: "PUT", body: p) }
    public func setSingerPIN(_ id: SingerID, pin: String?) async throws { let _: [String: Bool] = try await send("v1/singers/\(id)/pin", method: "POST", body: SingerPINRequest(pin: pin)) }
    public func unlockSinger(_ id: SingerID, pin: String) async throws { let _: [String: Bool] = try await send("v1/singers/\(id)/unlock", method: "POST", body: SingerPINRequest(pin: pin)) }
    public func mergeSingers(from: SingerID, into: SingerID) async throws { let _: [String: Bool] = try await send("v1/singers/merge", method: "POST", body: MergeSingers(from: from, into: into)) }
    public func wishes(_ singer: SingerID) async throws -> [SongSummary] { try await get("v1/singers/\(singer)/wishes") }
    public func setWish(_ singer: SingerID, song: SongID, on: Bool) async throws {
        let _: [String: Bool] = try await send("v1/singers/\(singer)/wishes/\(song)", method: on ? "PUT" : "DELETE", body: [String: String]())
    }
    public func queueNextWish(_ singer: SingerID) async throws -> SongSummary? {
        let r: SearchResponse = try await send("v1/singers/\(singer)/wishes/next", method: "POST", body: [String: String]())
        return r.songs.first
    }
    public func settingsProfiles() async throws -> [SettingsProfile] { try await get("v1/settings/profiles") }
    public func applySettingsProfile(_ name: String) async throws {
        let _: [String: Bool] = try await send("v1/settings/profiles/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)/apply", method: "POST", body: [String: String]())
    }
    public func auditLog() async throws -> [AuditEntry] { try await get("v1/owner/audit") }

    public func reportBadLyrics(_ id: SongID) async throws { let _: [String: Bool] = try await send("v1/songs/\(id)/lyrics/report", method: "POST", body: [String: String]()) }
    public func models() async throws -> [ModelInfo] { try await get("v1/owner/models") }
    public func removeModel(_ name: String) async throws { let _: [String: Bool] = try await send("v1/owner/models/\(name)", method: "DELETE", body: [String: String]()) }
    public func reinstallModels() async throws { let _: [String: Bool] = try await send("v1/owner/models/reinstall", method: "POST", body: [String: String]()) }
    public func checkCaches() async throws -> Int { let r: [String: Int] = try await send("v1/owner/check", method: "POST", body: [String: String]()); return r["rebuilding"] ?? 0 }

    public func recap() async throws -> PartyRecap { try await get("v1/recap") }
    public func songSettings(_ id: SongID) async throws -> SongSettings { try await get("v1/songs/\(id)/settings") }
    @discardableResult
    public func updateSongSettings(_ id: SongID, _ s: SongSettings) async throws -> SongSettings { try await send("v1/songs/\(id)/settings", method: "PUT", body: s) }

    public func recordings(singer: SingerID?) async throws -> [RecordingInfo] {
        try await get("v1/recordings", query: singer.map { [URLQueryItem(name: "singer", value: String($0))] } ?? [])
    }
    /// Token in the query so AVPlayer can stream it.
    public func recordingAudioURL(_ id: Int64) -> URL {
        var c = URLComponents(url: endpoint.baseURL.appendingPathComponent("v1/recordings/\(id)/audio"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "token", value: token)]
        return c.url!
    }
    public func shareURL(_ r: RecordingInfo) -> String { endpoint.baseURL.appendingPathComponent("r/\(r.shareToken)").absoluteString }
    public func keepRecording(_ id: Int64, _ keep: Bool) async throws {
        let _: [String: Bool] = try await send("v1/recordings/\(id)/\(keep ? "keep" : "unkeep")", method: "POST", body: [String: String]())
    }
    public func deleteRecording(_ id: Int64) async throws {
        let _: [String: Bool] = try await send("v1/recordings/\(id)", method: "DELETE", body: [String: String]())
    }
    public func replayRecording(_ id: Int64) async throws {
        let _: [String: Bool] = try await send("v1/recordings/\(id)/replay", method: "POST", body: [String: String]())
    }

    public func artworkURL(_ id: SongID) -> URL { endpoint.baseURL.appendingPathComponent("v1/songs/\(id)/artwork") }

    public func artwork(_ id: SongID) async throws -> Data {
        let (data, resp) = try await session.data(for: request(artworkURL(id)))
        try check(resp, data)
        return data
    }

    /// The live socket listens on the next port up.
    public var liveURL: URL? {
        guard token != nil else { return nil }
        let h = endpoint.host.contains(":") && !endpoint.host.hasPrefix("[") ? "[\(endpoint.host)]" : endpoint.host
        return URL(string: "ws://\(h):\(endpoint.port + 1)/v1/live")
    }

    func request(_ url: URL, method: String = "GET") -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let ownerToken { r.setValue(ownerToken, forHTTPHeaderField: "X-Sing-Owner") }
        return r
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var c = URLComponents(url: endpoint.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query }
        let (data, resp) = try await session.data(for: request(c.url!))
        try check(resp, data)
        return try SingProtocol.decoder().decode(T.self, from: data)
    }

    func send<B: Encodable, T: Decodable>(_ path: String, method: String, body: B) async throws -> T {
        var r = request(endpoint.baseURL.appendingPathComponent(path), method: method)
        r.httpBody = try SingProtocol.encoder().encode(body)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.data(for: r)
        try check(resp, data)
        return try SingProtocol.decoder().decode(T.self, from: data)
    }

    func check(_ resp: URLResponse, _ data: Data) throws {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if let e = try? SingProtocol.decoder().decode(ErrorBody.self, from: data) { throw ClientError(e.message, code: e.code) }
            if code == 401 { throw ClientError("This device is no longer paired. Pair it again.", code: "unauthorized") }
            throw ClientError("The Mac answered with an error (\(code)).", code: "http\(code)")
        }
    }
}

/// Live WebSocket with automatic reconnection.
public final class LiveConnection: @unchecked Sendable {
    public enum Status: Sendable, Equatable { case connecting, connected, disconnected(String?) }

    private let url: URL
    private let token: String
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var stopped = false
    private let lock = NSLock()
    private let onMessage: @Sendable (ServerMessage) -> Void
    private let onStatus: @Sendable (Status) -> Void
    private var attempt = 0

    public init(url: URL, token: String, onMessage: @escaping @Sendable (ServerMessage) -> Void, onStatus: @escaping @Sendable (Status) -> Void) {
        self.url = url
        self.token = token
        self.onMessage = onMessage
        self.onStatus = onStatus
    }

    public func start() {
        lock.withLock { stopped = false }
        connect()
    }

    public func stop() {
        lock.withLock {
            stopped = true
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
        }
    }

    public func send(_ message: ClientMessage) {
        guard let data = try? SingProtocol.encoder().encode(message) else { return }
        let t = lock.withLock { task }
        t?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func connect() {
        let t: URLSessionWebSocketTask? = lock.withLock {
            guard !stopped else { return nil }
            let t = session.webSocketTask(with: url)
            task = t
            return t
        }
        guard let t else { return }
        onStatus(.connecting)
        t.resume()
        if let auth = try? SingProtocol.encoder().encode(ClientMessage.auth(token: token)) {
            t.send(.string(String(decoding: auth, as: UTF8.self))) { _ in }
        }
        receive(t)
        t.sendPing { [weak self] error in
            guard let self else { return }
            if error == nil {
                self.lock.withLock { self.attempt = 0 }
                self.onStatus(.connected)
            }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                var data: Data?
                switch msg {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let data, let m = try? SingProtocol.decoder().decode(ServerMessage.self, from: data) {
                    if case .hello = m { self.onStatus(.connected) }
                    self.onMessage(m)
                }
                self.receive(t)
            case .failure(let error):
                self.onStatus(.disconnected(error.localizedDescription))
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        let delay: Double = lock.withLock {
            attempt += 1
            return min(10, 0.5 * pow(1.6, Double(attempt)))
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in self?.connect() }
    }
}

/// Finds Macs advertising `_sing._tcp` and resolves them to host and port.
public final class ServerBrowser: @unchecked Sendable {
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "sing.browser")
    private let onChange: @Sendable ([ServerEndpoint]) -> Void
    private var found: [String: ServerEndpoint] = [:]

    public init(onChange: @escaping @Sendable ([ServerEndpoint]) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: SingProtocol.bonjourType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            for r in results {
                guard case .service(let name, _, _, _) = r.endpoint else { continue }
                self.resolve(r.endpoint, name: name)
            }
            let names = Set(results.compactMap { r -> String? in if case .service(let n, _, _, _) = r.endpoint { return n } else { return nil } })
            self.queue.async {
                self.found = self.found.filter { names.contains($0.key) }
                self.onChange(Array(self.found.values).sorted { $0.name < $1.name })
            }
        }
        b.start(queue: queue)
        browser = b
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    private func resolve(_ endpoint: NWEndpoint, name: String) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if case .hostPort(let host, let port) = conn.currentPath?.remoteEndpoint {
                    var h = "\(host)"
                    if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                    self.queue.async {
                        self.found[name] = ServerEndpoint(name: name, host: h, port: Int(port.rawValue))
                        self.onChange(Array(self.found.values).sorted { $0.name < $1.name })
                    }
                }
                conn.cancel()
            case .failed, .cancelled:
                conn.cancel()
            default: break
            }
        }
        conn.start(queue: queue)
    }
}
