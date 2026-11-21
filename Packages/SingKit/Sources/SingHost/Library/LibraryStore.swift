import Foundation
import GRDB
import SingCore

public struct ImportResult: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var skipped = 0
    public var failed: [String] = []
}

public final class LibraryStore: Sendable {
    let db: SingDatabase
    let paths: SingPaths

    public init(db: SingDatabase, paths: SingPaths) {
        self.db = db
        self.paths = paths
    }

    // MARK: Import

    public static func audioFiles(in urls: [URL]) -> [URL] {
        var out: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if AudioMetadataReader.supportedExtensions.contains(f.pathExtension.lowercased()) { out.append(f) }
                }
            } else if AudioMetadataReader.supportedExtensions.contains(url.pathExtension.lowercased()) {
                out.append(url)
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    public func importFiles(_ urls: [URL], progress: (@Sendable (Int, Int) -> Void)? = nil) async -> ImportResult {
        var result = ImportResult()
        let files = Self.audioFiles(in: urls)
        for (i, file) in files.enumerated() {
            progress?(i, files.count)
            do {
                switch try await importFile(file) {
                case .added: result.added += 1
                case .updated: result.updated += 1
                case .unchanged: result.skipped += 1
                }
            } catch {
                result.failed.append(file.lastPathComponent)
            }
        }
        progress?(files.count, files.count)
        return result
    }

    public enum ImportOutcome: Sendable { case added, updated, unchanged }

    @discardableResult
    public func importFile(_ url: URL) async throws -> ImportOutcome {
        if let existing = try await db.writer.read({ try SongRecord.filter(Column("filePath") == url.path).fetchOne($0) }),
           !existing.missing, FileManager.default.fileExists(atPath: existing.filePath) {
            return .unchanged
        }
        let meta = try await AudioMetadataReader.read(url)
        let hash = try AudioHasher.hash(url)
        try paths.ensure()
        let cacheDir = paths.songCache(hash)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        var palette: [String]?
        if let art = meta.artwork {
            try art.write(to: paths.artwork(hash))
            palette = PaletteExtractor.palette(from: art)
        }
        if let synced = meta.syncedLyrics {
            try synced.write(to: cacheDir.appendingPathComponent("embedded.lrc"), atomically: true, encoding: .utf8)
        }
        if let plain = meta.plainLyrics {
            try plain.write(to: cacheDir.appendingPathComponent("embedded.txt"), atomically: true, encoding: .utf8)
        }
        let paletteJSON = palette.flatMap { try? String(decoding: JSONEncoder().encode($0), as: UTF8.self) }

        return try await db.writer.write { db in
            if var song = try SongRecord.filter(Column("audioHash") == hash).fetchOne(db) {
                song.filePath = url.path
                song.missing = false
                song.title = meta.title ?? song.title
                song.artist = meta.artist ?? song.artist
                song.album = meta.album ?? song.album
                song.isrc = meta.isrc ?? song.isrc
                song.hasArtwork = meta.artwork != nil || song.hasArtwork
                song.palette = paletteJSON ?? song.palette
                try song.update(db)
                return .updated
            }
            var song = SongRecord(
                title: meta.title ?? url.deletingPathExtension().lastPathComponent,
                artist: meta.artist ?? "Unknown artist",
                album: meta.album, durationMs: meta.durationMs, year: meta.year, genre: meta.genre,
                language: meta.language, isrc: meta.isrc, filePath: url.path, audioHash: hash
            )
            song.hasArtwork = meta.artwork != nil
            song.palette = paletteJSON
            try song.insert(db)
            return .added
        }
    }

    // MARK: Queries

    public func song(_ id: SongID) async throws -> SongRecord? {
        try await db.writer.read { try SongRecord.fetchOne($0, key: id) }
    }

    public func all() async throws -> [SongRecord] {
        try await db.writer.read { try SongRecord.order(Column("artist"), Column("title")).fetchAll($0) }
    }

    public func update(_ id: SongID, _ change: @escaping @Sendable (inout SongRecord) -> Void) async throws {
        try await db.writer.write { db in
            guard var song = try SongRecord.fetchOne(db, key: id) else { return }
            change(&song)
            try song.update(db)
        }
    }

    public func playCounts() async throws -> [SongID: Int] {
        try await db.writer.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT songId, COUNT(*) AS n FROM play WHERE songId IS NOT NULL AND skipped = 0 GROUP BY songId")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["songId"] as Int64, $0["n"] as Int) })
        }
    }

    public func search(_ query: String, filters: SearchFilters = SearchFilters(), limit: Int = 60) async throws -> [SongRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let songs: [SongRecord] = try await db.writer.read { db in
            var request = SongRecord.all()
            if filters.readyOnly { request = request.filter(Column("readiness") == Readiness.ready.rawValue) }
            if filters.duetOnly { request = request.filter(Column("isDuet") == true) }
            if let decade = filters.decade { request = request.filter(Column("year") >= decade && Column("year") < decade + 10) }
            if let genre = filters.genre { request = request.filter(Column("genre") == genre) }
            if let lang = filters.language { request = request.filter(Column("language") == lang) }
            guard !q.isEmpty else {
                return try request.order(Column("artist"), Column("title")).limit(limit).fetchAll(db)
            }
            var hits: [SongRecord] = []
            if let pattern = FTS5Pattern(matchingAllPrefixesIn: q) {
                let ids = try Int64.fetchAll(db, sql: "SELECT rowid FROM songFts WHERE songFts MATCH ? ORDER BY bm25(songFts, 10.0, 5.0, 1.0) LIMIT ?", arguments: [pattern, limit])
                let found = try request.filter(ids.contains(Column("id"))).fetchAll(db)
                let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
                hits = found.sorted { (order[$0.id ?? 0] ?? 0) < (order[$1.id ?? 0] ?? 0) }
            }
            if hits.count < 5 {
                let all = try request.fetchAll(db)
                let fuzzy = Fuzzy.rank(all, query: q) { "\($0.title) \($0.artist) \($0.album ?? "")" }
                for s in fuzzy where !hits.contains(where: { $0.id == s.id }) { hits.append(s) }
            }
            return Array(hits.prefix(limit))
        }
        return songs
    }
}

enum Fuzzy {
    static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
    }

    static func rank<T>(_ items: [T], query: String, text: (T) -> String) -> [T] {
        let qWords = normalize(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !qWords.isEmpty else { return [] }
        let scored: [(T, Double)] = items.compactMap { item in
            let words = normalize(text(item)).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            var total = 0.0
            for q in qWords {
                let best = words.map { w -> Double in
                    if w.hasPrefix(q) { return 0 }
                    let d = Double(distance(q, String(w.prefix(q.count + 1))))
                    return d / Double(max(q.count, 1))
                }.min() ?? 1
                if best > 0.34 { return nil }
                total += best
            }
            return (item, total)
        }
        return scored.sorted { $0.1 < $1.1 }.map(\.0)
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
