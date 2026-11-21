import Foundation

public struct LyricsQuery: Sendable {
    public var title: String
    public var artist: String
    public var album: String?
    public var durationMs: Int
    public var isrc: String?

    public init(title: String, artist: String, album: String? = nil, durationMs: Int, isrc: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.isrc = isrc
    }
}

public protocol LyricsProvider: Sendable {
    var name: String { get }
    func fetch(_ query: LyricsQuery) async throws -> Lyrics?
}

let userAgent = "Sing/0.1 (+https://github.com/yohann69/sing-apple)"

func makeSession(timeout: TimeInterval) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout * 2
    config.httpAdditionalHeaders = ["User-Agent": userAgent]
    return URLSession(configuration: config)
}

/// Client for sing-lyrics-api: search, track lookup, match and TTML download.
public struct SingLyricsAPI: LyricsProvider {
    public let name = "Sing"
    public var base: URL
    let session: URLSession

    public init(base: URL, timeout: TimeInterval = 6) {
        self.base = base
        self.session = makeSession(timeout: timeout)
    }

    public struct Track: Codable, Sendable {
        public var id: String?
        public var isrc: String
        public var title: String
        public var artistName: String?
        public var albumTitle: String?
        public var durationMs: Int?
        public var hasLyrics: Bool?
        public var wordSynced: Bool?
        public var lineSynced: Bool?
    }

    public struct Download: Codable, Sendable {
        public var format: String
        public var language: String?
        public var wordSynced: Bool
        public var lineSynced: Bool
        public var downloadUrl: String
        public var plainLyrics: String?
        public var syncedLyrics: String?
    }

    struct MatchResponse: Codable { var track: Track; var lyrics: Download }
    struct SearchResponse: Codable { var tracks: [Track]?; var hits: [Track]? }

    public func healthy() async -> Bool {
        guard let (_, r) = try? await session.data(from: base.appendingPathComponent("healthz")) else { return false }
        return (r as? HTTPURLResponse)?.statusCode == 200
    }

    public func search(_ q: String, limit: Int = 10) async throws -> [Track] {
        var c = URLComponents(url: base.appendingPathComponent("v1/search"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: String(limit))]
        let data = try await get(c.url!)
        if let arr = try? JSONDecoder().decode([Track].self, from: data) { return arr }
        let r = try JSONDecoder().decode(SearchResponse.self, from: data)
        return r.tracks ?? r.hits ?? []
    }

    public func download(isrc: String) async throws -> Download? {
        let data = try await get(base.appendingPathComponent("v1/tracks/\(isrc)/lyrics"), allow404: true)
        return data.isEmpty ? nil : try JSONDecoder().decode(Download.self, from: data)
    }

    public func match(_ q: LyricsQuery) async throws -> Download? {
        var c = URLComponents(url: base.appendingPathComponent("v1/lyrics/match"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "track_name", value: q.title), URLQueryItem(name: "artist_name", value: q.artist)]
        if let album = q.album { c.queryItems?.append(URLQueryItem(name: "album_name", value: album)) }
        if q.durationMs > 0 { c.queryItems?.append(URLQueryItem(name: "duration", value: String(q.durationMs / 1000))) }
        let data = try await get(c.url!, allow404: true)
        return data.isEmpty ? nil : try JSONDecoder().decode(MatchResponse.self, from: data).lyrics
    }

    public func fetch(_ query: LyricsQuery) async throws -> Lyrics? {
        var dl: Download?
        if let isrc = query.isrc { dl = try? await download(isrc: isrc) }
        if dl == nil { dl = try await match(query) }
        guard let dl else { return nil }
        if let url = URL(string: dl.downloadUrl), !dl.downloadUrl.isEmpty {
            let (data, _) = try await session.data(from: url)
            if let lyrics = try? TTMLParser.parse(data, source: .singAPI) { return lyrics }
        }
        if let synced = dl.syncedLyrics { return try? LRCParser.parse(synced, source: .singAPI) }
        return dl.plainLyrics.flatMap { LRCParser.plain($0, source: .singAPI) }
    }

    private func get(_ url: URL, allow404: Bool = false) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if allow404 && code == 404 { return Data() }
        guard (200..<300).contains(code) else { throw URLError(.badServerResponse) }
        return data
    }
}

/// lrclib.net: free, open, line-synced lyrics.
public struct LRCLibProvider: LyricsProvider {
    public let name = "LRCLIB"
    let session: URLSession

    public init(timeout: TimeInterval = 6) {
        session = makeSession(timeout: timeout)
    }

    struct Response: Codable {
        var syncedLyrics: String?
        var plainLyrics: String?
        var duration: Double?
        var instrumental: Bool?
    }

    public func fetch(_ query: LyricsQuery) async throws -> Lyrics? {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [URLQueryItem(name: "track_name", value: query.title), URLQueryItem(name: "artist_name", value: query.artist)]
        if let album = query.album { c.queryItems?.append(URLQueryItem(name: "album_name", value: album)) }
        if query.durationMs > 0 { c.queryItems?.append(URLQueryItem(name: "duration", value: String(query.durationMs / 1000))) }
        var r = try await request(c.url!)
        if r == nil {
            var s = URLComponents(string: "https://lrclib.net/api/search")!
            s.queryItems = [URLQueryItem(name: "track_name", value: query.title), URLQueryItem(name: "artist_name", value: query.artist)]
            let (data, _) = try await session.data(from: s.url!)
            let list = (try? JSONDecoder().decode([Response].self, from: data)) ?? []
            let target = Double(query.durationMs) / 1000
            r = list.filter { $0.syncedLyrics != nil }.min { abs(($0.duration ?? 0) - target) < abs(($1.duration ?? 0) - target) } ?? list.first
        }
        guard let r else { return nil }
        if let synced = r.syncedLyrics, !synced.isEmpty { return try? LRCParser.parse(synced, source: .lrclib) }
        return r.plainLyrics.flatMap { LRCParser.plain($0, source: .lrclib) }
    }

    private func request(_ url: URL) async throws -> Response? {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Response.self, from: data)
    }
}
