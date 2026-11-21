import Foundation

/// A song found in a public catalog (Apple Music, Deezer) that is not in the library yet.
public struct CatalogTrack: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var artist: String
    public var album: String?
    public var durationMs: Int
    public var artworkURL: String?
    public var isrc: String?
    public var sources: [String]
    public var year: Int?

    public init(id: String, title: String, artist: String, album: String?, durationMs: Int, artworkURL: String?, isrc: String?, sources: [String], year: Int?) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.durationMs = durationMs
        self.artworkURL = artworkURL
        self.isrc = isrc
        self.sources = sources
        self.year = year
    }

    public var durationText: String {
        let s = durationMs / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

public struct SongRequest: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var track: CatalogTrack
    public var singers: [Singer]
    public var requestedAt: Date
    public var votes: Int

    public init(id: String = UUID().uuidString, track: CatalogTrack, singers: [Singer], requestedAt: Date = .now, votes: Int = 1) {
        self.id = id
        self.track = track
        self.singers = singers
        self.requestedAt = requestedAt
        self.votes = votes
    }
}

public enum CatalogSearch {
    struct ITunes: Decodable {
        struct R: Decodable {
            var trackId: Int?
            var trackName: String?
            var artistName: String?
            var collectionName: String?
            var trackTimeMillis: Int?
            var artworkUrl100: String?
            var releaseDate: String?
        }
        var results: [R]
    }

    struct Deezer: Decodable {
        struct T: Decodable {
            struct A: Decodable { var name: String }
            struct Al: Decodable { var title: String?; var cover_big: String? }
            var id: Int
            var title: String
            var isrc: String?
            var duration: Int?
            var artist: A
            var album: Al?
        }
        var data: [T]?
    }

    /// Apple Music and Deezer in parallel, merged on title and artist. Both are free and need no key.
    public static func search(_ q: String, country: String = Locale.current.region?.identifier ?? "US", limit: Int = 25) async -> [CatalogTrack] {
        let query = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let session = makeSession(timeout: 5)
        async let apple: [CatalogTrack] = {
            var c = URLComponents(string: "https://itunes.apple.com/search")!
            c.queryItems = [URLQueryItem(name: "term", value: query), URLQueryItem(name: "entity", value: "song"), URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "country", value: country)]
            guard let (d, _) = try? await session.data(from: c.url!), let r = try? JSONDecoder().decode(ITunes.self, from: d) else { return [] }
            return r.results.compactMap { t in
                guard let id = t.trackId, let name = t.trackName, let artist = t.artistName else { return nil }
                return CatalogTrack(id: "am:\(id)", title: name, artist: artist, album: t.collectionName, durationMs: t.trackTimeMillis ?? 0,
                                    artworkURL: t.artworkUrl100?.replacingOccurrences(of: "100x100", with: "600x600"), isrc: nil, sources: ["Apple Music"], year: t.releaseDate.flatMap { Int($0.prefix(4)) })
            }
        }()
        async let deezer: [CatalogTrack] = {
            var c = URLComponents(string: "https://api.deezer.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: String(limit))]
            guard let (d, _) = try? await session.data(from: c.url!), let r = try? JSONDecoder().decode(Deezer.self, from: d) else { return [] }
            return (r.data ?? []).map { t in
                CatalogTrack(id: "dz:\(t.id)", title: t.title, artist: t.artist.name, album: t.album?.title, durationMs: (t.duration ?? 0) * 1000,
                             artworkURL: t.album?.cover_big, isrc: t.isrc, sources: ["Deezer"], year: nil)
            }
        }()
        return merge(await apple, await deezer)
    }

    static func key(_ t: CatalogTrack) -> String {
        normalizeForMatch(t.title) + "|" + normalizeForMatch(t.artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first ?? t.artist)
    }

    public static func merge(_ a: [CatalogTrack], _ b: [CatalogTrack]) -> [CatalogTrack] {
        var out: [CatalogTrack] = []
        var index: [String: Int] = [:]
        let maxCount = max(a.count, b.count)
        for i in 0..<maxCount {
            for list in [a, b] where i < list.count {
                let t = list[i]
                let k = key(t)
                if let j = index[k] {
                    out[j].sources = Array(Set(out[j].sources + t.sources)).sorted()
                    out[j].isrc = out[j].isrc ?? t.isrc
                    out[j].year = out[j].year ?? t.year
                    if out[j].durationMs == 0 { out[j].durationMs = t.durationMs }
                } else {
                    index[k] = out.count
                    out.append(t)
                }
            }
        }
        return out
    }
}
