import Foundation
import SingCore

public final class LyricsService: Sendable {
    let library: LibraryStore
    let paths: SingPaths
    let services: @Sendable () -> ServiceSettings

    public init(library: LibraryStore, paths: SingPaths, services: @escaping @Sendable () -> ServiceSettings) {
        self.library = library
        self.paths = paths
        self.services = services
    }

    public func cached(_ song: SongRecord) -> Lyrics? {
        guard let data = try? Data(contentsOf: paths.lyrics(song.audioHash)) else { return nil }
        return try? JSONDecoder().decode(Lyrics.self, from: data)
    }

    /// Cache first, then local files, then the Sing API and LRCLIB; the richest timing wins.
    public func resolve(_ song: SongRecord, refresh: Bool = false) async -> Lyrics? {
        if !refresh, let c = cached(song) { return c }
        var candidates: [(Lyrics, Int)] = []
        candidates += localCandidates(song).map { ($0, 3) }
        let best = candidates.max { $0.0.kind < $1.0.kind }
        if best?.0.kind ?? .plain < .word {
            let s = services()
            let query = LyricsQuery(title: song.title, artist: Self.primaryArtist(song.artist), album: song.album, durationMs: song.durationMs, isrc: song.isrc)
            var providers: [(any LyricsProvider, Int)] = []
            if s.singAPIEnabled, let base = URL(string: s.singAPIBase) { providers.append((SingLyricsAPI(base: base, timeout: s.timeoutSeconds), 4)) }
            if s.lrclibEnabled { providers.append((LRCLibProvider(timeout: s.timeoutSeconds), 1)) }
            await withTaskGroup(of: (Lyrics, Int)?.self) { group in
                for (p, rank) in providers {
                    group.addTask { (try? await p.fetch(query)).flatMap { $0 }.map { ($0, rank) } }
                }
                for await r in group { if let r { candidates.append(r) } }
            }
        }
        guard let chosen = candidates.max(by: { ($0.0.kind, $0.1) < ($1.0.kind, $1.1) })?.0 else { return nil }
        store(chosen, for: song)
        return chosen
    }

    public func store(_ lyrics: Lyrics, for song: SongRecord) {
        try? FileManager.default.createDirectory(at: paths.songCache(song.audioHash), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(lyrics) { try? data.write(to: paths.lyrics(song.audioHash), options: .atomic) }
        if let id = song.id {
            let kind = lyrics.kind
            let duet = lyrics.isDuet
            Task { try? await library.update(id) { $0.lyricsKind = kind; $0.isDuet = duet } }
        }
    }

    func localCandidates(_ song: SongRecord) -> [Lyrics] {
        var out: [Lyrics] = []
        let audio = URL(fileURLWithPath: song.filePath)
        let stem = audio.deletingPathExtension()
        if let d = try? Data(contentsOf: stem.appendingPathExtension("ttml")), let l = try? TTMLParser.parse(d, source: .sidecar) { out.append(l) }
        if let t = try? String(contentsOf: stem.appendingPathExtension("lrc"), encoding: .utf8), let l = try? LRCParser.parse(t, source: .sidecar) { out.append(l) }
        let dir = paths.songCache(song.audioHash)
        if let t = try? String(contentsOf: dir.appendingPathComponent("embedded.lrc"), encoding: .utf8), let l = try? LRCParser.parse(t, source: .embedded) { out.append(l) }
        if out.isEmpty {
            for url in [stem.appendingPathExtension("txt"), dir.appendingPathComponent("embedded.txt")] {
                if let t = try? String(contentsOf: url, encoding: .utf8), let l = LRCParser.plain(t, source: .embedded) { out.append(l); break }
            }
        }
        return out
    }

    static func primaryArtist(_ artist: String) -> String {
        for sep in [" & ", ", ", " feat. ", " ft. ", ";"] {
            if let r = artist.range(of: sep) { return String(artist[..<r.lowerBound]) }
        }
        return artist
    }
}
